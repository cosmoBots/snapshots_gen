# frozen_string_literal: true

# Writer, reader and verifier of the tags package (.cstags), version 1
# (docs/cstags-format.md). The converter writes it; the importer reads it.
# It only depends on the legacy snapshot format (canonical JSON) and rubyzip,
# so it runs under the converter's Ruby and inside the new instance.

require 'date'
require 'digest'
require 'json'
require 'set'
require 'yaml'
require 'zip'
require_relative '../../../exporter/legacy_snapshot_format'

module SnapshotsGen
  module TagsPackage
    SCHEMA = 'cosmosys-tags'
    SCHEMA_VERSION = '1'
    MANIFEST_PATH = 'manifest.json'
    FILES = {
      'tags' => 'tables/tags.jsonl',
      'taggings' => 'tables/taggings.jsonl',
      'objects' => 'tables/objects.jsonl',
      'roles' => 'tables/roles.jsonl',
      'anomalies' => 'reports/anomalies.jsonl'
    }.freeze
    # The only profile of version 1. Every field is part of the meaning of the
    # package: a reader must reject any other value.
    PROFILE = {
      'name' => 'additional-tags-4.6-postgresql-exact-v1',
      'implicit_context' => 'tags',
      'tagger_policy' => 'null-only',
      'duplicate_policy' => 'reject',
      'name_policy' => 'exact',
      'order_policy' => 'not-preserved'
    }.freeze
    ROW_KEYS = {
      'tags' => %w[created_at id name ordinal source_extra source_taggings_count updated_at],
      'taggings' => %w[context created_at id object_id ordinal source_extra tag_id taggable_id taggable_type tagger_id tagger_type],
      'objects' => %w[id source_id source_order source_type target untargeted_reason],
      'roles' => %w[builtin id name ordinal tag_permissions],
      'anomalies' => %w[code id reason severity source_ids table]
    }.freeze
    CONTENT_KEYS = %w[captured_at counts dependencies files generator importable profile source].freeze
    SOURCE_KEYS = %w[legacy_snapshot_sha256 plugins settings settings_provenance table_descriptors tables_present].freeze
    DEPENDENCY_KEYS = %w[csys_packages history_content_sha256 history_sha256].freeze
    COUNT_KEYS = %w[blocking_anomalies distinct_contexts duplicate_projection_groups information_anomalies issue_objects
                    non_null_taggers objects roles_with_tag_permissions source_roles source_taggings source_tags
                    tagged_objects unsupported_objects unused_tags warning_anomalies wiki_objects].freeze
    SOURCE_TABLES = { 'tags' => 'additional_tags', 'taggings' => 'additional_taggings' }.freeze
    # Columns of the old plugin (fork 1.0.4) that the rows carry by name.
    # Any other column goes to source_extra and blocks the import.
    KNOWN_COLUMNS = {
      'additional_tags' => %w[id name taggings_count created_at updated_at],
      'additional_taggings' => %w[id tag_id taggable_id taggable_type tagger_id tagger_type context created_at]
    }.freeze
    TAGGABLE_TYPES = %w[Issue WikiPage].freeze
    # The tag permissions of a role: the same names in the fork 1.0.4 and in
    # 4.6.0 (init.rb of both). The package carries which of them each source
    # role had, so the importer can give them to the destination roles.
    TAG_PERMISSIONS = %w[add_wiki_tags create_issue_tags edit_issue_tags view_issue_tags].freeze
    # Role.builtin in Redmine: 0 a role given to members, 1 Non member, 2 Anonymous.
    BUILTIN_ROLES = { 1 => 'non_member', 2 => 'anonymous' }.freeze
    LIST_SEPARATOR = ','
    MAX_NAME_LENGTH = 255
    BLANK = /\A[[:space:]]*\z/.freeze
    SCOPE_SEPARATOR = '::'
    GROUP_SEPARATOR = ':'

    # Effective settings of the destination plugin (additional_tags 4.6.0).
    SETTING_KEYS = %w[active_issue_tags active_wiki_tags open_issues_only show_tags_after_queries show_with_count
                      tags_color_theme tags_sidebar tags_sort_by tags_sort_order tags_suggestion_order].freeze
    CRITICAL_SETTINGS = %w[active_issue_tags active_wiki_tags].freeze
    # The values each setting may hold in 4.6.0: switches are "0" or "1".
    CHOICE_SETTINGS = {
      'tags_sidebar' => %w[none list cloud simple_cloud], 'tags_sort_by' => %w[name count],
      'tags_sort_order' => %w[asc desc], 'tags_suggestion_order' => %w[name last_created count]
    }.freeze
    SETTING_DOMAINS = SETTING_KEYS.to_h { |key| [key, CHOICE_SETTINGS.fetch(key, %w[0 1])] }.freeze
    # Datetimes as the legacy snapshot writes them: UTC with microseconds.
    TIMESTAMP = /\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})\.(\d{6})Z\z/.freeze
    SETTING_ENTRY_KEYS = %w[provenance source_key source_value value].freeze
    PROVENANCES = %w[stored default mapped destination_default unavailable].freeze
    SETTINGS_PROVENANCES = %w[stored plugin_defaults incomplete].freeze

    UNTARGETED_REASONS = %w[absorbed_into_document not_migrated project_missing wiki_missing invalid_title
                            not_in_source unsupported_type].freeze

    # Anomaly code => [severity, meaning]. The severity is fixed by the code.
    ANOMALIES = {
      'missing_table' => ['blocking', 'A tag table of the old plugin is not in the legacy snapshot'],
      'missing_column' => ['blocking', 'A column of the old plugin is missing from a tag table'],
      'unknown_column' => ['blocking', 'A tag table has columns without an approved mapping (kept in source_extra)'],
      'invalid_key' => ['blocking', 'A tag or tagging id is null or repeated'],
      'invalid_name' => ['blocking', 'Tag names the destination cannot hold exactly (null, empty, blank, edge spaces, U+0000, too long)'],
      'invalid_encoding' => ['blocking', 'Tag names that are not valid UTF-8 (kept as $base64)'],
      'duplicate_name' => ['blocking', 'Tags with exactly the same name'],
      'orphan_tag' => ['blocking', 'Taggings whose tag does not exist or is ambiguous'],
      'orphan_object' => ['blocking', 'Taggings of an issue or wiki page that does not exist or is not migrated'],
      'unsupported_type' => ['blocking', 'Taggings of an object type other than Issue and WikiPage'],
      'absorbed_issue' => ['blocking', 'Taggings of AD/RD/CD items absorbed into documents'],
      'unsupported_context' => ['blocking', 'Taggings with a context other than "tags" (the destination has no context)'],
      'non_null_tagger' => ['blocking', 'Taggings with a tagger (the destination has no tagger)'],
      'duplicate_projection' => ['blocking', 'Taggings that collapse into one in the destination (same object and name)'],
      'ambiguous_object' => ['blocking', 'Tagged objects whose destination identity is not unique'],
      'missing_settings' => ['blocking', 'Tag activation settings that cannot be determined'],
      'history_tag_change_dropped' => ['blocking', 'Tag changes in the history of items absorbed into documents or not in the source: the history cannot keep them'],
      'ambiguous_untagged_object' => ['warning', 'Untagged objects whose destination identity is not unique'],
      'invalid_setting' => ['warning', 'Tag display settings that cannot be determined (the destination default stays)'],
      'tags_not_visible' => ['warning', 'Tagged object types whose tags are switched off in the settings'],
      'unused_tag' => ['warning', 'Tags without taggings: imported, but the new plugin deletes unused tags after edits'],
      'case_variant_names' => ['warning', 'Names equal except for case: kept apart, but the new tag API matches them as one'],
      'scoped_tag_conflict' => ['warning', 'Objects with two tags of the same "group::" scope, which the new plugin rejects on edit'],
      'comma_in_name' => ['warning', 'Names with a comma: kept as one tag, but the new plugin splits them at the comma when the object is edited'],
      'unreadable_role_permissions' => ['warning', 'Roles whose permissions cannot be read: no tag permission is given for them'],
      'invalid_timestamp' => ['blocking', 'Tag or tagging dates that are not a valid timestamp (or a missing tag date, which the destination requires)'],
      'counter_mismatch' => ['information', 'Tags whose stored taggings_count differs from their real count (recomputed on import)']
    }.freeze
    SEVERITIES = %w[blocking warning information].freeze
    ANOMALY_TABLES = %w[tags taggings objects roles settings history].freeze

    MAX_ENTRY_BYTES = 1 << 30

    class Error < StandardError; end

    module_function

    # nil when a tag name can be inserted exactly, or [code, reason].
    def name_problem(name)
      return ['invalid_encoding', 'not valid UTF-8'] if name.is_a?(Hash) && name.key?('$base64')
      return ['invalid_name', 'null'] if name.nil?
      return ['invalid_name', 'not text'] unless name.is_a?(String)
      return ['invalid_encoding', 'not valid UTF-8'] unless name.dup.force_encoding(Encoding::UTF_8).valid_encoding?

      text = name.dup.force_encoding(Encoding::UTF_8)
      return ['invalid_name', 'empty'] if text.empty?
      return ['invalid_name', 'contains U+0000'] if text.include?("\u0000")
      # String#blank? of ActiveSupport: the TagList of 4.6.0 drops these
      # names, which String#strip alone would not see (U+00A0, U+3000...).
      return ['invalid_name', 'only spaces'] if text.strip.empty? || BLANK.match?(text)
      return ['invalid_name', 'leading or trailing spaces'] if text.strip != text
      return ['invalid_name', "longer than #{MAX_NAME_LENGTH} characters"] if text.length > MAX_NAME_LENGTH

      nil
    end

    # nil when value is a datetime of the format that exists in the calendar
    # (no 31 February, no hour 24), or the reason it is not.
    def timestamp_problem(value)
      match = value.is_a?(String) && TIMESTAMP.match(value)
      return 'not a UTC datetime with microseconds' unless match

      year, month, day, hour, minute, second = match.captures.first(6).map(&:to_i)
      return 'not a calendar date' unless Date.valid_date?(year, month, day)
      return 'not a time of the day' unless hour < 24 && minute < 60 && second < 60

      nil
    end

    # The Time of a valid timestamp; raises Error otherwise, never normalizes.
    def parse_time(value)
      problem = timestamp_problem(value)
      raise Error, problem if problem

      parts = TIMESTAMP.match(value).captures.map(&:to_i)
      Time.utc(*parts.first(6), parts.last)
    end

    # Exact identity of a name inside the package: the string itself, or the
    # base64 evidence of a name that is not text.
    def name_key(name)
      name.is_a?(Hash) ? ['$base64', name['$base64'].to_s] : ['text', name]
    end

    # The group a "group::value" name belongs to, as AdditionalTag#group_name
    # computes it in 4.6.0; nil for names without "::".
    def scope_group(name)
      return nil unless name.is_a?(String) && name.include?(SCOPE_SEPARATOR)

      text = name.strip
      scope = text.split(SCOPE_SEPARATOR).map(&:strip)
      labels, separator = scope.length > 1 ? [scope, SCOPE_SEPARATOR] : [text.split(GROUP_SEPARATOR).map(&:strip), GROUP_SEPARATOR]
      labels.length > 2 ? labels[0...-1].join(separator) : labels.first
    end

    def object_sort_key(row)
      rank = { 'Issue' => 0, 'WikiPage' => 1 }.fetch(row['source_type'], 2)
      [rank, rank == 2 ? row['id'].to_s.delete_prefix('unsupported:').to_i : 0,
       LegacySnapshot::Values.sort_key(row['source_id'])]
    end

    def anomaly_sort_key(row)
      [row['code'].to_s.b, row['table'].to_s.b, Array(row['source_ids']).map { |id| LegacySnapshot::Values.sort_key(id) }]
    end

    # The tag behind each tagging, by unique source id; nil when it is missing
    # or its id is repeated.
    def tags_by_id(tags)
      groups = tags.group_by { |row| row['id'] }
      groups.reject { |id, rows| id.nil? || rows.length > 1 }.transform_values(&:first)
    end

    # Groups of taggings that would be one row in the destination: same
    # object and same exact tag name (or same tag id when the tag is unknown).
    def projection_groups(tags, taggings)
      by_id = tags_by_id(tags)
      taggings.group_by do |row|
        tag = by_id[row['tag_id']]
        [row['object_id'], tag ? name_key(tag['name']) : ['tag_id', row['tag_id']]]
      end.values.select { |rows| rows.length > 1 }
    end

    # The tag permissions of a role from the YAML that Redmine stores in
    # roles.permissions (a list of symbols), or nil when it cannot be read.
    # It walks the YAML tree and never builds Ruby objects from it: only a
    # plain list of plain scalars is accepted.
    def tag_permissions(raw)
      return [] if raw.nil?
      return nil unless raw.is_a?(String) && raw.dup.force_encoding(Encoding::UTF_8).valid_encoding?

      document = Psych.parse(raw.dup.force_encoding(Encoding::UTF_8))
      # An empty value or a YAML null: a role without permissions.
      return [] if !document || (document.root.is_a?(Psych::Nodes::Scalar) && document.root.tag.nil? &&
                                 ['', '~', 'null'].include?(document.root.value))

      list = document.root
      return nil unless list.is_a?(Psych::Nodes::Sequence) && list.tag.nil?
      return nil unless list.children.all? { |node| node.is_a?(Psych::Nodes::Scalar) && node.tag.nil? }

      (list.children.map { |node| node.value.delete_prefix(':') } & TAG_PERMISSIONS).sort
    rescue Psych::Exception
      nil
    end

    def counts(rows)
      tags = rows.fetch('tags')
      taggings = rows.fetch('taggings')
      objects = rows.fetch('objects')
      roles = rows.fetch('roles')
      anomalies = rows.fetch('anomalies')
      used = taggings.map { |row| row['tag_id'] }.to_set
      severity = anomalies.group_by { |row| row['severity'] }.transform_values(&:length)
      {
        'source_tags' => tags.length,
        'source_taggings' => taggings.length,
        'objects' => objects.length,
        'issue_objects' => objects.count { |row| row['source_type'] == 'Issue' },
        'wiki_objects' => objects.count { |row| row['source_type'] == 'WikiPage' },
        'unsupported_objects' => objects.count { |row| !TAGGABLE_TYPES.include?(row['source_type']) },
        'tagged_objects' => taggings.map { |row| row['object_id'] }.uniq.length,
        'unused_tags' => tags.count { |row| !used.include?(row['id']) },
        'distinct_contexts' => taggings.map { |row| row['context'] }.uniq.length,
        'non_null_taggers' => taggings.count { |row| !row['tagger_id'].nil? || !row['tagger_type'].nil? },
        'duplicate_projection_groups' => projection_groups(tags, taggings).length,
        'source_roles' => roles.length,
        'roles_with_tag_permissions' => roles.count { |row| row['tag_permissions'].is_a?(Array) && row['tag_permissions'].any? },
        'blocking_anomalies' => severity.fetch('blocking', 0),
        'warning_anomalies' => severity.fetch('warning', 0),
        'information_anomalies' => severity.fetch('information', 0)
      }
    end

    # Writes a package. content holds captured_at, generator, source,
    # dependencies and importable; the profile, files and counts are added
    # here. Returns the manifest.
    def write(path, content:, rows:)
      raise Error, "#{path} already exists" if File.exist?(path)

      payload = {}
      files = FILES.map do |name, relative|
        list = rows.fetch(name)
        data = list.map do |row|
          raise Error, "row of #{name} does not have the keys of the format: #{row.keys.sort.inspect}" unless row.keys.sort == ROW_KEYS.fetch(name)

          LegacySnapshot::CanonicalJson.generate(row) + "\n"
        end.join.b
        payload[relative] = data
        { 'path' => relative, 'sha256' => Digest::SHA256.hexdigest(data), 'bytes' => data.bytesize, 'rows' => list.length }
      end
      content = content.merge('profile' => PROFILE, 'files' => files.sort_by { |file| file['path'] }, 'counts' => counts(rows))
      raise Error, "unexpected content keys #{content.keys.sort.inspect}" unless content.keys.sort == CONTENT_KEYS

      normalized = LegacySnapshot::CanonicalJson.normalize(content)
      manifest = {
        'schema' => SCHEMA,
        'schema_version' => SCHEMA_VERSION,
        'content_sha256' => Digest::SHA256.hexdigest(LegacySnapshot::CanonicalJson.generate(normalized)),
        'content' => normalized
      }
      Zip::OutputStream.open(path) do |zip|
        zip.put_next_entry(MANIFEST_PATH)
        zip.write(LegacySnapshot::CanonicalJson.generate(manifest))
        payload.keys.sort.each do |relative|
          zip.put_next_entry(relative)
          zip.write(payload.fetch(relative))
        end
      end
      manifest
    end

    # A verified package: manifest and rows. Raises Error when it does not
    # verify, so nothing reads a package that failed any check.
    Package = Struct.new(:manifest, :rows) do
      def content
        manifest.fetch('content')
      end

      def importable?
        content.fetch('importable') == true
      end
    end

    def read(path, history: nil, csys: nil)
      result = Verifier.new(path).verify(history: history, csys: csys)
      raise Error, "the tags package does not verify: #{result.errors.first(10).join('; ')}" unless result.ok?

      Package.new(result.manifest, result.rows)
    end

    class Verifier
      Result = Struct.new(:errors, :manifest, :rows) do
        def ok?
          errors.empty?
        end
      end

      def initialize(path)
        @path = path.to_s
      end

      # history: path of the sibling .cshistory; csys: paths of every sibling
      # .csys. When given, the package must name exactly those files.
      def verify(history: nil, csys: nil)
        @errors = []
        entries = read_zip
        return Result.new(@errors, nil, nil) if @errors.any?

        manifest = check_manifest(entries)
        return Result.new(@errors, manifest, nil) if @errors.any?

        rows = check_files(manifest.fetch('content'), entries)
        return Result.new(@errors, manifest, nil) if @errors.any?

        check_rows(rows)
        check_counts(manifest.fetch('content'), rows)
        check_source(manifest.fetch('content').fetch('source'))
        check_descriptors(manifest.fetch('content').fetch('source'), rows)
        check_profile(manifest.fetch('content'), rows) if manifest.dig('content', 'importable') == true
        check_dependencies(manifest.fetch('content').fetch('dependencies'), history, csys, rows.fetch('objects'))
        Result.new(@errors, manifest, @errors.empty? ? rows : nil)
      rescue Zip::Error, JSON::ParserError, SystemCallError, Error, KeyError, TypeError, NoMethodError, ArgumentError => error
        Result.new(@errors + ["malformed package: #{error.class}: #{error.message}"], nil, nil)
      end

      private

      def read_zip
        unless File.file?(@path)
          @errors << "#{@path} is not a file"
          return {}
        end

        entries = {}
        Zip::File.open(@path) do |archive|
          @errors << 'the archive holds data outside its listed entries (repeated names?)' unless contiguous?(archive)
          archive.each do |entry|
            name = entry.name
            next if entry.directory?

            if name.start_with?('/') || name.split('/').include?('..') || name.include?('\\')
              @errors << "unsafe entry name #{name.inspect}"
              next
            end
            @errors << "symbolic link #{name.inspect}" if entry.symlink?
            @errors << "duplicate entry #{name.inspect}" if entries.key?(name)
            @errors << "unexpected entry #{name.inspect}" unless name == MANIFEST_PATH || FILES.value?(name)
            @errors << "#{name} is larger than the limit" if entry.size > MAX_ENTRY_BYTES
            next if @errors.any?

            data = entry.get_input_stream { |input| input.read(MAX_ENTRY_BYTES + 1) }.to_s.b
            @errors << "#{name} is larger than the limit" if data.bytesize > MAX_ENTRY_BYTES
            entries[name] = data
          end
        end
        entries
      end

      # The archive must be exactly its listed entries, one after the other,
      # then the central directory: rubyzip keeps one entry per name, so a
      # repeated name, hidden data or a second record would otherwise pass.
      def contiguous?(archive)
        File.open(@path, 'rb') do |file|
          size = file.size
          tail_length = [size, 65_557].min
          file.seek(size - tail_length)
          tail = file.read(tail_length)
          index = tail.rindex("PK\x05\x06".b)
          return false unless index && tail.bytesize >= index + 22

          declared, directory_size, directory_offset, comment = tail[index + 10, 12].unpack('vVVv')
          return false unless declared == archive.size && size - tail_length + index + 22 + comment == size &&
                              directory_offset + directory_size == size - tail_length + index

          position = 0
          archive.entries.sort_by(&:local_header_offset).each do |entry|
            return false unless entry.local_header_offset == position

            file.seek(position)
            header = file.read(30).to_s
            return false unless header.bytesize == 30 && header.start_with?("PK\x03\x04".b)

            name_length, extra_length = header[26, 4].unpack('vv')
            position += 30 + name_length + extra_length + entry.compressed_size
            next unless entry.gp_flags & 8 != 0

            file.seek(position)
            position += file.read(4) == "PK\x07\x08".b ? 16 : 12
          end
          position == directory_offset
        end
      end

      def check_manifest(entries)
        raw = entries[MANIFEST_PATH]
        raise Error, 'manifest.json is missing' unless raw

        manifest = JSON.parse(raw.dup.force_encoding(Encoding::UTF_8))
        raise Error, 'manifest.json is not an object' unless manifest.is_a?(Hash)

        @errors << 'manifest.json is not canonical JSON' unless LegacySnapshot::CanonicalJson.generate(manifest).b == raw
        unless manifest.keys.sort == %w[content content_sha256 schema schema_version]
          @errors << "manifest.json has keys #{manifest.keys.sort.inspect}"
        end
        unless manifest['schema'] == SCHEMA && manifest['schema_version'] == SCHEMA_VERSION
          @errors << "unsupported schema #{manifest['schema'].inspect} #{manifest['schema_version'].inspect}"
          return manifest
        end
        content = manifest['content']
        raise Error, 'content is not an object' unless content.is_a?(Hash)

        actual = Digest::SHA256.hexdigest(LegacySnapshot::CanonicalJson.generate(content))
        @errors << 'content_sha256 does not match the manifest content' unless actual == manifest['content_sha256']
        @errors << "content has keys #{content.keys.sort.inspect}" unless content.keys.sort == CONTENT_KEYS
        @errors << 'the profile is not the profile of version 1' unless content['profile'] == PROFILE
        @errors << 'importable is not a boolean' unless [true, false].include?(content['importable'])
        manifest
      end

      def check_files(content, entries)
        files = content.fetch('files')
        paths = files.map { |file| file['path'] }
        @errors << "files lists #{paths.inspect}" unless paths.sort == FILES.values.sort && paths == paths.sort
        missing = FILES.values - entries.keys
        @errors << "missing entries #{missing.join(', ')}" if missing.any?
        return nil if @errors.any?

        rows = {}
        FILES.each do |name, relative|
          entry = files.find { |file| file['path'] == relative }
          data = entries.fetch(relative)
          @errors << "#{relative} has keys #{entry.keys.sort.inspect}" unless entry.keys.sort == %w[bytes path rows sha256]
          @errors << "#{relative} has a different SHA-256" unless Digest::SHA256.hexdigest(data) == entry['sha256']
          @errors << "#{relative} has a different size" unless data.bytesize == entry['bytes']
          @errors << "#{relative} does not end its last line" unless data.empty? || data.end_with?("\n")
          text = data.dup.force_encoding(Encoding::UTF_8)
          unless text.valid_encoding?
            @errors << "#{relative} is not UTF-8"
            next
          end
          lines = text.lines
          @errors << "#{relative} has #{lines.length} lines, expected #{entry['rows']}" unless lines.length == entry['rows']
          rows[name] = lines.each_with_index.map do |line, index|
            row = JSON.parse(line)
            location = "#{relative}:#{index + 1}"
            unless row.is_a?(Hash) && LegacySnapshot::CanonicalJson.generate(row) + "\n" == line
              @errors << "#{location} is not a canonical JSON object"
              next {}
            end
            @errors << "#{location} has keys #{row.keys.sort.inspect}" unless row.keys.sort == ROW_KEYS.fetch(name)
            row
          end
        end
        rows
      end

      def check_rows(rows)
        %w[tags taggings roles].each do |name|
          rows.fetch(name).each_with_index do |row, index|
            @errors << "#{FILES[name]}:#{index + 1} has ordinal #{row['ordinal'].inspect}" unless row['ordinal'] == index + 1
            next if name == 'roles'

            @errors << "#{FILES[name]}:#{index + 1} has a source_extra that is not an object" unless row['source_extra'].is_a?(Hash)
          end
        end
        rows.fetch('roles').each_with_index { |row, index| check_role(row, "#{FILES['roles']}:#{index + 1}") }
        objects = rows.fetch('objects')
        ids = objects.map { |row| row['id'] }
        @errors << 'objects repeat an id' unless ids.uniq.length == ids.length
        pairs = objects.map { |row| [row['source_type'], row['source_id']] }
        @errors << 'objects repeat a source type and id' unless pairs.uniq.length == pairs.length
        objects.each do |row|
          if row['id'].to_s.start_with?('unsupported:')
            @errors << "object #{row['id']} is unsupported without the reason unsupported_type" unless row['untargeted_reason'] == 'unsupported_type'
          elsif row['id'] != "#{row['source_type']}:#{row['source_id']}"
            @errors << "object #{row['id']} has an id that is not its source type and id"
          end
        end
        @errors << 'objects are out of order' unless objects == objects.sort_by { |row| TagsPackage.object_sort_key(row) }
        objects.each { |row| check_object(row) }
        known = ids.to_set
        rows.fetch('taggings').each do |row|
          @errors << "tagging ordinal #{row['ordinal']} names an unknown object" unless known.include?(row['object_id'])
        end
        anomalies = rows.fetch('anomalies')
        anomalies.each_with_index do |row, index|
          location = "#{FILES['anomalies']}:#{index + 1}"
          @errors << "#{location} has id #{row['id'].inspect}" unless row['id'] == index + 1
          @errors << "#{location} has an unknown code" unless ANOMALIES.key?(row['code'])
          @errors << "#{location} has the wrong severity" unless ANOMALIES.dig(row['code'], 0) == row['severity']
          @errors << "#{location} has an unknown table" unless ANOMALY_TABLES.include?(row['table'])
          @errors << "#{location} has source_ids that are not a list" unless row['source_ids'].is_a?(Array)
          @errors << "#{location} has no reason" unless row['reason'].is_a?(String)
        end
        sorted = anomalies.sort_by { |row| TagsPackage.anomaly_sort_key(row) }
        @errors << 'anomalies are out of order' unless anomalies.map { |row| row['id'] } == sorted.map { |row| row['id'] }
      end

      def check_role(row, location)
        @errors << "#{location} has a builtin that is not an integer" unless row['builtin'].nil? || row['builtin'].is_a?(Integer)
        permissions = row['tag_permissions']
        valid = permissions.nil? || (permissions.is_a?(Array) && permissions == permissions.uniq.sort &&
                                     permissions.all? { |permission| TAG_PERMISSIONS.include?(permission) })
        @errors << "#{location} has tag_permissions that are not a sorted list of tag permissions" unless valid
      end

      # Every object with a target is the item or wiki page of the history
      # with the same source id, and the target says what that row says: an
      # item by key, project and CSID, a page by project and exact title.
      def check_history_identities(history, manifest, objects)
        tables = %w[projects items wiki_pages].to_h do |name|
          entry = manifest.dig('content', 'tables').find { |table| table['name'] == name }
          rows = entry ? Zip::File.open(history) { |zip| zip.read(entry.fetch('path')) }.force_encoding(Encoding::UTF_8).lines.map { |line| JSON.parse(line) } : []
          [name, rows.group_by { |row| row['id'] }]
        end
        projects = tables.fetch('projects').transform_values { |rows| rows.length == 1 ? rows.first['identifier'] : nil }
        objects.each do |row|
          target = row['target']
          next unless target.is_a?(Hash)

          found = tables.fetch(row['source_type'] == 'Issue' ? 'items' : 'wiki_pages').fetch(row['source_id'], [])
          source = found.first if found.length == 1
          same = source && projects[source['project_id']] == target['project_identifier'] &&
                 (row['source_type'] == 'Issue' ? source['key'] == target['item_key'] && source['csid'] == target['csid'] : source['title'] == target['title'])
          @errors << "object #{row['id']} does not match the history (#{row['source_type'] == 'Issue' ? 'item' : 'wiki page'} with the same source id)" unless same
        end
      end

      def check_object(row)
        target = row['target']
        reason = row['untargeted_reason']
        @errors << "object #{row['id']} has a source_order" unless row['source_order'].nil?
        if target.nil?
          @errors << "object #{row['id']} has no target and no reason" unless UNTARGETED_REASONS.include?(reason)
          return
        end
        @errors << "object #{row['id']} has a target and a reason" unless reason.nil?
        expected = row['source_type'] == 'Issue' ? %w[csid item_key project_identifier type] : %w[project_identifier title type]
        valid = target.is_a?(Hash) && target.keys.sort == expected && target['type'] == row['source_type'] &&
                TAGGABLE_TYPES.include?(row['source_type']) && target.values.all? { |value| value.is_a?(String) && !value.empty? }
        @errors << "object #{row['id']} has an invalid target" unless valid
      end

      def check_counts(content, rows)
        counts = content.fetch('counts')
        expected = TagsPackage.counts(rows)
        @errors << "counts has keys #{counts.keys.sort.inspect}" unless counts.keys.sort == COUNT_KEYS
        expected.each do |key, value|
          @errors << "counts #{key} is #{counts[key].inspect}, the rows give #{value}" unless counts[key] == value
        end
        blocking = expected.fetch('blocking_anomalies')
        @errors << 'importable does not match the blocking anomalies' unless content['importable'] == blocking.zero?
      end

      def check_source(source)
        @errors << "source has keys #{source.keys.sort.inspect}" unless source.keys.sort == SOURCE_KEYS
        present = source['tables_present']
        @errors << 'tables_present is not a map of both tables' unless present.is_a?(Hash) && present.keys.sort == SOURCE_TABLES.values.sort
        settings = source['settings']
        unless settings.is_a?(Hash) && settings.keys.sort == SETTING_KEYS
          @errors << 'settings does not hold exactly the destination settings'
          return
        end
        settings.each do |key, entry|
          valid = entry.is_a?(Hash) && entry.keys.sort == SETTING_ENTRY_KEYS && PROVENANCES.include?(entry['provenance']) &&
                  (entry['value'].nil? || entry['value'].is_a?(String)) && (entry['value'].nil? == (entry['provenance'] == 'unavailable'))
          @errors << "setting #{key} is malformed" unless valid
          next if !valid || entry['value'].nil? || SETTING_DOMAINS.fetch(key).include?(entry['value'])

          @errors << "setting #{key} has a value outside its domain"
        end
        @errors << 'settings_provenance is unknown' unless SETTINGS_PROVENANCES.include?(source['settings_provenance'])
      end

      # The descriptors are the evidence of the source tables: one per present
      # table, with as many rows as the package carries, and columns that
      # differ from the known ones only with their missing_column or
      # unknown_column anomaly.
      def check_descriptors(source, rows)
        present = source['tables_present']
        descriptors = source['table_descriptors']
        return unless present.is_a?(Hash) && descriptors.is_a?(Array)

        names = descriptors.map { |entry| entry.is_a?(Hash) ? entry['name'] : nil }
        unless names == present.select { |_name, ok| ok == true }.keys.sort
          @errors << 'table_descriptors does not describe exactly the present tables'
          return
        end
        codes = rows.fetch('anomalies').map { |row| row['code'] }
        SOURCE_TABLES.each do |file, table|
          entry = descriptors.find { |descriptor| descriptor['name'] == table }
          unless entry
            @errors << "#{FILES[file]} has rows of the absent table #{table}" if rows.fetch(file).any?
            next
          end
          @errors << "#{table} declares #{entry['rows'].inspect} rows; the package has #{rows.fetch(file).length}" unless entry['rows'] == rows.fetch(file).length
          columns = Array(entry['columns']).map { |column| column.is_a?(Hash) ? column['name'] : nil }
          known = KNOWN_COLUMNS.fetch(table)
          missing = known - columns
          extra = columns - known
          if (missing.any? && !codes.include?('missing_column')) || (extra.any? && !codes.include?('unknown_column'))
            @errors << "#{table} has columns #{columns.inspect} without the anomaly that says so"
          end
        end
      end

      # An importable package must satisfy the strict profile row by row; this
      # recomputes it instead of trusting the anomalies.
      def check_profile(content, rows)
        problems = []
        source = content.fetch('source')
        problems << 'a tag table is missing' unless source.fetch('tables_present').values.all?(true)
        CRITICAL_SETTINGS.each do |key|
          problems << "setting #{key} is not 0 or 1" unless %w[0 1].include?(source.dig('settings', key, 'value'))
        end
        tags = rows.fetch('tags')
        taggings = rows.fetch('taggings')
        objects = rows.fetch('objects').to_h { |row| [row['id'], row] }
        ids = tags.map { |row| row['id'] }
        problems << 'tag ids are null or repeated' if ids.include?(nil) || ids.uniq.length != ids.length
        tagging_ids = taggings.map { |row| row['id'] }
        problems << 'tagging ids are null or repeated' if tagging_ids.include?(nil) || tagging_ids.uniq.length != tagging_ids.length
        problems << 'a tag name is not exact' if tags.any? { |row| TagsPackage.name_problem(row['name']) }
        names = tags.map { |row| TagsPackage.name_key(row['name']) }
        problems << 'two tags share a name' unless names.uniq.length == names.length
        problems << 'a row has source_extra' if (tags + taggings).any? { |row| !row['source_extra'].empty? }
        problems << 'a tag has no creation or update time' if tags.any? { |row| row['created_at'].nil? || row['updated_at'].nil? }
        if tags.any? { |row| [row['created_at'], row['updated_at']].compact.any? { |value| TagsPackage.timestamp_problem(value) } }
          problems << 'a tag has a date that is not a valid timestamp'
        end
        if taggings.any? { |row| !row['created_at'].nil? && TagsPackage.timestamp_problem(row['created_at']) }
          problems << 'a tagging has a date that is not a valid timestamp'
        end
        by_id = TagsPackage.tags_by_id(tags)
        taggings.each do |row|
          object = objects[row['object_id']]
          problems << 'a tagging has no tag' unless by_id.key?(row['tag_id'])
          problems << 'a tagging has another context' unless row['context'] == PROFILE['implicit_context']
          problems << 'a tagging has a tagger' unless row['tagger_id'].nil? && row['tagger_type'].nil?
          problems << 'a tagging has an unsupported type' unless TAGGABLE_TYPES.include?(row['taggable_type'])
          problems << 'a tagging has no destination object' unless object && object['target'] && object['source_type'] == row['taggable_type'] &&
                                                                  object['source_id'] == row['taggable_id']
        end
        problems << 'two taggings collapse into one' if TagsPackage.projection_groups(tags, taggings).any?
        targets = objects.values.select { |row| row['target'] }.group_by do |row|
          target = row['target']
          [target['type'], target['project_identifier'], (target['csid'] || target['title']).downcase]
        end
        tagged = taggings.map { |row| row['object_id'] }.to_set
        if targets.values.any? { |group| group.length > 1 && group.any? { |row| tagged.include?(row['id']) } }
          problems << 'two tagged objects share a destination identity'
        end
        problems.uniq.each { |problem| @errors << "importable package breaks the strict profile: #{problem}" }
      end

      def check_dependencies(dependencies, history, csys, objects)
        @errors << "dependencies has keys #{dependencies.keys.sort.inspect}" unless dependencies.keys.sort == DEPENDENCY_KEYS
        if history
          result = LegacySnapshot::Verifier.new(history).verify
          if !result.ok?
            @errors << 'the history package does not verify'
          elsif result.manifest['content_sha256'] != dependencies['history_content_sha256'] ||
                Digest::SHA256.file(history).hexdigest != dependencies['history_sha256']
            @errors << 'the history package is not the one this tags package was converted with'
          else
            check_history_identities(history, result.manifest, objects)
          end
        end
        return unless csys

        expected = dependencies.fetch('csys_packages').map { |entry| entry['sha256'] }.sort
        actual = csys.map { |path| Digest::SHA256.file(path).hexdigest }.sort
        @errors << 'the .csys packages are not the ones this tags package was converted with' unless expected == actual
      end
    end
  end
end
