# frozen_string_literal: true

require 'digest'
require 'set'
require 'yaml'
require_relative '../tags_package'

module SnapshotsGen
  module Converter
    # Builds the tags package (.cstags) of a conversion: every row of the old
    # tag tables, every issue and wiki page with its destination identity, and
    # every finding of the strict profile. It decides nothing: a case the
    # destination cannot hold exactly is an anomaly, and any blocking anomaly
    # makes the package not importable.
    class TagsBuilder
      SETTING_NAME = 'plugin_additional_tags'
      # Defaults of the old plugin (fork 1.0.4, config/settings.yml), the
      # values Redmine uses when the setting was never saved.
      LEGACY_DEFAULTS = {
        'active_issue_tags' => 0, 'active_wiki_tags' => 0, 'open_issues_only' => 0, 'show_with_count' => 0,
        'tags_sidebar' => 'none', 'tags_sort_by' => 'name', 'tags_sort_order' => 'asc', 'tags_suggestion_order' => 'name',
        'use_colors' => 1
      }.freeze
      BOOLEAN_SETTINGS = %w[active_issue_tags active_wiki_tags open_issues_only show_with_count].freeze
      CHOICE_SETTINGS = {
        'tags_sidebar' => %w[none list cloud simple_cloud], 'tags_sort_by' => %w[name count],
        'tags_sort_order' => %w[asc desc], 'tags_suggestion_order' => %w[name last_created count]
      }.freeze
      # Destination key => old key whose value it takes, translated.
      MAPPED_SETTINGS = { 'tags_color_theme' => 'use_colors' }.freeze
      # Destination keys without an old equivalent: the destination default.
      DESTINATION_DEFAULTS = { 'show_tags_after_queries' => '0' }.freeze
      HASH_TAG = %r{\A---[ \t]*!ruby/hash(?:-with-ivars)?:ActiveSupport::HashWithIndifferentAccess[ \t]*\r?\n}.freeze

      attr_reader :rows, :content

      # csys: [{ 'path', 'root_identifier', 'content_sha256' }] of every
      # sibling .csys; history_path: the sibling .cshistory, already written.
      def initialize(plan, history_path:, csys:)
        @plan = plan
        @source = plan.source
        @history_path = history_path
        @csys = csys
        @anomalies = []
      end

      def build
        present = TagsPackage::SOURCE_TABLES.values.to_h { |name| [name, @source.table?(name)] }
        present.each do |name, ok|
          anomaly('missing_table', table_for(name), [], "the legacy snapshot has no #{name} table") unless ok
        end
        check_columns(present)
        tags = tag_rows
        objects, object_ids = object_rows
        taggings = tagging_rows(objects, object_ids)
        check_tags(tags, taggings)
        check_taggings(tags, taggings, objects)
        check_objects(objects, taggings)
        settings = resolve_settings
        check_visibility(settings, taggings)
        anomalies = @anomalies.sort_by { |row| TagsPackage.anomaly_sort_key(row) }.each_with_index.map { |row, index| row.merge('id' => index + 1) }
        @rows = { 'tags' => tags, 'taggings' => taggings, 'objects' => objects.values.sort_by { |row| TagsPackage.object_sort_key(row) },
                  'anomalies' => anomalies }
        @content = {
          'captured_at' => @source.content.fetch('captured_at'),
          'generator' => HistoryBuilder::GENERATOR,
          'source' => {
            'legacy_snapshot_sha256' => @source.manifest.fetch('content_sha256'),
            'plugins' => plugins,
            'tables_present' => present,
            'table_descriptors' => present.select { |_name, ok| ok }.keys.sort.map do |name|
              @source.table_entry(name).slice('name', 'columns', 'primary_key', 'rows')
            end,
            'settings' => settings,
            'settings_provenance' => settings_provenance(settings)
          },
          'dependencies' => dependencies,
          'importable' => anomalies.none? { |row| row['severity'] == 'blocking' }
        }
        self
      end

      def write(path)
        build unless @rows
        TagsPackage.write(path, content: @content, rows: @rows)
      end

      # Counts and anomalies by code for the conversion report: no names.
      def report!(report)
        counts = TagsPackage.counts(@rows)
        report.add('tags_information', 'package', importable: @content['importable'],
                                                  **counts.slice('source_tags', 'source_taggings', 'objects', 'tagged_objects',
                                                                 'unused_tags').transform_keys(&:to_sym))
        @rows.fetch('anomalies').group_by { |row| row['code'] }.sort.each do |code, rows|
          severity, meaning = TagsPackage::ANOMALIES.fetch(code)
          ids = rows.flat_map { |row| row['source_ids'] }.first(20)
          report.add("tags_#{severity}", code, records: rows.length, meaning: meaning, table: rows.map { |row| row['table'] }.uniq.join(','),
                                               source_ids: ids)
        end
      end

      private

      def table_for(source_table)
        TagsPackage::SOURCE_TABLES.key(source_table)
      end

      def anomaly(code, table, source_ids, reason)
        severity = TagsPackage::ANOMALIES.fetch(code).first
        @anomalies << { 'code' => code, 'severity' => severity, 'table' => table, 'source_ids' => source_ids, 'reason' => reason }
      end

      def row_id(row)
        row['id'].nil? ? "ordinal:#{row['ordinal']}" : row['id']
      end

      def check_columns(present)
        TagsPackage::KNOWN_COLUMNS.each do |name, known|
          next unless present[name]

          columns = @source.table_entry(name).fetch('columns').map { |column| column.fetch('name') }
          (known - columns).each { |column| anomaly('missing_column', table_for(name), [], "#{name} has no #{column} column") }
          extra = columns - known
          next if extra.empty?

          anomaly('unknown_column', table_for(name), [], "#{name} has #{extra.length} columns without mapping: #{extra.sort.join(', ')}")
        end
      end

      def source_rows(name)
        known = TagsPackage::KNOWN_COLUMNS.fetch(name)
        @source.raw_table(name).each_with_index.map do |row, index|
          [row.slice(*known), row.reject { |column, _value| known.include?(column) }, index + 1]
        end
      end

      def tag_rows
        source_rows('additional_tags').map do |row, extra, ordinal|
          { 'id' => row['id'], 'name' => row['name'], 'source_taggings_count' => row['taggings_count'],
            'created_at' => row['created_at'], 'updated_at' => row['updated_at'], 'ordinal' => ordinal, 'source_extra' => extra }
        end
      end

      # Every issue and wiki page of the source, tagged or not, keyed by
      # object id; and the object id of each (type, id) pair.
      def object_rows
        objects = {}
        ids = {}
        @source.raw_table('issues').each do |issue|
          id = issue['id']
          object = { 'id' => "Issue:#{id}", 'source_type' => 'Issue', 'source_id' => id, 'source_order' => nil }
          objects[object['id']] = object.merge(issue_target(id))
          ids[['Issue', id]] = object['id']
        end
        wikis = @source.raw_table('wikis').to_h { |row| [row['id'], row['project_id']] }
        @source.raw_table('wiki_pages').each do |page|
          id = page['id']
          object = { 'id' => "WikiPage:#{id}", 'source_type' => 'WikiPage', 'source_id' => id, 'source_order' => nil }
          objects[object['id']] = object.merge(wiki_target(page, wikis))
          ids[['WikiPage', id]] = object['id']
        end
        [objects, ids]
      end

      def issue_target(id)
        return untargeted('absorbed_into_document') if @plan.absorbed.key?(id)

        item = @plan.item_for_issue(id)
        return untargeted('not_migrated') unless item && item.csid

        project = @plan.project(item.project_id)
        return untargeted('project_missing') unless project && project['identifier'].is_a?(String)

        { 'target' => { 'type' => 'Issue', 'project_identifier' => project['identifier'], 'csid' => item.csid, 'item_key' => item.key },
          'untargeted_reason' => nil }
      end

      def wiki_target(page, wikis)
        project = @plan.project(wikis[page['wiki_id']])
        return untargeted(wikis.key?(page['wiki_id']) ? 'project_missing' : 'wiki_missing') unless project && project['identifier'].is_a?(String)
        return untargeted('invalid_title') unless page['title'].is_a?(String) && !page['title'].empty?

        { 'target' => { 'type' => 'WikiPage', 'project_identifier' => project['identifier'], 'title' => page['title'] },
          'untargeted_reason' => nil }
      end

      def untargeted(reason)
        { 'target' => nil, 'untargeted_reason' => reason }
      end

      def tagging_rows(objects, object_ids)
        rows = source_rows('additional_taggings')
        unsupported = rows.map { |row, _extra, _ordinal| [row['taggable_type'], row['taggable_id']] }
                          .reject { |pair| object_ids.key?(pair) || (TagsPackage::TAGGABLE_TYPES.include?(pair[0]) && pair[1].is_a?(Integer)) }
                          .uniq.sort_by { |pair| pair.map { |value| LegacySnapshot::Values.sort_key(value) } }
        unsupported.each_with_index do |(type, id), index|
          object = { 'id' => "unsupported:#{index + 1}", 'source_type' => type, 'source_id' => id, 'source_order' => nil,
                     'target' => nil, 'untargeted_reason' => 'unsupported_type' }
          objects[object['id']] = object
          object_ids[[type, id]] = object['id']
        end
        rows.map do |row, extra, ordinal|
          pair = [row['taggable_type'], row['taggable_id']]
          unless object_ids.key?(pair)
            # An Issue or WikiPage id that is not in the source.
            object = { 'id' => "#{pair[0]}:#{pair[1]}", 'source_type' => pair[0], 'source_id' => pair[1], 'source_order' => nil,
                       'target' => nil, 'untargeted_reason' => 'not_in_source' }
            objects[object['id']] = object
            object_ids[pair] = object['id']
          end
          { 'id' => row['id'], 'tag_id' => row['tag_id'], 'taggable_type' => row['taggable_type'], 'taggable_id' => row['taggable_id'],
            'tagger_id' => row['tagger_id'], 'tagger_type' => row['tagger_type'], 'context' => row['context'],
            'created_at' => row['created_at'], 'object_id' => object_ids.fetch(pair), 'ordinal' => ordinal, 'source_extra' => extra }
        end
      end

      def check_keys(table, rows)
        rows.group_by { |row| row['id'] }.each do |id, group|
          if id.nil?
            group.each { |row| anomaly('invalid_key', table, [row_id(row)], 'null id') }
          elsif group.length > 1
            anomaly('invalid_key', table, group.map { |row| row_id(row) }, "id repeated #{group.length} times")
          end
        end
      end

      def check_tags(tags, taggings)
        check_keys('tags', tags)
        tags.each do |row|
          problem = TagsPackage.name_problem(row['name'])
          anomaly(problem[0], 'tags', [row_id(row)], "name: #{problem[1]}") if problem
        end
        tags.group_by { |row| TagsPackage.name_key(row['name']) }.each_value do |group|
          next if group.length < 2

          anomaly('duplicate_name', 'tags', group.map { |row| row_id(row) }, "#{group.length} tags with the same name")
        end
        valid = tags.select { |row| row['name'].is_a?(String) && TagsPackage.name_problem(row['name']).nil? }
        valid.group_by { |row| row['name'].downcase }.each_value do |group|
          next if group.map { |row| row['name'] }.uniq.length < 2

          anomaly('case_variant_names', 'tags', group.map { |row| row_id(row) }, "#{group.length} names equal except for case")
        end
        counts = taggings.group_by { |row| row['tag_id'] }.transform_values(&:length)
        TagsPackage.tags_by_id(tags).each do |id, row|
          real = counts.fetch(id, 0)
          anomaly('unused_tag', 'tags', [id], 'no taggings') if real.zero?
          next if row['source_taggings_count'] == real

          anomaly('counter_mismatch', 'tags', [id], "stored taggings_count #{row['source_taggings_count'].inspect}, real #{real}")
        end
      end

      def check_taggings(tags, taggings, objects)
        check_keys('taggings', taggings)
        by_id = TagsPackage.tags_by_id(tags)
        taggings.each do |row|
          id = [row_id(row)]
          anomaly('orphan_tag', 'taggings', id, row['tag_id'].nil? ? 'null tag_id' : 'tag_id names no unique tag') unless by_id.key?(row['tag_id'])
          unless row['context'] == TagsPackage::PROFILE['implicit_context']
            anomaly('unsupported_context', 'taggings', id, row['context'].nil? ? 'null context' : 'context other than "tags"')
          end
          anomaly('non_null_tagger', 'taggings', id, 'tagger_id or tagger_type is set') unless row['tagger_id'].nil? && row['tagger_type'].nil?
          object = objects.fetch(row['object_id'])
          case object['untargeted_reason']
          when nil then next
          when 'unsupported_type'
            anomaly('unsupported_type', 'taggings', id, 'taggable type and id are not an Issue or WikiPage id')
          when 'absorbed_into_document'
            anomaly('absorbed_issue', 'taggings', id, "#{row['object_id']} became a document")
          else
            anomaly('orphan_object', 'taggings', id, "#{row['object_id']}: #{object['untargeted_reason'].tr('_', ' ')}")
          end
        end
        TagsPackage.projection_groups(tags, taggings).each do |group|
          anomaly('duplicate_projection', 'taggings', group.map { |row| row_id(row) }, "#{group.length} taggings of #{group.first['object_id']} with the same name")
        end
        scoped = Hash.new { |hash, key| hash[key] = [] }
        taggings.each do |row|
          group = (tag = by_id[row['tag_id']]) && TagsPackage.scope_group(tag['name'])
          scoped[[row['object_id'], group]] << row if group
        end
        scoped.each_value do |group|
          names = group.map { |row| by_id[row['tag_id']]['name'] }.uniq
          next if names.length < 2

          anomaly('scoped_tag_conflict', 'taggings', group.map { |row| row_id(row) }, "#{names.length} tags of one scope on #{group.first['object_id']}")
        end
      end

      # Destination identities must be unique: the importer finds an item by
      # project and CSID and a wiki page by project and title, both ignoring case.
      def check_objects(objects, taggings)
        tagged = taggings.map { |row| row['object_id'] }.to_set
        objects.values.select { |row| row['target'] }.group_by do |row|
          target = row['target']
          [target['type'], target['project_identifier'], (target['csid'] || target['title']).downcase]
        end.each_value do |group|
          next if group.length < 2

          code = group.any? { |row| tagged.include?(row['id']) } ? 'ambiguous_object' : 'ambiguous_untagged_object'
          anomaly(code, 'objects', group.map { |row| row['id'] }, "#{group.length} objects with one destination identity")
        end
      end

      def plugins
        Array(@source.inventory['plugins']).select { |plugin| %w[additional_tags additionals].include?(plugin['id']) }
                                           .map { |plugin| plugin.slice('id', 'version') }.sort_by { |plugin| plugin['id'] }
      end

      def dependencies
        history = LegacySnapshot::Verifier.new(@history_path).verify
        raise Error, 'the history package does not verify' unless history.ok?

        {
          'history_content_sha256' => history.manifest.fetch('content_sha256'),
          'history_sha256' => Digest::SHA256.file(@history_path).hexdigest,
          'csys_packages' => @csys.map do |entry|
            { 'root_identifier' => entry.fetch('root_identifier'), 'content_sha256' => entry.fetch('content_sha256'),
              'sha256' => Digest::SHA256.file(entry.fetch('path')).hexdigest }
          end.sort_by { |entry| entry['root_identifier'] }
        }
      end

      # --- settings ------------------------------------------------------------

      def resolve_settings
        stored, unavailable = stored_settings
        settings = {}
        (TagsPackage::SETTING_KEYS - MAPPED_SETTINGS.keys - DESTINATION_DEFAULTS.keys).each do |key|
          settings[key] = setting(key, key, stored, unavailable)
        end
        MAPPED_SETTINGS.each do |key, old_key|
          entry = setting(key, old_key, stored, unavailable)
          entry['provenance'] = 'mapped' if entry['value']
          settings[key] = entry
        end
        DESTINATION_DEFAULTS.each do |key, value|
          settings[key] = { 'value' => value, 'provenance' => 'destination_default', 'source_key' => nil, 'source_value' => nil }
        end
        settings.sort.to_h
      end

      # [stored hash or nil when the setting was never saved, reason it is unavailable]
      def stored_settings
        unless @source.table?('settings')
          anomaly('missing_settings', 'settings', [], 'the legacy snapshot has no settings table')
          return [nil, 'no settings table']
        end
        rows = @source.raw_table('settings').select { |row| row['name'] == SETTING_NAME }
        return [nil, nil] if rows.empty?

        ids = rows.map { |row| row['id'] }
        if rows.length > 1
          anomaly('missing_settings', 'settings', ids, "#{rows.length} rows of #{SETTING_NAME}")
          return [nil, 'repeated']
        end
        row = rows.first
        redacted = @source.report_rows('redactions').any? { |entry| entry['table'] == 'settings' && entry['id'] == row['id'] }
        reason = if redacted then 'redacted by the exporter'
                 elsif !row['value'].is_a?(String) then 'no readable value'
                 end
        if reason
          anomaly('missing_settings', 'settings', ids, "#{SETTING_NAME}: #{reason}")
          return [nil, reason]
        end
        value = YAML.safe_load(row['value'].sub(HASH_TAG, "---\n"), permitted_classes: [Symbol], aliases: false)
        unless value.is_a?(Hash)
          anomaly('missing_settings', 'settings', ids, "#{SETTING_NAME} is not a map")
          return [nil, 'not a map']
        end
        [value.to_h { |key, entry| [key.to_s, entry] }, nil]
      rescue Psych::Exception => error
        anomaly('missing_settings', 'settings', ids, "#{SETTING_NAME} is not safe YAML (#{error.class.name.split('::').last})")
        [nil, 'unreadable']
      end

      def setting(key, old_key, stored, unavailable)
        entry = { 'value' => nil, 'provenance' => 'unavailable', 'source_key' => old_key, 'source_value' => nil }
        return entry if unavailable

        if stored.nil?
          raw = LEGACY_DEFAULTS.fetch(old_key)
          provenance = 'default'
        elsif stored.key?(old_key)
          raw = stored[old_key]
          provenance = 'stored'
        else
          return unresolved(key, entry, "#{old_key} is not in the stored setting")
        end
        entry['source_value'] = raw.is_a?(Symbol) ? raw.to_s : raw
        entry['source_value'] = nil unless [String, Integer, TrueClass, FalseClass, NilClass].any? { |type| entry['source_value'].is_a?(type) }
        value = normalize_setting(old_key, raw)
        return unresolved(key, entry, "#{old_key} has a value outside its choices") unless value

        entry.merge('value' => value, 'provenance' => provenance)
      end

      def unresolved(key, entry, reason)
        code = TagsPackage::CRITICAL_SETTINGS.include?(key) ? 'missing_settings' : 'invalid_setting'
        anomaly(code, 'settings', [key], reason)
        entry
      end

      def normalize_setting(key, raw)
        if CHOICE_SETTINGS.key?(key)
          text = raw.is_a?(Symbol) ? raw.to_s : raw
          CHOICE_SETTINGS.fetch(key).include?(text) ? text : nil
        else
          case raw
          when 1, '1', true then '1'
          when 0, '0', false then '0'
          end
        end
      end

      def settings_provenance(settings)
        provenances = settings.values.map { |entry| entry['provenance'] }
        return 'incomplete' if provenances.include?('unavailable')
        return 'plugin_defaults' if provenances.include?('default')

        'stored'
      end

      def check_visibility(settings, taggings)
        { 'Issue' => 'active_issue_tags', 'WikiPage' => 'active_wiki_tags' }.each do |type, key|
          next unless settings.dig(key, 'value') == '0'

          count = taggings.count { |row| row['taggable_type'] == type }
          anomaly('tags_not_visible', 'settings', [key], "#{count} #{type} taggings, #{key} is off") if count.positive?
        end
      end
    end
  end
end
