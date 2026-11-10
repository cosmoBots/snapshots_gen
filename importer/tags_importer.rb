# frozen_string_literal: true

# Tags importer: writes a tags package (.cstags, docs/cstags-format.md) into
# the tag plugin of the new instance (additional_tags 4.6 on PostgreSQL).
#
# It never goes through the plugin's API: tag_list=, the tag lookups by
# LOWER(name) and the model normalization merge names that differ in case,
# split names at commas and strip spaces. Rows go straight into the two tag
# tables, in one transaction, and are read back and compared before the
# commit. Nothing printed here holds a tag name: tags are named by their
# source id and the first hex digits of the SHA-256 of their name.

require 'digest'
require 'json'
require 'set'
require 'time'
require_relative 'history_importer'
require_relative '../converter/lib/snapshots_gen/tags_package'

module SnapshotsGen
  module Importer
    class TagsRun
      TAGS_TABLE = 'additional_tags'
      TAGGINGS_TABLE = 'additional_taggings'
      SETTING_NAME = 'plugin_additional_tags'
      ROLES_TABLE = 'roles'
      # The profile of the package names the plugin generation it was checked
      # against; any other must be validated before trusting this importer.
      PLUGIN_VERSIONS = { 'additional_tags' => '4.6.', 'additionals' => nil }.freeze
      # Column => [type, nullable], exactly as the 4.6.0 migrations leave them.
      SCHEMA = {
        TAGS_TABLE => { 'id' => [:integer, false], 'name' => [:string, false], 'taggings_count' => [:integer, true],
                        'created_at' => [:datetime, false], 'updated_at' => [:datetime, false] },
        TAGGINGS_TABLE => { 'id' => [:integer, false], 'tag_id' => [:integer, false], 'taggable_type' => [:string, false],
                            'taggable_id' => [:integer, false], 'created_at' => [:datetime, true] }
      }.freeze
      UNIQUE_INDEXES = { TAGS_TABLE => [%w[name]], TAGGINGS_TABLE => [%w[tag_id taggable_id taggable_type]] }.freeze
      # Tables this import may write to; anything else written is a failure.
      # In roles it only adds tag permissions (role_differences).
      WRITABLE = [TAGS_TABLE, TAGGINGS_TABLE, 'settings', ROLES_TABLE].freeze
      SIDE_EFFECTS = %w[enqueue.active_job enqueue_at.active_job enqueue_all.active_job perform_start.active_job
                        deliver.action_mailer process.action_mailer].freeze
      BATCH = 500
      LISTED = 40

      # Bare models over the plugin's tables: no callbacks, no validations, no
      # normalization of names, no counter cache.
      class TagRow < ActiveRecord::Base
        self.table_name = TAGS_TABLE
      end

      class TaggingRow < ActiveRecord::Base
        self.table_name = TAGGINGS_TABLE
        self.inheritance_column = nil
      end

      Tag = Struct.new(:source_id, :name, :created_at, :updated_at)
      Tagging = Struct.new(:source_id, :tag, :object_key, :created_at)
      State = Struct.new(:tags, :taggings, :setting)

      attr_reader :log

      def initialize(path, options = {})
        @path = File.expand_path(path.to_s)
        @options = options
        @log = []
        @events = []
      end

      def say(message)
        puts message
        @log << message
      end

      def call
        $stdout.sync = true
        ActionMailer::Base.perform_deliveries = false
        load_package!
        check_destination!
        watching_side_effects do
          in_one_transaction do
            # Nobody else writes tags while this runs; taken before the first
            # query, so the snapshot of the transaction already has the lock.
            connection.execute("LOCK TABLE #{TAGS_TABLE}, #{TAGGINGS_TABLE} IN SHARE ROW EXCLUSIVE MODE")
            @before = state
            @roles_before = role_state
            @others_before = fingerprint
            resolve_objects!
            check_history!
            plan!
            plan_roles!
            say "Preflight passed: #{@managed.length} objects found (#{count_type('Issue')} items, #{count_type('WikiPage')} wiki pages), " \
                "#{@tags.length - @new_tags.length} of #{@tags.length} tags and #{@taggings.length - @new_taggings.length} of " \
                "#{@taggings.length} taggings already there, no conflicts."
            write!
            fail_with('verification failed, nothing was written', verify!)
            raise ActiveRecord::Rollback if dry_run?
          end
          finish!
        end
        write_report!
      end

      private

      # REPEATABLE READ: the transaction sees the database as it was when it
      # started plus its own writes, so "nothing else changed" is about this
      # import and not about someone else's session.
      def in_one_transaction(&block)
        ActiveRecord::Base.transaction(isolation: :repeatable_read, &block)
      rescue ActiveRecord::StatementInvalid => error
        # The message of the database may quote the row it refused, tag name
        # included: only the kind of error and the constraint are shown.
        constraint = error.cause.respond_to?(:result) && error.cause.result&.error_field(PG::Result::PG_DIAG_CONSTRAINT_NAME)
        raise Error, "the database refused a write and everything was rolled back: #{error.class}#{constraint ? " (#{constraint})" : ''}"
      end

      def dry_run?
        @options['dry_run'] == true
      end

      def connection
        ActiveRecord::Base.respond_to?(:lease_connection) ? ActiveRecord::Base.lease_connection : ActiveRecord::Base.connection
      end

      def digest(name)
        Digest::SHA256.hexdigest(name.to_s)[0, 12]
      end

      def tag_label(tag)
        "tag #{tag.source_id} (sha256 #{digest(tag.name)})"
      end

      def fail_with(title, problems)
        return if problems.empty?

        listed = problems.first(LISTED)
        listed << "... and #{problems.length - LISTED} more" if problems.length > LISTED
        raise Error, "#{title} (#{problems.length}):\n  #{listed.join("\n  ")}"
      end

      # --- package -----------------------------------------------------------

      def load_package!
        raise Error, "#{@path} is not a file" unless File.file?(@path)

        directory = File.expand_path(@options['packages'] || File.dirname(@path))
        raise Error, "#{directory} is not a directory" unless File.directory?(directory)

        names = Dir.children(directory).sort
        histories = names.select { |name| name.end_with?('.cshistory') }.map { |name| File.join(directory, name) }
        @csys_paths = names.select { |name| name.end_with?('.csys') }.map { |name| File.join(directory, name) }
        unless histories.length == 1
          raise Error, "#{directory} must hold the .cshistory of this conversion and only that one (found #{histories.length})"
        end

        @history_path = histories.first
        # Always given, never nil: the verifier skips a dependency it is not given.
        @package = TagsPackage.read(@path, history: @history_path, csys: @csys_paths)
        content = @package.content
        unless @package.importable?
          codes = @package.rows.fetch('anomalies').select { |row| row['severity'] == 'blocking' }.map { |row| row['code'] }.tally
          raise Error, "the tags package is not importable: #{codes.map { |code, count| "#{code} #{count}" }.join(', ')} " \
                       '(see the conversion report)'
        end
        parse_rows!
        counts = content.fetch('counts')
        say "Package: #{File.basename(@path)} (#{counts['source_tags']} tags, #{counts['source_taggings']} taggings, " \
            "#{counts['tagged_objects']} tagged objects of #{counts['objects']}), content #{@package.manifest['content_sha256'][0, 12]}, " \
            "with #{File.basename(@history_path)} and #{@csys_paths.length} .csys"
        warnings = @package.rows.fetch('anomalies').reject { |row| row['severity'] == 'blocking' }.group_by { |row| row['code'] }
        warnings.sort.each do |code, rows|
          say "  #{rows.first['severity']} #{code} (#{rows.length}): #{TagsPackage::ANOMALIES.fetch(code).last}"
        end
      rescue TagsPackage::Error => error
        raise Error, error.message
      end

      def timestamp(value, label, required)
        return nil if value.nil? && !required

        Time.iso8601(value)
      rescue ArgumentError, TypeError
        raise Error, "#{label} is not a timestamp the destination can hold"
      end

      def parse_rows!
        rows = @package.rows
        @tags = rows.fetch('tags').map do |row|
          name = row['name']
          problem = TagsPackage.name_problem(name)
          raise Error, "tag #{row['id']} has a name the destination cannot hold exactly (#{problem.last})" if problem

          Tag.new(row['id'], name, timestamp(row['created_at'], "created_at of tag #{row['id']}", true),
                  timestamp(row['updated_at'], "updated_at of tag #{row['id']}", true))
        end
        raise Error, 'two tags of the package have the same name' unless @tags.map(&:name).uniq.length == @tags.length

        by_id = @tags.to_h { |tag| [tag.source_id, tag] }
        @objects = rows.fetch('objects').select { |row| row['target'] }.to_h { |row| [row['id'], row] }
        @taggings = rows.fetch('taggings').map do |row|
          tag = by_id[row['tag_id']]
          raise Error, "tagging #{row['id']} names a tag that is not in the package" unless tag
          raise Error, "tagging #{row['id']} is on an object without destination" unless @objects.key?(row['object_id'])
          unless row['context'] == TagsPackage::PROFILE['implicit_context'] && row['tagger_id'].nil? && row['tagger_type'].nil?
            raise Error, "tagging #{row['id']} is outside the profile of the package"
          end

          Tagging.new(row['id'], tag, row['object_id'], timestamp(row['created_at'], "created_at of tagging #{row['id']}", false))
        end
        @expected = Hash.new { |hash, key| hash[key] = [] }
        @taggings.each { |tagging| @expected[tagging.object_key] << tagging }
        @settings = @package.content.dig('source', 'settings')
        @source_roles = rows.fetch('roles')
      end

      # --- destination: plugin, migrations, schema and collation ---------------

      def check_destination!
        problems = []
        unless connection.adapter_name == 'PostgreSQL'
          raise Error, "the profile of the package is for PostgreSQL; this instance uses #{connection.adapter_name}"
        end

        encoding = connection.select_value('SHOW server_encoding')
        problems << "the database encoding is #{encoding}, not UTF8" unless encoding == 'UTF8'
        versions = check_plugins(problems)
        fail_with('the tag plugin is not ready in this instance (install the "tags" option of the deploy and migrate)', problems)
        check_schema(problems)
        collation = check_collation(problems)
        fail_with('the tag tables are not the ones this importer knows; nothing was written', problems)
        say "Destination: #{versions.join(', ')}; PostgreSQL #{connection.select_value('SHOW server_version')}, " \
            "name collation #{collation} (deterministic), all plugin migrations applied"
      end

      def check_plugins(problems)
        applied = connection.select_values('SELECT version FROM schema_migrations').to_set
        PLUGIN_VERSIONS.filter_map do |id, version|
          plugin = begin
            Redmine::Plugin.find(id)
          rescue Redmine::PluginNotFound
            problems << "plugin #{id} is not installed"
            next
          end
          if version && !plugin.version.to_s.start_with?(version)
            problems << "plugin #{id} is #{plugin.version}; this importer is validated for #{version}x only"
          end
          directory = File.join(plugin.directory, 'db', 'migrate')
          migrations = File.directory?(directory) ? Dir.children(directory).filter_map { |name| name[/\A(\d+)_.+\.rb\z/, 1] } : []
          pending = migrations.reject { |number| applied.include?("#{number.to_i}-#{id}") }
          problems << "plugin #{id} has no migrations in #{directory}" if migrations.empty?
          problems << "plugin #{id} has #{pending.length} migrations not applied (#{pending.sort.join(', ')})" if pending.any?
          "#{id} #{plugin.version}"
        end.tap do
          { 'AdditionalTag' => TAGS_TABLE, 'AdditionalTagging' => TAGGINGS_TABLE }.each do |model, table|
            klass = model.safe_constantize
            problems << "the model #{model} of the tag plugin is not loaded" unless klass
            problems << "the model #{model} uses the table #{klass.table_name}, not #{table}" if klass && klass.table_name != table
          end
        end
      end

      def check_schema(problems)
        SCHEMA.each do |table, expected|
          unless connection.table_exists?(table)
            problems << "table #{table} does not exist"
            next
          end
          columns = connection.columns(table).to_h { |column| [column.name, column] }
          problems << "#{table} has columns #{columns.keys.sort.join(', ')}; expected #{expected.keys.sort.join(', ')}" unless columns.keys.sort == expected.keys.sort
          expected.each do |name, (type, null)|
            column = columns[name] || next
            problems << "#{table}.#{name} is #{column.type}, expected #{type}" unless column.type == type
            problems << "#{table}.#{name} #{column.null ? 'allows' : 'does not allow'} NULL" unless column.null == null
          end
          problems << "#{table} has primary key #{connection.primary_key(table).inspect}" unless connection.primary_key(table) == 'id'
          unique = connection.indexes(table).select(&:unique).map do |index|
            index.columns.is_a?(Array) && index.where.nil? ? index.columns.sort : "#{index.name} (expression or partial)"
          end
          unless unique.sort_by(&:to_s) == UNIQUE_INDEXES.fetch(table).map(&:sort)
            problems << "#{table} has unique indexes #{unique.inspect}; expected #{UNIQUE_INDEXES.fetch(table).inspect}"
          end
          checks = connection.check_constraints(table)
          problems << "#{table} has #{checks.length} check constraints this importer does not know" if checks.any?
          triggers = connection.select_value(<<~SQL.squish).to_i
            SELECT COUNT(*) FROM pg_trigger WHERE tgrelid = #{connection.quote(table)}::regclass AND NOT tgisinternal
          SQL
          problems << "#{table} has #{triggers} triggers this importer does not know" if triggers.positive?
          rules = connection.select_value("SELECT COUNT(*) FROM pg_rules WHERE tablename = #{connection.quote(table)}").to_i
          problems << "#{table} has #{rules} rewrite rules this importer does not know" if rules.positive?
        end
        return if problems.any?

        keys = connection.foreign_keys(TAGGINGS_TABLE).map { |key| [key.column, key.to_table, key.primary_key] }
        problems << "#{TAGGINGS_TABLE} has foreign keys #{keys.inspect}" unless keys == [['tag_id', TAGS_TABLE, 'id']]
        limit = connection.columns(TAGS_TABLE).find { |column| column.name == 'name' }.limit
        longest = @tags.map { |tag| tag.name.length }.max.to_i
        problems << "#{TAGS_TABLE}.name holds #{limit} characters; the longest name of the package has #{longest}" if limit && longest > limit
      end

      # Every name of the package must stay apart under the collation that the
      # unique index of the destination really uses, and equal there must mean
      # equal byte for byte.
      def check_collation(problems)
        return nil if problems.any?

        row = connection.select_rows(<<~SQL.squish).first
          SELECT n.nspname, c.collname, c.collisdeterministic
          FROM pg_attribute a
          JOIN pg_collation c ON c.oid = a.attcollation
          JOIN pg_namespace n ON n.oid = c.collnamespace
          WHERE a.attrelid = #{connection.quote(TAGS_TABLE)}::regclass AND a.attname = 'name'
        SQL
        unless row
          problems << "#{TAGS_TABLE}.name has no collation"
          return nil
        end
        schema, name, deterministic = row
        collation = "#{connection.quote_column_name(schema)}.#{connection.quote_column_name(name)}"
        unless [true, 't'].include?(deterministic)
          problems << "#{TAGS_TABLE}.name uses the collation #{name}, which is not deterministic: names that differ " \
                      'would be equal there'
        end
        @tags.map(&:name).each_slice(BATCH * 4).with_index do |names, index|
          distinct = connection.select_value(ActiveRecord::Base.sanitize_sql_array([
            "SELECT COUNT(*) FROM (SELECT DISTINCT x COLLATE #{collation} FROM unnest(ARRAY[?]::varchar[]) AS u(x)) d", names
          ])).to_i
          next if distinct == names.length

          problems << "#{names.length - distinct} names of the package (batch #{index + 1}) are equal to another under the collation #{name}"
        end
        name
      end

      # --- before and after ----------------------------------------------------

      def state
        State.new(
          TagRow.order(:id).pluck(:id, :name, :taggings_count, :created_at, :updated_at),
          TaggingRow.order(:id).pluck(:id, :tag_id, :taggable_type, :taggable_id, :created_at),
          connection.select_rows("SELECT id, value, updated_on::text FROM settings WHERE name = #{connection.quote(SETTING_NAME)} ORDER BY id")
        )
      end

      # Every role: the digest of all its columns but permissions, the raw
      # permissions and the permissions as Redmine reads them.
      def role_state
        raw = connection.select_rows(<<~SQL.squish)
          SELECT r.id, md5((to_jsonb(r) - 'permissions')::text), r.permissions FROM #{ROLES_TABLE} r ORDER BY r.id
        SQL
        permissions = Role.unscoped.pluck(:id, :permissions).to_h { |id, list| [id, Array(list).map(&:to_s)] }
        raw.to_h { |id, others, text| [id.to_i, [others, text, permissions[id.to_i]]] }
      end

      # Row count and content digest of every other table of the database (and
      # of every other setting). The transaction is REPEATABLE READ, so it only
      # sees its own writes: any difference between two fingerprints was made
      # by this import. Roles are compared apart, column by column
      # (role_differences).
      def fingerprint
        (connection.tables - [TAGS_TABLE, TAGGINGS_TABLE, ROLES_TABLE]).sort.to_h do |table|
          where = table == 'settings' ? " WHERE name <> #{connection.quote(SETTING_NAME)}" : ''
          row = connection.select_rows(<<~SQL.squish).first
            SELECT COUNT(*), md5(COALESCE(string_agg(h, '' ORDER BY h), ''))
            FROM (SELECT md5(x::text) AS h FROM #{connection.quote_table_name(table)} x#{where}) s
          SQL
          [table, row.map(&:to_s)]
        end
      end

      def watching_side_effects
        subscribers = SIDE_EFFECTS.map do |name|
          ActiveSupport::Notifications.subscribe(name) do |*arguments|
            payload = arguments.last
            subject = payload.is_a?(Hash) && (payload[:job]&.class&.name || payload[:mailer])
            @events << [name, subject].compact.join(' ')
          end
        end
        yield
      ensure
        Array(subscribers).each { |subscriber| ActiveSupport::Notifications.unsubscribe(subscriber) }
      end

      # --- identities ------------------------------------------------------------

      def count_type(type)
        @managed.keys.count { |key| key.first == type }
      end

      # Every object of the package with a destination must be exactly one
      # issue (project and CSID, ignoring case) or one wiki page (project and
      # identical title, never a redirect).
      def resolve_objects!
        problems = []
        identifiers = @objects.values.map { |row| row.dig('target', 'project_identifier') }.uniq
        projects = Project.unscoped.where(identifier: identifiers).pluck(:identifier, :id).group_by(&:first)
        project_id = lambda do |identifier|
          found = projects.fetch(identifier, [])
          found.length == 1 ? found.first.last : nil
        end
        identifiers.each do |identifier|
          found = projects.fetch(identifier, []).length
          problems << "project #{identifier}: #{found.zero? ? 'not imported (import every .csys first)' : "#{found} projects with that identifier"}" unless found == 1
        end
        project_ids = identifiers.filter_map { |identifier| project_id.call(identifier) }
        issues = Hash.new { |hash, key| hash[key] = [] }
        Issue.unscoped.where(project_id: project_ids).pluck(:project_id, :csid, :id).each do |project, csid, id|
          issues[[project, csid.to_s.downcase]] << id unless csid.to_s.empty?
        end
        wikis = Wiki.unscoped.where(project_id: project_ids).pluck(:project_id, :id).group_by(&:first)
        pages = Hash.new { |hash, key| hash[key] = [] }
        WikiPage.unscoped.where(wiki_id: wikis.values.flatten(1).map(&:last)).pluck(:wiki_id, :title, :id).each do |wiki, title, id|
          pages[[wiki, title.to_s.downcase]] << [title, id]
        end

        @destination = {}
        @managed = Hash.new { |hash, key| hash[key] = [] }
        @objects.each do |object_id, row|
          target = row.fetch('target')
          project = project_id.call(target['project_identifier']) || next
          found = if target['type'] == 'Issue'
                    candidates = issues.fetch([project, target['csid'].downcase], [])
                    problems << "#{object_id}: #{candidates.length} items with CSID #{target['csid']} in #{target['project_identifier']}" unless candidates.length == 1
                    candidates.first if candidates.length == 1
                  else
                    wiki = wikis.fetch(project, [])
                    if wiki.length != 1
                      problems << "#{object_id}: #{target['project_identifier']} has #{wiki.length} wikis"
                      next
                    end
                    candidates = pages.fetch([wiki.first.last, target['title'].downcase], [])
                    exact = candidates.select { |title, _id| title == target['title'] }
                    if candidates.length == 1 && exact.length == 1
                      exact.first.last
                    else
                      problems << "#{object_id}: #{exact.length} wiki pages with exactly that title in #{target['project_identifier']} " \
                                  "(#{candidates.length} ignoring case)"
                      nil
                    end
                  end
          next unless found

          key = [target['type'], found]
          @destination[object_id] = key
          @managed[key] << object_id
        end
        @managed.each do |key, object_ids|
          next if object_ids.length == 1 || object_ids.none? { |object_id| @expected.key?(object_id) }

          problems << "#{object_ids.join(', ')}: tagged objects that are one #{key.first} here (##{key.last})"
        end
        fail_with('objects of the package that are not exactly one object here; nothing was written', problems)
      end

      # The sibling history package must describe the same items, and the
      # history import must already have run: it is what gives every item its
      # source creation date.
      def check_history!
        problems = []
        pending = 0
        checked = 0
        Package.open(@history_path) do |history|
          identifiers = history.by_id('projects').transform_values { |row| row['identifier'] }
          items = history.rows('items').to_h { |row| [row['key'], row] }
          created = Issue.unscoped.where(id: @managed.keys.select { |key| key.first == 'Issue' }.map(&:last)).pluck(:id, :created_on).to_h
          @objects.each do |object_id, row|
            target = row.fetch('target')
            next unless target['type'] == 'Issue'

            item = items[target['item_key']]
            unless item && item['csid'] == target['csid'] && identifiers[item['project_id']] == target['project_identifier']
              problems << "#{object_id}: the history package does not have this item with the same project and CSID"
              next
            end
            next unless item['created_on']

            checked += 1
            pending += 1 unless created[@destination.fetch(object_id).last] == Time.iso8601(item['created_on'])
          end
        end
        fail_with('the tags package and the history package do not describe the same items', problems)
        return if pending.zero?

        raise Error, "the history is not imported yet: #{pending} of #{checked} items do not have their source creation date " \
                     '(import the history first, step 6.3)'
      end

      # --- plan: what is already there, what is missing, what conflicts --------

      def plan!
        problems = []
        existing = @before.tags.to_h { |id, name, _count, created_at, updated_at| [name, [id, created_at, updated_at]] }
        @tag_ids = {}
        @new_tags = []
        @tags.each do |tag|
          id, created_at, updated_at = existing[tag.name]
          if id.nil?
            @new_tags << tag
          elsif created_at == tag.created_at && updated_at == tag.updated_at
            @tag_ids[tag.source_id] = id
          else
            problems << "#{tag_label(tag)} already exists here as tag ##{id} with other dates"
          end
        end
        folded = @tags.group_by { |tag| tag.name.downcase }
        names = @tags.map(&:name).to_set
        @before.tags.each do |id, name, *_rest|
          next if names.include?(name) || !folded.key?(name.downcase)

          problems << "tag ##{id} of this instance differs only in case from #{tag_label(folded[name.downcase].first)}"
        end
        @foreign_tags = @before.tags.count { |_id, name, *_rest| !names.include?(name) }

        name_of = @before.tags.to_h { |id, name, *_rest| [id, name] }
        present = Hash.new { |hash, key| hash[key] = [] }
        @before.taggings.each { |id, tag_id, type, taggable_id, created_at| present[[type, taggable_id]] << [id, name_of[tag_id], created_at] }
        @new_taggings = []
        @managed.each do |key, object_ids|
          wanted = object_ids.flat_map { |object_id| @expected.fetch(object_id, []) }.to_h { |tagging| [tagging.tag.name, tagging] }
          found = Set.new
          present.fetch(key, []).each do |id, name, created_at|
            tagging = wanted[name]
            if tagging.nil?
              problems << "#{key.first} ##{key.last} (#{object_ids.join(', ')}) already has tagging ##{id}, which is not in the package"
            elsif tagging.created_at != created_at
              problems << "tagging ##{id} of #{key.first} ##{key.last} already exists with another date than tagging #{tagging.source_id} of the package"
            else
              found << name
            end
          end
          @new_taggings.concat(wanted.reject { |name, _tagging| found.include?(name) }.values)
        end
        fail_with('conflicts with tags that already exist in this instance; nothing was written', problems)
      end

      # Each destination role gets the tag permissions its source roles had
      # (several source roles on one destination: the union). Roles are
      # mapped as the history import maps memberships (Importer.role_target,
      # with the same roles=old:new), and the built-in Non member and
      # Anonymous roles to themselves. Permissions are only added, never
      # removed.
      def plan_roles!
        overrides = @options.fetch('roles', {})
        grants = {}
        @roles_without_destination = []
        @source_roles.each do |row|
          permissions = row['tag_permissions']
          next if permissions.nil? || permissions.empty?

          role = destination_role(row, overrides)
          unless role
            @roles_without_destination << "#{source_role_label(row)} (#{permissions.join(', ')})"
            next
          end
          grant = (grants[role.id] ||= { role: role, permissions: [], sources: [] })
          grant[:permissions] |= permissions
          grant[:sources] << source_role_label(row)
        end
        @role_grants = grants.values.sort_by { |grant| grant[:role].id }
        @role_changes = @role_grants.filter_map do |grant|
          missing = grant[:permissions].sort - Array(grant[:role].permissions).map(&:to_s)
          [grant[:role], missing, grant[:sources]] if missing.any?
        end
      end

      def destination_role(row, overrides)
        if row['builtin'] == 0
          row['name'].is_a?(String) ? Importer.role_target(row['name'], overrides) : nil
        elsif TagsPackage::BUILTIN_ROLES.key?(row['builtin'])
          found = Role.unscoped.where(builtin: row['builtin']).to_a
          found.length == 1 ? found.first : nil
        end
      end

      def source_role_label(row)
        name = row['name'].is_a?(String) ? row['name'] : "##{row['id']}"
        TagsPackage::BUILTIN_ROLES.key?(row['builtin']) ? "#{name} (built-in)" : name
      end

      # --- writing ---------------------------------------------------------------

      def write!
        by_name = @new_tags.to_h { |tag| [tag.name, tag] }
        # A new tag has no taggings here but those of the package.
        uses = @taggings.map { |tagging| tagging.tag.source_id }.tally
        @new_tags.each_slice(BATCH) do |tags|
          rows = tags.map do |tag|
            { 'name' => tag.name, 'taggings_count' => uses.fetch(tag.source_id, 0), 'created_at' => tag.created_at, 'updated_at' => tag.updated_at }
          end
          TagRow.insert_all!(rows, returning: %w[id name], record_timestamps: false).rows.each do |id, name|
            tag = by_name[name] || raise(Error, "the database stored a name that is not the one sent (tag ##{id}); nothing was written")
            @tag_ids[tag.source_id] = id
          end
        end
        missing = @tags.reject { |tag| @tag_ids.key?(tag.source_id) }
        raise Error, "#{missing.length} tags were not created; nothing was written" if missing.any?

        @new_taggings.each_slice(BATCH) do |taggings|
          TaggingRow.insert_all!(taggings.map do |tagging|
            type, id = @destination.fetch(tagging.object_key)
            { 'tag_id' => @tag_ids.fetch(tagging.tag.source_id), 'taggable_type' => type, 'taggable_id' => id, 'created_at' => tagging.created_at }
          end, record_timestamps: false)
        end
        # The counter of every tag of the package is the real count of all its
        # taggings, also of those that were already here and are not of the
        # package; only rows whose counter is wrong change.
        @counters_set = @tag_ids.values.each_slice(BATCH * 4).sum do |ids|
          connection.update(<<~SQL.squish)
            UPDATE #{TAGS_TABLE} t SET taggings_count = s.real
            FROM (SELECT t2.id, COUNT(g.id) AS real FROM #{TAGS_TABLE} t2 LEFT JOIN #{TAGGINGS_TABLE} g ON g.tag_id = t2.id
                  WHERE t2.id IN (#{ids.map { |id| Integer(id) }.join(', ')}) GROUP BY t2.id) s
            WHERE t.id = s.id AND t.taggings_count IS DISTINCT FROM s.real
          SQL
        end
        apply_settings!
        apply_roles!
        say "Tags: #{@new_tags.length} created, #{@tags.length - @new_tags.length} already there" \
            "#{@foreign_tags.positive? ? " (#{@foreign_tags} other tags of this instance left as they are)" : ''}. " \
            "Taggings: #{@new_taggings.length} created, #{@taggings.length - @new_taggings.length} already there. " \
            "Counters corrected: #{@counters_set}."
      end

      def current_setting(key)
        AdditionalTags.setting(key.to_sym)
      end

      # The source values of the plugin settings, stored as the settings page
      # stores them. A setting the conversion could not determine keeps the
      # value of this instance.
      def apply_settings!
        wanted = @settings.reject { |_key, entry| entry['provenance'] == 'unavailable' }.transform_values { |entry| entry['value'] }
        kept = @settings.keys - wanted.keys
        @setting_changes = wanted.filter_map { |key, value| [key, current_setting(key), value] unless current_setting(key) == value }
        if @setting_changes.any?
          Setting.send(:"#{SETTING_NAME}=", ActiveSupport::HashWithIndifferentAccess.new(Setting.send(SETTING_NAME.to_sym)).merge(wanted))
        end
        @wanted_settings = wanted
        say "Settings: #{@setting_changes.any? ? @setting_changes.map { |key, old, new| "#{key} #{old.inspect} -> #{new.inspect}" }.join(', ') : 'already as in the source'}" \
            "#{kept.any? ? "; not in the source, left as they are: #{kept.join(', ')}" : ''}."
      end

      def apply_roles!
        @role_changes.each do |role, missing, _sources|
          role.add_permission!(*missing.map(&:to_sym))
        rescue ActiveRecord::RecordInvalid => error
          raise Error, "the role #{role.name} could not be saved with its tag permissions " \
                       "(#{error.record.errors.full_messages.join('; ')}); nothing was written"
        end
        line = if @role_changes.any?
                 @role_changes.map { |role, missing, sources| "#{role.name} +#{missing.join(' +')} (from #{sources.join(', ')})" }.join('; ')
               elsif @role_grants.any?
                 "#{@role_grants.map { |grant| grant[:role].name }.join(', ')} already have the tag permissions of their source roles"
               else
                 'no source role had tag permissions'
               end
        say "Roles: #{line}."
      end

      # --- verification ----------------------------------------------------------

      # Roles may only have gained the planned tag permissions: every other
      # column is the same, the permissions of the other roles are the same
      # bytes, and the changed ones are the old list plus what was planned.
      def role_differences(now)
        problems = []
        added = @role_changes.to_h { |role, missing, _sources| [role.id, missing] }
        (@roles_before.keys | now.keys).sort.each do |id|
          was = @roles_before[id]
          is = now[id]
          unless was && is
            problems << "role ##{id} #{was ? 'is gone' : 'was created'}"
            next
          end
          problems << "role ##{id} changed outside its permissions" unless was[0] == is[0]
          if added.key?(id)
            expected = was[2] + added[id]
            problems << "role ##{id} has permissions #{is[2].sort.inspect}, expected #{expected.sort.inspect}" unless is[2] == expected
          elsif was[1] != is[1]
            problems << "role ##{id} changed its permissions and nothing had to change"
          end
        end
        problems
      end

      # Compares what the database holds now with the package and with what
      # was there before; returns the differences.
      def differences(now)
        problems = []
        before_tags = @before.tags.to_h { |row| [row.first, row] }
        package = @tags.to_h { |tag| [tag.name, tag] }
        seen = Hash.new(0)
        now.tags.each do |id, name, count, created_at, updated_at|
          seen[name] += 1
          tag = package[name]
          old = before_tags[id]
          if old && [name, created_at, updated_at] != old.values_at(1, 3, 4)
            problems << "tag ##{id}, which was already here, changed"
          elsif tag.nil? && old.nil?
            problems << "tag ##{id} (sha256 #{digest(name)}) was created and is not in the package"
          elsif tag && (created_at != tag.created_at || updated_at != tag.updated_at)
            problems << "#{tag_label(tag)} is tag ##{id} with other dates than the package"
          end
          problems << "tag ##{id}, which is not in the package, changed its counter" if tag.nil? && old && old[2] != count
        end
        (before_tags.keys - now.tags.map(&:first)).each { |id| problems << "tag ##{id}, which was already here, is gone" }
        @tags.each { |tag| problems << "#{tag_label(tag)} is #{seen[tag.name]} times in the catalog" unless seen[tag.name] == 1 }
        expected_size = @before.tags.length + @new_tags.length
        problems << "the catalog has #{now.tags.length} tags, expected #{expected_size}" unless now.tags.length == expected_size

        before_taggings = @before.taggings.to_h { |row| [row.first, row] }
        name_of = now.tags.to_h { |id, name, *_rest| [id, name] }
        by_object = Hash.new { |hash, key| hash[key] = [] }
        real = Hash.new(0)
        now.taggings.each do |row|
          id, tag_id, type, taggable_id, created_at = row
          old = before_taggings[id]
          problems << "tagging ##{id}, which was already here, changed" if old && old != row
          problems << "tagging ##{id} was created on #{type} ##{taggable_id}, which is not an object of the package" if old.nil? && !@managed.key?([type, taggable_id])
          problems << "tagging ##{id} names tag ##{tag_id}, which does not exist" unless name_of.key?(tag_id)
          by_object[[type, taggable_id]] << [name_of[tag_id].to_s, created_at]
          real[tag_id] += 1
        end
        (before_taggings.keys - now.taggings.map(&:first)).each { |id| problems << "tagging ##{id}, which was already here, is gone" }
        expected_size = @before.taggings.length + @new_taggings.length
        problems << "there are #{now.taggings.length} taggings, expected #{expected_size}" unless now.taggings.length == expected_size

        # Every object of the package, tagged or not: the multiset of exact
        # names (and their dates) it has here is the one of the package.
        @managed.each do |key, object_ids|
          wanted = object_ids.flat_map { |object_id| @expected.fetch(object_id, []) }.map { |tagging| [tagging.tag.name, tagging.created_at] }
          found = by_object.fetch(key, [])
          next if found.sort_by { |name, _time| name.b } == wanted.sort_by { |name, _time| name.b }

          missing = wanted.map(&:first).tally.to_a - found.map(&:first).tally.to_a
          extra = found.map(&:first).tally.to_a - wanted.map(&:first).tally.to_a
          detail = if missing.empty? && extra.empty?
                     'same names, other dates'
                   else
                     "missing #{missing.map { |name, _count| digest(name) }.join(' ')}; extra #{extra.map { |name, _count| digest(name) }.join(' ')}"
                   end
          problems << "#{key.first} ##{key.last} (#{object_ids.join(', ')}) has #{found.length} tags, the package #{wanted.length}: #{detail}"
        end

        now.tags.each do |id, name, count, *_rest|
          next unless package.key?(name)

          problems << "#{tag_label(package[name])} has counter #{count.inspect} and #{real[id]} taggings" unless count == real[id]
        end
        problems
      end

      def verify!
        now = state
        problems = differences(now) + role_differences(role_state)
        Setting.clear_cache
        @wanted_settings.each do |key, value|
          problems << "setting #{key} is #{current_setting(key).inspect}, the source has #{value.inspect}" unless current_setting(key) == value
        end
        if @setting_changes.empty? && now.setting != @before.setting
          problems << "the #{SETTING_NAME} setting changed and nothing had to change"
        end

        others = fingerprint
        (@others_before.keys | others.keys).sort.each do |table|
          was = @others_before[table]
          is = others[table]
          next if was == is

          problems << "table #{table} changed during the import (#{was ? was.first : 'absent'} rows before, #{is ? is.first : 'absent'} now)"
        end
        @writes = connection.select_rows(<<~SQL.squish).to_h { |name, *counts| [name, counts.map(&:to_i)] }
          SELECT relname, n_tup_ins, n_tup_upd, n_tup_del FROM pg_stat_xact_user_tables
          WHERE n_tup_ins + n_tup_upd + n_tup_del > 0 ORDER BY relname
        SQL
        (@writes.keys - WRITABLE).each { |table| problems << "the import wrote to #{table} (#{@writes[table].join('/')} rows inserted/updated/deleted)" }
        # PostgreSQL counts nothing when track_counts is off: then the content
        # digests above are the only evidence, and the summary says so.
        @write_statistics = (@new_tags.empty? || @writes.key?(TAGS_TABLE)) && (@new_taggings.empty? || @writes.key?(TAGGINGS_TABLE)) &&
                            (@role_changes.empty? || @writes.key?(ROLES_TABLE))
        if @write_statistics
          { TAGS_TABLE => [@new_tags.length, @counters_set, 0], TAGGINGS_TABLE => [@new_taggings.length, 0, 0],
            ROLES_TABLE => [0, @role_changes.length, 0] }.each do |table, expected|
            written = @writes.fetch(table, [0, 0, 0])
            problems << "the import wrote #{written.join('/')} rows to #{table} (inserted/updated/deleted), expected #{expected.join('/')}" unless written == expected
          end
          problems << 'the import wrote to settings and no setting had to change' if @writes.key?('settings') && @setting_changes.empty?
          problems << 'the import deleted settings' if @writes.fetch('settings', [0, 0, 0]).last.positive?
        end
        @events.tally.each { |event, count| problems << "#{count} #{event} triggered by the import" }

        if problems.empty?
          say "Verified before committing: #{@managed.length} objects have exactly the tags of the package " \
              "(#{@expected.length} tagged, #{@managed.length - @expected.length} without tags); the #{@tags.length} tags of the package are in a " \
              "catalog of #{@before.tags.length + @new_tags.length}, with their dates and real counters; #{@before.taggings.length + @new_taggings.length} " \
              "taggings; #{others.length} other tables unchanged (journals, items, wiki pages...); no job or mail."
          say(if @write_statistics
                "Rows written (inserted/updated/deleted): #{@writes.empty? ? 'none' : @writes.map { |table, counts| "#{table} #{counts.join('/')}" }.join(', ')}."
              else
                'Rows written: PostgreSQL keeps no write statistics here (track_counts is off); only the content of the tables was compared.'
              end)
        end
        problems
      end

      # After the commit or the rollback, on a new database connection: what
      # is stored is what was verified.
      def finish!
        connection.reconnect!
        Setting.clear_cache
        problems = if dry_run?
                     now = state
                     %i[tags taggings setting].filter_map { |part| "#{part} are not as before the dry run" unless now[part] == @before[part] } +
                       (role_state == @roles_before ? [] : ['roles are not as before the dry run'])
                   else
                     differences(state) + role_differences(role_state) + @wanted_settings.filter_map do |key, value|
                       "setting #{key} is #{current_setting(key).inspect}" unless current_setting(key) == value
                     end
                   end
        @events.tally.each { |event, count| problems << "#{count} #{event} triggered by the import" }
        title = dry_run? ? 'the dry run left changes behind' : 'THE IMPORT WAS COMMITTED but reading it back shows differences'
        fail_with(title, problems)

        @unchanged = @new_tags.empty? && @new_taggings.empty? && @counters_set.zero? && @setting_changes.empty? && @role_changes.empty?
        if dry_run?
          say 'Dry run: everything was rolled back.'
        elsif @unchanged
          say "Nothing to import: this instance already has the #{@tags.length} tags and #{@taggings.length} taggings of the package. Nothing was changed."
        else
          say 'Tags imported.'
        end
        visibility_notes
      end

      # Tags are only seen by roles with view_issue_tags, in projects with the
      # module; the import gives it only to roles whose source roles had it.
      def visibility_notes
        if @roles_without_destination.any?
          say "WARNING: source roles with tag permissions and no destination role (nothing given for them; map them with " \
              "roles=old:new as in the history import): #{@roles_without_destination.join(', ')}."
        end
        { 'Issue' => 'active_issue_tags', 'WikiPage' => 'active_wiki_tags' }.each do |type, key|
          tagged = @taggings.count { |tagging| @destination.fetch(tagging.object_key).first == type }
          # In a dry run the settings are rolled back: what counts is what the import leaves.
          next if tagged.zero? || RedminePluginKit.true?(@wanted_settings.fetch(key) { current_setting(key) })

          say "WARNING: #{key} is off, as in the source: the #{tagged} #{type} taggings are stored but nobody sees them until it is switched on."
        end
        issue_ids = @taggings.map { |tagging| @destination.fetch(tagging.object_key) }.select { |type, _id| type == 'Issue' }.map(&:last).uniq
        return if issue_ids.empty?

        project_ids = Issue.unscoped.where(id: issue_ids).distinct.pluck(:project_id)
        without_module = project_ids - EnabledModule.where(project_id: project_ids, name: 'issue_tracking').pluck(:project_id)
        say "WARNING: #{without_module.length} projects with tagged items do not have the issue tracking module." if without_module.any?
        role_ids = MemberRole.joins(:member).where(members: { project_id: project_ids }).distinct.pluck(:role_id)
        # In a dry run the roles are rolled back: what counts is what the import leaves.
        granted = @role_changes.select { |_role, missing, _sources| missing.include?('view_issue_tags') }.map { |role, *_rest| role.id }
        blind = Role.where(id: role_ids).reject { |role| role.permissions.include?(:view_issue_tags) || granted.include?(role.id) }
                    .map(&:name).sort
        return if blind.empty?

        say "WARNING: roles used in the projects with tags that lack the view_issue_tags permission, also after the import because " \
            "their source roles did not have it (their members see neither the tags nor the tag changes of the history): #{blind.join(', ')}."
      end

      def write_report!
        report = File.join(File.dirname(@path), "tags-import-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}.json")
        summary = {
          'mode' => dry_run? ? 'dry_run' : 'import', 'unchanged' => @unchanged,
          'package' => { 'content_sha256' => @package.manifest['content_sha256'], 'counts' => @package.content['counts'] },
          'stats' => { 'objects' => @managed.length, 'tags_created' => @new_tags.length, 'tags_already_there' => @tags.length - @new_tags.length,
                       'taggings_created' => @new_taggings.length, 'taggings_already_there' => @taggings.length - @new_taggings.length,
                       'counters_corrected' => @counters_set, 'other_tags_in_instance' => @foreign_tags,
                       'settings_changed' => @setting_changes.map { |key, old, new| { 'key' => key, 'from' => old, 'to' => new } },
                       'roles_changed' => @role_changes.map { |role, missing, sources| { 'role' => role.name, 'added' => missing, 'from' => sources } },
                       'roles_without_destination' => @roles_without_destination },
          'rows_written' => @writes, 'log' => @log
        }
        File.write(report, JSON.pretty_generate(summary) + "\n")
        puts "Report: #{report}"
      end
    end
  end
end
