# frozen_string_literal: true

# snapshots_gen exporter: reads an old cosmoSys instance (Redmine 4.2) and
# either prints its inventory or writes a legacy snapshot package.
#
#   bundle exec rails runner -e production export.rb inventory [out=DIR]
#   bundle exec rails runner -e production export.rb capture out=DIR [label=NAME]
#
# It only reads: every query runs inside one read-only transaction, nothing is
# installed, migrated or restarted, and nothing is written to the instance.
# Its only output is the inventory file or the package under out=DIR.

require_relative 'legacy_snapshot_format'
require 'fileutils'
require 'json'

module SnapshotsGen
  module Exporter
    VERSION = '0.1.0'
    GENERATOR = { 'name' => 'snapshots_gen exporter', 'version' => VERSION }.freeze

    EXCLUDED_TABLES = {
      'tokens' => 'credentials (sessions, API keys, feeds, recovery); the new instance issues its own',
      'sessions' => 'credentials (web sessions)'
    }.freeze
    REDACTED_COLUMNS = {
      'users' => {
        'twofa_totp_key' => '2FA secret encrypted with the old instance key; 2FA is reset in the new instance'
      },
      'auth_sources' => { 'account_password' => 'service credential' },
      'repositories' => { 'password' => 'service credential' }
    }.freeze
    SECRET_SETTING_NAMES = %w[mail_handler_api_key sys_api_key].freeze
    SECRET_PATTERN = /password|passwd|secret|token|api_key|private_key/i.freeze
    BATCH_SIZE = 1000

    module_function

    def main(argv)
      # Packages hold password hashes and client data: only the owner may read them.
      File.umask(0o077)
      mode = argv.first.to_s
      options = argv.drop(1).each_with_object({}) do |argument, result|
        key, value = argument.split('=', 2)
        raise ArgumentError, "expected key=value, got #{argument.inspect}" if value.nil?

        result[key] = value
      end
      case mode
      when 'inventory' then run_inventory(options)
      when 'capture' then run_capture(options)
      else
        warn 'usage: export.rb inventory [out=DIR] | capture out=DIR [label=NAME]'
        exit 2
      end
    end

    def run_inventory(options)
      reader = Reader.new(ActiveRecord::Base.connection)
      inventory = nil
      reader.transaction { inventory = Inventory.new(reader).build }
      puts Inventory.summary(inventory)
      return unless options['out']

      FileUtils.mkdir_p(options['out'])
      path = File.join(options['out'], "inventory-#{timestamp}.json")
      File.write(path, LegacySnapshot::CanonicalJson.generate(inventory) + "\n")
      puts "Inventory written to #{path}"
    end

    def run_capture(options)
      out = options.fetch('out') { raise ArgumentError, 'capture needs out=DIR' }
      label = options['label'].to_s.strip
      label = 'instance' if label.empty?
      raise ArgumentError, 'label may only contain letters, digits, - and _' unless label.match?(/\A[A-Za-z0-9_-]+\z/)

      FileUtils.mkdir_p(out)
      stamp = timestamp
      staging = File.join(out, ".#{label}-#{stamp}.staging")
      target = File.join(out, "#{label}-#{stamp}.cslegacy")
      reader = Reader.new(ActiveRecord::Base.connection)
      capture = Capture.new(reader, LegacySnapshot::Writer.new(staging), label: label)
      reader.transaction { capture.call }
      LegacySnapshot::Writer.zip_directory(staging, target)
      FileUtils.rm_rf(staging)
      result = LegacySnapshot::Verifier.new(target).verify
      raise "the package does not verify: #{result.errors.first(5).join('; ')}" unless result.ok?

      puts capture.summary
      puts "Package written to #{target} (#{File.size(target)} bytes), verified."
    rescue StandardError
      FileUtils.rm_rf(staging) if staging
      raise
    end

    def timestamp
      Time.now.utc.strftime('%Y%m%dT%H%M%SZ')
    end

    # Read-only access to the instance database, inside one consistent
    # transaction.
    class Reader
      attr_reader :connection, :consistency, :started_at

      def initialize(connection)
        @connection = connection
      end

      def adapter
        @adapter ||= connection.adapter_name.downcase
      end

      def mysql?
        adapter.include?('mysql')
      end

      def postgresql?
        adapter.include?('postg')
      end

      def transaction
        if mysql?
          # A session set to utf8 would turn 4-byte characters into '?'.
          if connection.select_value("SELECT @@character_set_database") == 'utf8mb4'
            connection.execute('SET NAMES utf8mb4')
          end
          connection.execute('SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ')
          connection.execute('START TRANSACTION WITH CONSISTENT SNAPSHOT, READ ONLY')
          @consistency = 'mysql_consistent_snapshot_read_only'
        elsif postgresql?
          connection.execute('BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY')
          @consistency = 'postgresql_repeatable_read_read_only'
        else
          connection.execute('BEGIN')
          @consistency = 'generic_transaction'
        end
        @started_at = Time.now.utc
        yield
      ensure
        connection.execute('ROLLBACK') if @consistency
      end

      def tables
        @tables ||= connection.tables.map(&:to_s).sort
      end

      def table?(name)
        tables.include?(name)
      end

      def column?(table, column)
        table?(table) && columns(table).any? { |entry| entry.name == column }
      end

      def columns(table)
        @columns ||= {}
        @columns[table] ||= connection.columns(table)
      end

      def primary_key(table)
        keys = if connection.respond_to?(:primary_keys)
                 connection.primary_keys(table)
               else
                 [connection.primary_key(table)].compact
               end
        Array(keys).map(&:to_s)
      end

      def quote_table(name)
        connection.quote_table_name(name)
      end

      def quote_column(name)
        connection.quote_column_name(name)
      end

      def value(sql)
        connection.select_value(sql)
      end

      def rows(sql)
        connection.select_all(sql).to_a
      end

      def count(table)
        value("SELECT COUNT(*) FROM #{quote_table(table)}").to_i
      end

      # Yields raw rows (Hash by column name) in primary-key order when the key
      # is one integer column, or all rows at once otherwise.
      def each_raw_row(table, primary_key)
        if integer_key?(table, primary_key)
          key = quote_column(primary_key.first)
          last = nil
          loop do
            condition = last.nil? ? '' : "WHERE #{key} > #{Integer(last)} "
            batch = rows("SELECT * FROM #{quote_table(table)} #{condition}ORDER BY #{key} LIMIT #{BATCH_SIZE}")
            break if batch.empty?

            batch.each { |row| yield row }
            last = batch.last[primary_key.first]
          end
        else
          rows("SELECT * FROM #{quote_table(table)}").each { |row| yield row }
        end
      end

      def integer_key?(table, primary_key)
        return false unless primary_key.length == 1

        column = columns(table).find { |entry| entry.name == primary_key.first }
        column && column.type == :integer
      end
    end

    class Capture
      attr_reader :gaps, :redactions, :stats

      def initialize(reader, writer, label:)
        @reader = reader
        @writer = writer
        @label = label
        @gaps = []
        @redactions = []
        @stats = {}
        @attachments = []
      end

      def call
        inventory = Inventory.new(@reader).build
        excluded = []
        @reader.tables.each do |table|
          if EXCLUDED_TABLES.key?(table)
            excluded << { 'name' => table, 'reason' => EXCLUDED_TABLES.fetch(table), 'rows' => @reader.count(table) }
            next
          end
          export_table(table)
        end
        export_assets
        verify_counts!
        @writer.write_report_document('inventory', inventory)
        @writer.write_report_rows('gaps', sorted(@gaps))
        @writer.write_report_rows('redactions', sorted(@redactions))
        @writer.finish!(
          captured_at: @reader.started_at,
          generator: GENERATOR,
          source: inventory.fetch('platform').merge('label' => @label, 'settings' => inventory.fetch('settings'),
                                                    'plugins' => inventory.fetch('plugins')),
          consistency: { 'mode' => @reader.consistency, 'counts_checked' => true },
          excluded_tables: excluded
        )
      end

      def summary
        lines = ["Captured #{@stats.length} tables, #{@stats.values.sum} rows, #{@attachments.length} attachment rows."]
        by_code = @gaps.group_by { |gap| gap['code'] }
        if by_code.empty?
          lines << 'Gaps: none.'
        else
          lines << 'Gaps:'
          by_code.keys.sort.each { |code| lines << "  #{code}: #{by_code[code].length}" }
        end
        lines << "Redactions: #{@redactions.length}."
        lines.join("\n")
      end

      private

      def sorted(rows)
        rows.sort_by { |row| [row['code'].to_s, row['table'].to_s, row['id'].to_s.rjust(20, '0'), row['column'].to_s] }
      end

      def export_table(table)
        columns = @reader.columns(table)
        primary_key = @reader.primary_key(table)
        names = columns.map(&:name)
        order_by = primary_key.empty? ? names : primary_key
        redacted = REDACTED_COLUMNS.fetch(table, {}).select { |column, _reason| names.include?(column) }
        descriptors = columns.map do |column|
          { 'name' => column.name, 'type' => column.type.to_s, 'sql_type' => column.sql_type.to_s,
            'null' => column.null ? true : false }
        end
        encoded_rows = []
        streamed = @reader.integer_key?(table, primary_key)
        entry = @writer.write_table(table, columns: descriptors, primary_key: primary_key, order_by: order_by,
                                           redacted_columns: redacted.keys) do |emit|
          @reader.each_raw_row(table, primary_key) do |raw|
            row = encode_row(table, columns, raw, redacted, primary_key)
            remember_attachment(row) if table == 'attachments'
            streamed ? emit.call(row) : encoded_rows << row
          end
          unless streamed
            encoded_rows.sort_by { |row| LegacySnapshot::Values.row_sort_key(row, order_by) }.each { |row| emit.call(row) }
          end
        end
        @stats[table] = entry.fetch('rows')
      end

      def encode_row(table, columns, raw, redacted, primary_key)
        row = {}
        identifier = primary_key.length == 1 ? raw[primary_key.first] : nil
        columns.each do |column|
          if redacted.key?(column.name)
            unless raw[column.name].nil? || raw[column.name].to_s.empty?
              @redactions << { 'table' => table, 'id' => identifier, 'column' => column.name,
                               'reason' => redacted.fetch(column.name) }
            end
            row[column.name] = nil
            next
          end
          value, problem = LegacySnapshot::Values.encode(raw[column.name], column.type)
          if problem == :invalid_utf8
            @gaps << { 'code' => 'invalid_utf8', 'table' => table, 'id' => identifier,
                       'detail' => { 'column' => column.name } }
          end
          row[column.name] = value
        end
        redact_setting!(row) if table == 'settings'
        row
      end

      def redact_setting!(row)
        name = row['name'].to_s
        value = row['value']
        secret = SECRET_SETTING_NAMES.include?(name) ||
                 (name.start_with?('plugin_') && value.is_a?(String) && value.match?(SECRET_PATTERN))
        return unless secret && !value.nil?

        row['value'] = nil
        @redactions << { 'table' => 'settings', 'id' => row['id'], 'column' => 'value',
                         'reason' => "setting #{name} holds credentials" }
      end

      def remember_attachment(row)
        @attachments << row.select { |key, _value| %w[id disk_directory disk_filename filesize digest].include?(key) }
      end

      def export_assets
        index = @attachments.map do |row|
          id = row.fetch('id')
          path = File.join(Attachment.storage_path, row['disk_directory'].to_s, row['disk_filename'].to_s)
          detail = { 'disk_directory' => row['disk_directory'], 'disk_filename' => row['disk_filename'] }
          if row['disk_filename'].to_s.empty? || !File.file?(path)
            @gaps << { 'code' => 'attachment_file_missing', 'table' => 'attachments', 'id' => id, 'detail' => detail }
            next({ 'attachment_id' => id, 'sha256' => nil, 'bytes' => nil, 'status' => 'missing' })
          end
          begin
            digest, bytes = @writer.add_asset(path)
          rescue SystemCallError => error
            @gaps << { 'code' => 'attachment_unreadable', 'table' => 'attachments', 'id' => id,
                       'detail' => detail.merge('error' => error.class.name) }
            next({ 'attachment_id' => id, 'sha256' => nil, 'bytes' => nil, 'status' => 'unreadable' })
          end
          if row['filesize'] && row['filesize'].to_i != bytes
            @gaps << { 'code' => 'attachment_size_mismatch', 'table' => 'attachments', 'id' => id,
                       'detail' => { 'filesize' => row['filesize'], 'bytes' => bytes } }
          end
          stored = row['digest'].to_s.downcase
          if stored.match?(/\A[0-9a-f]{64}\z/) && stored != digest
            @gaps << { 'code' => 'attachment_digest_mismatch', 'table' => 'attachments', 'id' => id,
                       'detail' => { 'digest' => stored, 'sha256' => digest } }
          end
          { 'attachment_id' => id, 'sha256' => digest, 'bytes' => bytes, 'status' => 'present' }
        end
        @writer.write_asset_index(index)
      end

      def verify_counts!
        mismatches = @stats.reject { |table, rows| @reader.count(table) == rows }
        return if mismatches.empty?

        raise "row counts changed during the capture: #{mismatches.keys.join(', ')}"
      end
    end

    # Counts and structure of the instance, without content.
    class Inventory
      def initialize(reader)
        @reader = reader
      end

      def build
        {
          'generator' => GENERATOR,
          'generated_at' => Time.now.utc,
          'platform' => platform,
          'settings' => settings,
          'plugins' => plugins,
          'tables' => @reader.tables.to_h { |table| [table, @reader.count(table)] },
          'trackers' => trackers,
          'statuses' => statuses,
          'custom_fields' => custom_fields,
          'roles' => roles,
          'projects' => projects,
          'journals' => journals,
          'wiki' => wiki,
          'attachments' => attachments,
          'users' => users,
          'cosmosys' => cosmosys,
          'tags' => tags,
          'text' => text
        }
      end

      def self.summary(inventory)
        platform = inventory.fetch('platform')
        lines = []
        lines << "Redmine #{platform['redmine_version']}, Rails #{platform['rails_version']}, Ruby #{platform['ruby_version']}, " \
                 "#{platform.dig('database', 'adapter')} #{platform.dig('database', 'version')}"
        settings = inventory.fetch('settings')
        lines << "text_formatting=#{settings['text_formatting'].inspect} wiki_compression=#{settings['wiki_compression'].inspect} " \
                 "default_language=#{settings['default_language'].inspect}"
        lines << 'Plugins: ' + inventory.fetch('plugins').map { |plugin| "#{plugin['id']} #{plugin['version']}" }.join(', ')
        lines << "Trackers: #{inventory.fetch('trackers').map { |tracker| "#{tracker['name']} (#{tracker['issues']})" }.join(', ')}"
        lines << "Statuses: #{inventory.fetch('statuses').map { |status| "#{status['name']} (#{status['issues']})" }.join(', ')}"
        projects = inventory.fetch('projects')
        lines << "Projects: #{projects['count']} (#{projects['roots']} roots, depth #{projects['max_depth']})"
        tables = inventory.fetch('tables')
        lines << "Issues: #{tables['issues']}, relations: #{tables['issue_relations']}, documents: #{tables['documents']}, " \
                 "versions: #{tables['versions']}, categories: #{tables['issue_categories']}"
        journals = inventory.fetch('journals')
        lines << "Journals: #{journals['count']} (#{journals['with_notes']} with notes, #{journals['private_notes']} private, " \
                 "#{journals['private_notes_with_details']} private with details); details by property: " +
                 journals.fetch('details_by_property').map { |property, count| "#{property}=#{count}" }.join(', ')
        wiki = inventory.fetch('wiki')
        lines << "Wiki: #{wiki['pages']} pages, #{wiki['versions']} versions, #{wiki['pages_with_version_gaps']} pages with gaps " \
                 "(#{wiki['missing_versions']} missing versions), compression #{wiki['compression'].inspect}"
        attachments = inventory.fetch('attachments')
        lines << "Attachments: #{attachments['count']} (#{attachments['bytes']} bytes), #{attachments['missing_files']} without file"
        users = inventory.fetch('users')
        lines << "Users: #{users['count']} (#{users['by_status'].map { |status, count| "#{status}=#{count}" }.join(', ')}), " \
                 "#{users['admins']} admins, #{users['with_2fa']} with 2FA, #{users['with_auth_source']} external auth, " \
                 "#{users['groups']} groups; time entries: #{tables['time_entries']}, watchers: #{tables['watchers']}, members: #{tables['members']}"
        text = inventory.fetch('text')
        lines << "Ambiguous Markdown tables: #{text['ambiguous_markdown_tables']} in #{text['objects_with_ambiguous_markdown_tables']} texts"
        lines.join("\n")
      end

      private

      def platform
        database = { 'adapter' => @reader.connection.adapter_name }
        if @reader.mysql?
          database['version'] = @reader.value('SELECT VERSION()')
          database['charset'] = @reader.value('SELECT @@character_set_database')
          database['collation'] = @reader.value('SELECT @@collation_database')
          database['time_zone'] = @reader.value('SELECT @@session.time_zone')
          database['system_time_zone'] = @reader.value('SELECT @@system_time_zone')
        elsif @reader.postgresql?
          database['version'] = @reader.value('SHOW server_version')
          database['time_zone'] = @reader.value('SHOW TimeZone')
        end
        {
          'redmine_version' => Redmine::VERSION.to_s,
          'rails_version' => Rails.version,
          'ruby_version' => RUBY_VERSION,
          'database' => database,
          'time' => {
            'default_timezone' => ActiveRecord::Base.default_timezone.to_s,
            'process_utc_offset' => Time.now.utc_offset,
            'tz' => ENV['TZ']
          }
        }
      end

      def settings
        names = %w[text_formatting wiki_compression default_language attachment_max_size
                   cross_project_issue_relations cross_project_subtasks parent_issue_dates
                   parent_issue_priority parent_issue_done_ratio issue_done_ratio
                   login_required self_registration password_min_length twofa
                   unsubscribe user_format default_projects_public default_projects_modules
                   default_projects_tracker_ids non_working_week_days timespan_format
                   commit_ref_keywords commit_fix_keywords]
        names.each_with_object({}) do |name, result|
          next unless Setting.respond_to?(name)

          value = Setting.public_send(name)
          result[name] = value.is_a?(Symbol) ? value.to_s : value
        end
      end

      def plugins
        migrations = Hash.new(0)
        if @reader.table?('schema_migrations')
          @reader.rows('SELECT version FROM schema_migrations').each do |row|
            plugin = row['version'].to_s[/-(.+)\z/, 1]
            migrations[plugin || '(core)'] += 1
          end
        end
        Redmine::Plugin.all.map do |plugin|
          { 'id' => plugin.id.to_s, 'name' => plugin.name.to_s, 'version' => plugin.version.to_s,
            'directory' => File.basename(plugin.directory.to_s), 'migrations' => migrations[plugin.id.to_s] }
        end.sort_by { |entry| entry['id'] } + [{ 'id' => '(core)', 'migrations' => migrations['(core)'] }]
      end

      def grouped_counts(sql)
        @reader.rows(sql).each_with_object({}) { |row, result| result[row['k'].to_s] = row['c'].to_i }
      end

      def trackers
        counts = grouped_counts('SELECT tracker_id AS k, COUNT(*) AS c FROM issues GROUP BY tracker_id')
        @reader.rows('SELECT id, name, position, default_status_id FROM trackers ORDER BY position, id').map do |row|
          { 'id' => row['id'], 'name' => row['name'], 'position' => row['position'],
            'default_status_id' => row['default_status_id'], 'issues' => counts[row['id'].to_s].to_i }
        end
      end

      def statuses
        counts = grouped_counts('SELECT status_id AS k, COUNT(*) AS c FROM issues GROUP BY status_id')
        @reader.rows('SELECT id, name, is_closed, position FROM issue_statuses ORDER BY position, id').map do |row|
          { 'id' => row['id'], 'name' => row['name'], 'is_closed' => LegacySnapshot::Values.boolean(row['is_closed']),
            'issues' => counts[row['id'].to_s].to_i }
        end
      end

      def custom_fields
        values = grouped_counts("SELECT custom_field_id AS k, COUNT(*) AS c FROM custom_values WHERE value IS NOT NULL AND value <> '' GROUP BY custom_field_id")
        trackers = Hash.new { |hash, key| hash[key] = [] }
        if @reader.table?('custom_fields_trackers')
          names = @reader.rows('SELECT id, name FROM trackers').to_h { |row| [row['id'], row['name']] }
          @reader.rows('SELECT custom_field_id, tracker_id FROM custom_fields_trackers').each do |row|
            trackers[row['custom_field_id']] << names[row['tracker_id']]
          end
        end
        @reader.rows('SELECT id, type, name, field_format, multiple, is_required, is_for_all FROM custom_fields ORDER BY type, position, id').map do |row|
          { 'id' => row['id'], 'type' => row['type'], 'name' => row['name'], 'field_format' => row['field_format'],
            'multiple' => LegacySnapshot::Values.boolean(row['multiple']),
            'is_required' => LegacySnapshot::Values.boolean(row['is_required']),
            'is_for_all' => LegacySnapshot::Values.boolean(row['is_for_all']),
            'trackers' => trackers[row['id']].compact.sort, 'values' => values[row['id'].to_s].to_i }
        end
      end

      def roles
        members = if @reader.table?('member_roles')
                    grouped_counts('SELECT role_id AS k, COUNT(*) AS c FROM member_roles GROUP BY role_id')
                  else
                    {}
                  end
        @reader.rows('SELECT id, name, builtin FROM roles ORDER BY position, id').map do |row|
          { 'id' => row['id'], 'name' => row['name'], 'builtin' => row['builtin'].to_i,
            'member_roles' => members[row['id'].to_s].to_i }
        end
      end

      def projects
        rows = @reader.rows('SELECT id, parent_id, status, is_public FROM projects')
        parents = rows.to_h { |row| [row['id'], row['parent_id']] }
        depth = lambda do |id|
          level = 0
          seen = {}
          while (id = parents[id]) && !seen[id]
            seen[id] = true
            level += 1
          end
          level
        end
        modules = grouped_counts('SELECT name AS k, COUNT(*) AS c FROM enabled_modules GROUP BY name')
        {
          'count' => rows.length,
          'roots' => rows.count { |row| row['parent_id'].nil? },
          'max_depth' => rows.map { |row| depth.call(row['id']) }.max.to_i,
          'public' => rows.count { |row| LegacySnapshot::Values.boolean(row['is_public']) },
          'by_status' => rows.group_by { |row| row['status'].to_s }.transform_values(&:length),
          'enabled_modules' => modules
        }
      end

      def journals
        result = {
          'count' => @reader.count('journals'),
          'by_journalized_type' => grouped_counts('SELECT journalized_type AS k, COUNT(*) AS c FROM journals GROUP BY journalized_type'),
          'with_notes' => @reader.value("SELECT COUNT(*) FROM journals WHERE notes IS NOT NULL AND notes <> ''").to_i,
          'private_notes' => @reader.value("SELECT COUNT(*) FROM journals WHERE private_notes = #{true_literal}").to_i,
          'private_notes_with_details' => @reader.value(
            "SELECT COUNT(DISTINCT j.id) FROM journals j JOIN journal_details d ON d.journal_id = j.id WHERE j.private_notes = #{true_literal}"
          ).to_i,
          'without_notes_or_details' => @reader.value(
            "SELECT COUNT(*) FROM journals j WHERE (j.notes IS NULL OR j.notes = '') AND NOT EXISTS (SELECT 1 FROM journal_details d WHERE d.journal_id = j.id)"
          ).to_i,
          'orphan_issue_journals' => @reader.value(
            "SELECT COUNT(*) FROM journals j WHERE j.journalized_type = 'Issue' AND NOT EXISTS (SELECT 1 FROM issues i WHERE i.id = j.journalized_id)"
          ).to_i,
          'details_by_property' => grouped_counts('SELECT property AS k, COUNT(*) AS c FROM journal_details GROUP BY property')
        }
        result['attr_keys'] = grouped_counts("SELECT prop_key AS k, COUNT(*) AS c FROM journal_details WHERE property = 'attr' GROUP BY prop_key")
        field_names = @reader.rows('SELECT id, name FROM custom_fields').to_h { |row| [row['id'].to_s, row['name']] }
        result['cf_fields'] = grouped_counts("SELECT prop_key AS k, COUNT(*) AS c FROM journal_details WHERE property = 'cf' GROUP BY prop_key")
                              .each_with_object({}) { |(id, count), fields| fields[field_names.fetch(id, "(deleted field #{id})")] = count }
        result['relation_types'] = grouped_counts("SELECT prop_key AS k, COUNT(*) AS c FROM journal_details WHERE property = 'relation' GROUP BY prop_key")
        result
      end

      def wiki
        return { 'present' => false } unless @reader.table?('wiki_content_versions')

        versions = @reader.rows(
          'SELECT wiki_content_id AS id, COUNT(*) AS c, MIN(version) AS lo, MAX(version) AS hi FROM wiki_content_versions GROUP BY wiki_content_id'
        )
        gaps = versions.select { |row| row['lo'].to_i != 1 || row['c'].to_i != row['hi'].to_i }
        current = @reader.rows('SELECT id, version FROM wiki_contents').to_h { |row| [row['id'], row['version'].to_i] }
        mismatched = versions.count { |row| current.key?(row['id']) && current[row['id']] != row['hi'].to_i }
        {
          'present' => true,
          'wikis' => @reader.count('wikis'),
          'pages' => @reader.count('wiki_pages'),
          'contents' => current.length,
          'versions' => versions.sum { |row| row['c'].to_i },
          'pages_with_version_gaps' => gaps.length,
          'missing_versions' => gaps.sum { |row| row['hi'].to_i - row['c'].to_i },
          'contents_not_matching_last_version' => mismatched,
          'contents_without_versions' => (current.keys - versions.map { |row| row['id'] }).length,
          'compression' => grouped_counts("SELECT COALESCE(compression, '') AS k, COUNT(*) AS c FROM wiki_content_versions GROUP BY compression"),
          'redirects' => @reader.table?('wiki_redirects') ? @reader.count('wiki_redirects') : 0
        }
      end

      def attachments
        rows = @reader.rows('SELECT disk_directory, disk_filename, filesize, container_type FROM attachments')
        missing = rows.count do |row|
          row['disk_filename'].to_s.empty? ||
            !File.file?(File.join(Attachment.storage_path, row['disk_directory'].to_s, row['disk_filename'].to_s))
        end
        {
          'count' => rows.length,
          'bytes' => rows.sum { |row| row['filesize'].to_i },
          'by_container_type' => rows.group_by { |row| row['container_type'].to_s }.transform_values(&:length),
          'missing_files' => missing
        }
      end

      def users
        users = @reader.rows("SELECT * FROM users WHERE type = 'User'")
        statuses = { 1 => 'active', 2 => 'registered', 3 => 'locked' }
        {
          'count' => users.length,
          'by_status' => users.group_by { |row| statuses.fetch(row['status'].to_i, row['status'].to_s) }.transform_values(&:length),
          'admins' => users.count { |row| LegacySnapshot::Values.boolean(row['admin']) },
          'with_2fa' => users.count { |row| !row['twofa_scheme'].to_s.empty? },
          'with_auth_source' => users.count { |row| !row['auth_source_id'].nil? },
          'without_password' => users.count { |row| row['hashed_password'].to_s.empty? },
          'password_formats' => users.group_by { |row| "#{row['hashed_password'].to_s.length}/#{row['salt'].to_s.length}" }
                                     .transform_values(&:length),
          'must_change_password' => users.count { |row| LegacySnapshot::Values.boolean(row['must_change_passwd']) },
          'other_principals' => grouped_counts("SELECT type AS k, COUNT(*) AS c FROM users WHERE type <> 'User' GROUP BY type"),
          'groups' => @reader.value("SELECT COUNT(*) FROM users WHERE type = 'Group'").to_i,
          'group_memberships' => @reader.table?('groups_users') ? @reader.count('groups_users') : 0,
          'email_addresses' => @reader.table?('email_addresses') ? @reader.count('email_addresses') : 0
        }
      end

      def cosmosys
        result = {}
        %w[cosmosys_issues cosmosys_projects cosmosys_trackers cosmosys_users cosmosys_versions cosmosys_documents
           cosmosys_project_gits csys_reqs csys_poris].each do |table|
          result[table] = @reader.table?(table) ? @reader.count(table) : nil
        end
        if @reader.column?('cosmosys_issues', 'relations_on_close')
          result['relations_on_close'] = @reader.value(
            "SELECT COUNT(*) FROM cosmosys_issues WHERE relations_on_close IS NOT NULL AND relations_on_close <> '' AND relations_on_close <> '[]'"
          ).to_i
        end
        result
      end

      def tags
        result = {}
        %w[tags taggings additional_tags additional_taggings].each do |table|
          next unless @reader.table?(table)

          result[table] = @reader.count(table)
          if @reader.column?(table, 'taggable_type')
            result["#{table}_by_type"] = grouped_counts("SELECT taggable_type AS k, COUNT(*) AS c FROM #{@reader.quote_table(table)} GROUP BY taggable_type")
          end
        end
        result
      end

      # Indented Markdown table headers turn into code blocks under CommonMark.
      def text
        findings = 0
        objects = 0
        scan = lambda do |sql, column|
          @reader.rows(sql).each do |row|
            count = ambiguous_tables(row[column].to_s)
            findings += count
            objects += 1 if count.positive?
          end
        end
        scan.call('SELECT description FROM issues', 'description')
        scan.call("SELECT notes FROM journals WHERE notes IS NOT NULL AND notes <> ''", 'notes')
        scan.call('SELECT text FROM wiki_contents', 'text') if @reader.table?('wiki_contents')
        { 'ambiguous_markdown_tables' => findings, 'objects_with_ambiguous_markdown_tables' => objects }
      end

      def ambiguous_tables(text)
        lines = text.gsub("\r\n", "\n").split("\n", -1)
        lines.each_cons(2).count do |header, separator|
          ambiguous = header.match?(/\A[ \t]{4,}\|/) || (header.include?('|') && !header.lstrip.start_with?('|'))
          cells = separator.strip.sub(/\A\|/, '').sub(/\|\z/, '').split('|').map(&:strip)
          ambiguous && cells.length >= 2 && cells.all? { |cell| cell.match?(/\A:?-{3,}:?\z/) }
        end
      end

      def true_literal
        @reader.connection.quoted_true
      end
    end
  end
end

SnapshotsGen::Exporter.main(ARGV) if defined?(Rails) && !defined?(SNAPSHOTS_GEN_LIBRARY_ONLY)
