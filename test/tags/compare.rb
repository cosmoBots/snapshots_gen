# frozen_string_literal: true

require 'json'
require 'digest'
require 'base64'
require 'time'
require 'optparse'
require_relative 'extract'

module TagsEvidence
  class InvalidEvidence < StandardError; end

  # The footer detects truncated extracts, including an otherwise valid prefix.
  class Document
    attr_reader :meta, :objects, :tags, :assignments

    def initialize(path)
      @objects, @tags, @assignments = [], [], []
      counts = Hash.new(0)
      digest = Digest::SHA256.new
      ended = false
      File.foreach(path).with_index(1) do |line, number|
        raise InvalidEvidence, "rows after end at line #{number}" if ended
        raise InvalidEvidence, "missing LF at line #{number}" unless line.end_with?("\n")

        begin
          row = JSON.parse(line)
        rescue JSON::ParserError, EncodingError
          raise InvalidEvidence, "invalid JSON at line #{number}"
        end
        raise InvalidEvidence, "invalid row at line #{number}" unless row.is_a?(Hash)
        raise InvalidEvidence, "noncanonical row at line #{number}" unless TagsEvidence.json(row) + "\n" == line
        kind = row['kind']
        if kind == 'end'
          raise InvalidEvidence, 'footer count or checksum mismatch' unless row['counts'] == counts && row['sha256'] == digest.hexdigest
          ended = true
          next
        end
        digest.update(line)
        counts[kind] += 1
        case kind
        when 'meta'
          raise InvalidEvidence, 'metadata must be first and unique' unless number == 1 && @meta.nil?
          @meta = row
        when 'object' then @objects << row
        when 'tag' then @tags << row
        when 'assignment' then @assignments << row
        else raise InvalidEvidence, "unknown row kind at line #{number}"
        end
      end
      raise InvalidEvidence, 'missing metadata or footer' unless @meta && ended
      raise InvalidEvidence, 'unsupported evidence schema' unless @meta['schema'] == SCHEMA
    end
  end

  class Comparison
    attr_reader :failures, :information

    def initialize(source, target, report, show_names: false)
      @source, @target, @report, @show_names = source, target, report, show_names
      @failures, @information = [], []
      @remap, @absorbed, @generated, @chapters = {}, {}, {}, []
      @expected_generated = []
      @tag_refs = { 'source' => Hash.new { |hash, key| hash[key] = [] }, 'target' => Hash.new { |hash, key| hash[key] = [] } }
      @object_refs = { 'source' => Hash.new { |hash, key| hash[key] = [] }, 'target' => Hash.new { |hash, key| hash[key] = [] } }
    end

    def fail_at(code, side, row = nil, value = nil)
      reference = if row && row['id'].is_a?(Integer)
                    " id=#{row['id']}"
                  else
                    ''
                  end
      suffix = value.nil? ? '' : " fingerprint=#{Digest::SHA256.hexdigest(TagsEvidence.json(value))[0, 16]}"
      suffix += " value=#{TagsEvidence.json(value)}" if @show_names && !value.nil?
      @failures << "#{code} side=#{side}#{reference}#{suffix}"
    end

    def byte_key(value)
      if value.is_a?(String)
        value.b
      elsif value.is_a?(Hash) && value.keys == ['$base64'] && value['$base64'].is_a?(String)
        Base64.strict_decode64(value['$base64'])
      else
        raise InvalidEvidence, 'invalid encoded string'
      end
    rescue ArgumentError
      raise InvalidEvidence, 'invalid base64 string'
    end

    def text?(value)
      value.is_a?(String) && !value.empty? && value.encoding != Encoding::BINARY && value.valid_encoding?
    end

    def timestamp(value, side, row)
      return nil if value.nil?
      unless value.is_a?(String) && value.match?(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?Z\z/)
        fail_at('invalid_timestamp', side, row)
        return value
      end
      Time.iso8601(value).utc.iso8601(6)
    rescue ArgumentError
      fail_at('invalid_timestamp', side, row)
      value
    end

    def report_map
      unless @report.is_a?(Hash) && @report['format'] == 'snapshots_gen-conversion-report-v1' && @report['entries'].is_a?(Array)
        raise InvalidEvidence, 'unsupported conversion report'
      end
      @report['entries'].each do |entry|
        raise InvalidEvidence, 'invalid conversion report entry' unless entry.is_a?(Hash)
        case entry['code']
        when 'identity_renumbered', 'identity_prefix_normalized'
          match = /\Aitem:(group-)?(\d+)\z/.match(entry['subject'].to_s)
          detail = entry['detail']
          unless match && detail.is_a?(Hash) && detail.key?('from') && text?(detail['to'])
            raise InvalidEvidence, 'unusable identity mapping in report'
          end
          id = match[2].to_i
          mapping = match[1] ? @generated : @remap
          raise InvalidEvidence, 'duplicate identity mapping in report' if mapping.key?(id)
          raise InvalidEvidence, 'generated identity has a source CSID' if match[1] && !detail['from'].nil?
          mapping[id] = detail
        when 'document_item_absorbed'
          match = /\A#(\d+)\s/.match(entry['subject'].to_s)
          raise InvalidEvidence, 'unusable absorbed identity in report' unless match
          raise InvalidEvidence, 'duplicate absorbed identity in report' if @absorbed.key?(match[1].to_i)
          raise InvalidEvidence, 'missing absorbed project in report' unless entry['detail'].is_a?(Hash) && text?(entry['detail']['project'])
          @absorbed[match[1].to_i] = entry['detail']['project']
        when 'synthetic_chapter'
          match = /\Aitem:(\d+)\z/.match(entry.dig('detail', 'around').to_s)
          raise InvalidEvidence, 'unusable generated chapter in report' unless match
          raise InvalidEvidence, 'duplicate generated chapter in report' if @chapters.include?(match[1].to_i)
          @chapters << match[1].to_i
        end
      end
      source_ids = @source.objects.select { |row| row['type'] == 'Issue' }.map { |row| row['id'] }
      (@remap.keys + @absorbed.keys + @generated.keys + @chapters).uniq.each do |id|
        fail_at('report_unknown_issue', 'report', { 'id' => id }) unless source_ids.include?(id)
      end
      raise InvalidEvidence, 'generated chapter lacks its final identity in report' unless @generated.keys.sort == @chapters.sort
      @generated.each do |id, mapping|
        objects = @source.objects.select { |row| row['type'] == 'Issue' && row['id'] == id }
        raise InvalidEvidence, 'ambiguous generated chapter origin' unless objects.length == 1
        @expected_generated << ['Issue', objects.first['project'], mapping['to']]
        @information << "generated_unlabelled_chapter around_id=#{id} (report)"
      end
    end

    def required(row, keys, side)
      keys.each { |key| fail_at("missing_field_#{key}", side, row) unless row.key?(key) }
    end

    def index(rows, side, kind)
      rows.each_with_object({}) do |row, result|
        id = row['id']
        unless id.is_a?(Integer) && id.positive?
          fail_at("invalid_#{kind}_id", side)
          next
        end
        fail_at("duplicate_#{kind}_id", side, row) if result.key?(id)
        result[id] = row
      end
    end

    def validate_schema(document, side)
      expected = {
        'additional_tags' => %w[id name taggings_count created_at updated_at],
        'additional_taggings' => %w[id tag_id taggable_id taggable_type created_at]
      }
      expected['additional_taggings'] += %w[context tagger_id tagger_type] if side == 'source'
      descriptors = document.meta['tables']
      raise InvalidEvidence, 'missing table descriptors' unless descriptors.is_a?(Hash)
      expected.each do |table, columns|
        actual = descriptors[table]
        raise InvalidEvidence, 'missing table descriptor' unless actual.is_a?(Array) && actual.all? { |column| column.is_a?(Hash) }
        names = actual.map { |column| column['name'] }
        fail_at('schema_columns_differ', side, nil, table) unless names.sort == columns.sort
      end
      document.tags.each do |row|
        fail_at('unexpected_tag_field', side, row) unless (row.keys - %w[kind actual_taggings_count]).sort == expected['additional_tags'].sort
      end
      document.assignments.each do |row|
        fail_at('unexpected_assignment_field', side, row) unless (row.keys - ['kind']).sort == expected['additional_taggings'].sort
      end
      plugins = document.meta['plugins']
      unless plugins.is_a?(Array) && %w[additional_tags additionals].all? { |id| plugins.any? { |plugin| plugin['id'] == id } }
        fail_at('missing_plugin_evidence', side)
      end
      if plugins.is_a?(Array)
        version = side == 'source' ? '1.0.4' : '4.6.0'
        fail_at('unexpected_plugin_version', side) unless plugins.any? { |plugin| plugin['id'] == 'additional_tags' && plugin['version'] == version }
      end
    end

    def normalized_settings(document, side)
      settings = document.meta.dig('settings', 'effective')
      raise InvalidEvidence, 'missing effective plugin settings' unless settings.is_a?(Hash)
      result = {}
      %w[active_issue_tags active_wiki_tags open_issues_only show_with_count].each do |key|
        value = settings[key]
        if [0, 1, '0', '1', true, false].include?(value)
          result[key] = [1, '1', true].include?(value) ? '1' : '0'
        else
          fail_at('invalid_boolean_setting', side, nil, key)
        end
      end
      { 'tags_sidebar' => %w[none list cloud simple_cloud], 'tags_sort_by' => %w[name count],
        'tags_sort_order' => %w[asc desc], 'tags_suggestion_order' => %w[name last_created count] }.each do |key, allowed|
        fail_at('invalid_setting', side, nil, key) unless allowed.include?(settings[key])
        result[key] = settings[key]
      end
      color = settings[side == 'source' ? 'use_colors' : 'tags_color_theme']
      fail_at('invalid_color_setting', side) unless [0, 1, '0', '1', true, false].include?(color)
      result['tags_color_theme'] = [1, '1', true].include?(color) ? '1' : '0'
      if side == 'target' && ![0, '0', false].include?(settings['show_tags_after_queries'])
        fail_at('unexpected_show_tags_after_queries', side)
      end
      result
    end

    def bag(values)
      values.each_with_object(Hash.new(0)) { |value, counts| counts[value] += 1 }
    end

    def difference(code, before, after)
      old, new = bag(before), bag(after)
      (old.keys | new.keys).each do |key|
        next if old[key] == new[key]
        detail = "#{code} expected=#{old[key]} actual=#{new[key]}"
        if %w[tag_catalog_or_dates assignment assignment_timestamp].include?(code)
          name = key[code == 'tag_catalog_or_dates' ? 0 : 3]
          detail += " tag_sha256=#{Digest::SHA256.hexdigest(name)[0, 16]}"
          detail += " source_tag_ids=#{@tag_refs['source'][name].inspect} target_tag_ids=#{@tag_refs['target'][name].inspect}"
        elsif code == 'object_coverage'
          detail += " source_object_ids=#{@object_refs['source'][key].inspect} target_object_ids=#{@object_refs['target'][key].inspect}"
        end
        fail_at(detail, 'both', nil, key)
      end
    end

    def inventory(document, side)
      settings = normalized_settings(document, side)
      tags = index(document.tags, side, 'tag')
      index(document.assignments, side, 'assignment')
      objects = {}
      logical_objects, catalog, assignments, dates, foreign_objects = [], [], [], [], []
      physical_counts = Hash.new(0)
      logical_assignment_counts = Hash.new(0)
      document.objects.each do |row|
        required(row, %w[id type project source_order], side)
        type, id = row.values_at('type', 'id')
        fail_at('invalid_object_id', side) unless id.is_a?(Integer) && id.positive?
        fail_at('unsupported_object_type', side, row) unless %w[Issue WikiPage].include?(type)
        physical_key = [type, id]
        fail_at('duplicate_object_id', side, row) if objects.key?(physical_key)
        identifier = row[type == 'Issue' ? 'csid' : 'title']
        if side == 'source' && type == 'Issue' && @remap.key?(id)
          mapping = @remap.fetch(id)
          fail_at('report_from_mismatch', side, row) unless mapping['from'] == identifier
          identifier = mapping['to']
        end
        logical_key = [type, row['project'], identifier]
        @object_refs[side][logical_key] << id if id.is_a?(Integer)
        absorbed = side == 'source' && type == 'Issue' && @absorbed.key?(id)
        fail_at('report_absorbed_project_mismatch', side, row) if absorbed && @absorbed[id] != row['project']
        fail_at('invalid_object_identity', side, row) unless absorbed || (text?(row['project']) && text?(identifier))
        # A new instance brings projects of its own (help wikis) that are
        # not part of the migration: outside the coverage, but never tagged.
        foreign = side == 'target' && !@source_projects.include?(row['project'])
        objects[physical_key] = { key: logical_key, row: row, absorbed: absorbed, foreign: foreign }
        if absorbed
          @information << "absorbed_unlabelled_issue id=#{id} (report)"
        elsif foreign
          foreign_objects << row
        else
          logical_objects << logical_key
        end
      end
      logical_objects.concat(@expected_generated) if side == 'source'
      bag(logical_objects).each do |key, count|
        fail_at('ambiguous_logical_object', side, nil, key) if count > 1
      end
      document.tags.each do |row|
        required(row, %w[id name taggings_count actual_taggings_count created_at updated_at], side)
        name = row['name']
        valid = name.is_a?(String) && !name.empty? && name.valid_encoding? && !name.include?("\u0000") && name.strip == name && !name.strip.empty?
        fail_at('invalid_tag_name', side, row, name) unless valid
        if name.is_a?(String) || name.is_a?(Hash)
          bytes = byte_key(name)
          @tag_refs[side][bytes] << row['id'] if row['id'].is_a?(Integer)
          catalog << [bytes, timestamp(row['created_at'], side, row), timestamp(row['updated_at'], side, row)]
          limit = @target.meta.fetch('tables').fetch('additional_tags').find { |column| column['name'] == 'name' }['limit']
          fail_at('tag_name_exceeds_target_limit', side, row) if valid && limit.is_a?(Integer) && name.length > limit
        end
      end
      bag(document.tags.map { |row| row['name'] }).each do |name, count|
        fail_at('duplicate_tag_name', side, nil, name) if count > 1
      end
      document.assignments.each do |row|
        required(row, %w[id tag_id taggable_type taggable_id created_at], side)
        physical_counts[row['tag_id']] += 1
        object = objects[[row['taggable_type'], row['taggable_id']]]
        tag = tags[row['tag_id']]
        fail_at('orphan_tag', side, row) unless tag
        fail_at('orphan_object', side, row) unless object
        fail_at('unsupported_type', side, row) unless %w[Issue WikiPage].include?(row['taggable_type'])
        if side == 'source'
          required(row, %w[context tagger_id tagger_type], side)
          fail_at('unsupported_context', side, row) unless row['context'] == 'tags'
          fail_at('non_null_tagger', side, row) unless row['tagger_id'].nil? && row['tagger_type'].nil?
        end
        next unless object && tag
        fail_at('absorbed_issue_has_tags', side, row) if object[:absorbed]
        fail_at('foreign_object_has_tags', side, row) if object[:foreign]
        next unless tag['name'].is_a?(String) || tag['name'].is_a?(Hash)

        name = byte_key(tag['name'])
        key = object[:key] + [name]
        assignments << key
        dates << key + [timestamp(row['created_at'], side, row)]
        logical_assignment_counts[key] += 1
        active = row['taggable_type'] == 'Issue' ? 'active_issue_tags' : 'active_wiki_tags'
        fail_at('tag_visibility_disabled', side, row) unless settings[active] == '1'
      end
      unless foreign_objects.empty?
        types = %w[Issue WikiPage].map { |type| "#{type}=#{foreign_objects.count { |row| row['type'] == type }}" }
        @information << "foreign_unlabelled_objects count=#{foreign_objects.length} #{types.join(' ')} " \
                        "projects=#{foreign_objects.map { |row| row['project'] }.uniq.length} (target projects that are not in the source)"
      end
      logical_assignment_counts.each do |key, count|
        fail_at('duplicate_assignment_projection', side, nil, key) if count > 1
      end
      document.tags.each do |row|
        unless row['actual_taggings_count'].is_a?(Integer) && row['actual_taggings_count'] == physical_counts[row['id']]
          fail_at('physical_count_evidence_mismatch', side, row)
        end
        next if row['taggings_count'].is_a?(Integer) && row['taggings_count'] == physical_counts[row['id']]
        if side == 'target'
          fail_at('taggings_count_mismatch', side, row)
        else
          @information << "source_counter_mismatch id=#{row['id']} (destination must recompute)"
        end
      end
      { objects: logical_objects, catalog: catalog, assignments: assignments, dates: dates, settings: settings }
    end

    def run
      raise InvalidEvidence, 'extract side mismatch' unless @source.meta['side'] == 'source' && @target.meta['side'] == 'target'
      validate_schema(@source, 'source')
      validate_schema(@target, 'target')
      report_map
      @source_projects = @source.objects.map { |row| row['project'] }.uniq
      source = inventory(@source, 'source')
      target = inventory(@target, 'target')
      difference('object_coverage', source[:objects], target[:objects])
      difference('tag_catalog_or_dates', source[:catalog], target[:catalog])
      difference('assignment', source[:assignments], target[:assignments])
      difference('assignment_timestamp', source[:dates], target[:dates])
      difference('effective_settings', source[:settings].to_a, target[:settings].to_a)
      @information << 'order: not-certified (SQL IDs and timestamps do not establish API order)'
      [@source, @target].each do |document|
        observed = document.objects.count { |row| !row['source_order'].nil? }
        @information << "order_observations side=#{document.meta['side']} objects=#{observed}"
      end
      # Compare any explicit observations without using them as a gate.
      @source.objects.each do |row|
        next unless row['source_order'].is_a?(Array)
        new_id = row['type'] == 'Issue' ? @remap.fetch(row['id'], {}).fetch('to', row['csid']) : nil
        peer = @target.objects.find do |other|
          other['type'] == row['type'] && other['project'] == row['project'] &&
            other[row['type'] == 'Issue' ? 'csid' : 'title'] == (row['type'] == 'Issue' ? new_id : row['title'])
        end
        source_names = row['source_order'].map { |id| @source.tags.find { |tag| tag['id'] == id }&.fetch('name') }
        target_names = peer && peer['source_order'].is_a?(Array) && peer['source_order'].map do |id|
          @target.tags.find { |tag| tag['id'] == id }&.fetch('name')
        end
        equal = target_names && !source_names.include?(nil) && source_names == target_names
        @information << "order_observation id=#{row['id']} observation_equal=#{!!equal} (not-certified)"
      end
      self
    end

    def print(io = $stdout)
      io.puts "Objects: #{@source.objects.length} source, #{@target.objects.length} target"
      io.puts "Tags: #{@source.tags.length} source, #{@target.tags.length} target"
      io.puts "Assignments: #{@source.assignments.length} source, #{@target.assignments.length} target"
      @information.each { |line| io.puts "  #{line}" }
      io.puts "Failures (#{@failures.length})"
      @failures.each { |line| io.puts "  #{line}" }
    end
  end

  def self.compare_cli(argv)
    show_names = false
    parser = OptionParser.new do |options|
      options.banner = 'usage: ruby compare.rb SOURCE.jsonl TARGET.jsonl REPORT.json [--show-names]'
      options.on('--show-names') { show_names = true }
    end
    parser.parse!(argv)
    raise InvalidEvidence, parser.banner unless argv.length == 3
    source, target = argv.first(2).map { |path| Document.new(path) }
    begin
      report = JSON.parse(File.read(argv[2]))
    rescue JSON::ParserError
      raise InvalidEvidence, 'invalid conversion report JSON'
    end
    comparison = Comparison.new(source, target, report, show_names: show_names).run
    comparison.print
    comparison.failures.empty? ? 0 : 1
  rescue InvalidEvidence, OptionParser::ParseError => error
    warn "Invalid evidence: #{error.message}"
    2
  rescue StandardError => error
    # Runtime errors must not leak tag names through exception diagnostics.
    warn "Invalid evidence: #{error.class} (no gate certification)"
    2
  end
end

exit TagsEvidence.compare_cli(ARGV) if $PROGRAM_NAME == __FILE__
