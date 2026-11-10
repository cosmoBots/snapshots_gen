# frozen_string_literal: true

# Compare two history_text.rb v2 extracts. No Rails or third-party gems are
# needed unless --history is used (the converter image already has rubyzip).
require 'json'
require 'optparse'
require_relative '../converter/lib/snapshots_gen/converter/rules'

module HistoryComparison
  Rules = SnapshotsGen::Converter::Rules
  REFS = {
    'status_id' => 'statuses', 'tracker_id' => 'trackers', 'priority_id' => 'priorities',
    'assigned_to_id' => 'users', 'author_id' => 'users', 'category_id' => 'categories',
    'fixed_version_id' => 'versions', 'project_id' => 'projects', 'parent_id' => 'items'
  }.freeze
  REFERENCE_PATTERN = /(?<![A-Za-z0-9_!&-])#(\d+)(?![A-Za-z0-9_-])/.freeze

  class Comparison
    attr_reader :failures, :unexplained, :explained

    def initialize(source, target, report = {}, history: {}, import_reports: [])
      @source, @target = source, target
      @entries = report.fetch('entries', [])
      @history = history
      @failures, @unexplained, @explained = [], [], Hash.new { |h, k| h[k] = [] }
      @pairs, @ids = {}, {}
      validate!
      pair_items
      # An importer discard is diagnostic evidence, not permission to lose a
      # record. Expected losses must already be identified by the converter.
      import_reports.each do |entry|
        raise ArgumentError, 'use a real import report, not a dry run' if entry['dry_run']
        entry.fetch('dropped').each do |drop|
          @failures << "importer: #{drop.fetch('kind')} ##{drop.fetch('id')}: #{drop.fetch('reason')}"
        end
      end
    end

    def run
      @source.each do |old|
        new = @pairs[old['id']]
        unless new
          absorbed = entry('document_item_absorbed') { |e| e['subject'].to_s.match?(/\A##{old['id']}\s/) }
          if absorbed
            explain('document_item_absorbed [report.json]', location(old))
          else
            @failures << "#{location(old)}: item missing in target"
          end
          next
        end
        compare_item(old, new)
      end
      used = @pairs.values.map { |row| row['id'] }
      @target.reject { |row| used.include?(row['id']) }.each { |row| generated_item(row) }
      self
    end

    def ok?
      @failures.empty? && @unexplained.empty?
    end

    def print(io = $stdout, details: false, show: nil)
      io.puts "Items: #{@source.length} in the source, #{@target.length} in the target"
      io.puts "Explained differences (#{@explained.values.map(&:length).inject(0, :+)}):"
      @explained.sort.each do |reason, rows|
        io.puts "  #{reason}: #{rows.length}"
        rows.each { |row| io.puts "    #{row}" } if details
      end
      io.puts "Unexplained differences (#{@unexplained.length}):"
      @unexplained.each { |row| io.puts "  #{row}" }
      io.puts "Failures (#{@failures.length}):"
      @failures.each { |row| io.puts "  #{row}" }
      if show
        [ ['source', @source], ['target', @target] ].each do |side, rows|
          rows.select { |row| row['csid'] == show }.each { |row| io.puts "#{side}: #{JSON.pretty_generate(row)}" }
        end
      end
    end

    private

    def validate!
      [@source, @target].each do |rows|
        ids, journals, details = [], [], []
        rows.each do |row|
          raise ArgumentError, 'regenerate both extracts with history_text.rb v2' unless row['format'] == 'history-text-v2'
          %w[id project csid author author_login created updated closed watchers watcher_logins time journals].each { |key| row.fetch(key) }
          raise ArgumentError, 'duplicate item id in extract' if ids.include?(row['id'])
          ids << row['id']
          row.fetch('journals').each do |journal|
            %w[id at by by_login private edited notes details raw_details].each { |key| journal.fetch(key) }
            raise ArgumentError, 'duplicate journal id in extract' if journals.include?(journal['id'])
            journals << journal['id']
            journal['raw_details'].each do |detail|
              %w[id property prop_key old_value value field label ref old_ref value_ref rendered].each { |key| detail.fetch(key) }
              raise ArgumentError, 'duplicate detail id in extract' if details.include?(detail['id'])
              details << detail['id']
            end
          end
        end
      end
      languages = (@source + @target).map { |row| row.fetch('language') }.uniq
      raise ArgumentError, 'extract languages differ' if languages.length > 1
      identities = @target.map { |row| [row['project'], row['csid']] }
      raise ArgumentError, 'duplicate destination project/CSID' unless identities.uniq.length == identities.length
      @target.each do |row|
        row['journals'].each do |journal|
          lines = journal['details'] + journal['raw_details'].flat_map { |detail| detail['rendered'] }
          @failures << "#{location(row)} journal ##{journal['id']}: Translation missing" if lines.any? { |line| line.match?(/translation missing/i) }
          @failures << "#{location(row)} journal ##{journal['id']}: shows as edited" if journal['edited']
          journal['raw_details'].each do |detail|
            if %w[old_ref value_ref].any? { |side| detail[side].is_a?(Hash) && detail[side].key?('missing') }
              @failures << "#{location(row)} journal ##{journal['id']}: unresolved target reference in detail ##{detail['id']}"
            end
          end
        end
      end
    end

    def location(row)
      "#{row['project']}/#{row['csid']} (##{row['id']})"
    end

    def entry(code)
      @entries.find { |e| e['code'] == code && yield(e) }
    end

    def explain(reason, message)
      @explained[reason] << message
    end

    def pair_items
      consumed = []
      @source.each do |old|
        rename = @entries.select do |e|
          %w[identity_renumbered identity_prefix_normalized].include?(e['code']) &&
            e['subject'] == "item:#{old['id']}" && e.dig('detail', 'from').to_s == old['csid']
        end
        raise ArgumentError, 'ambiguous identity report' if rename.length > 1
        csid = rename.empty? ? old['csid'] : rename.first.fetch('detail').fetch('to')
        candidates = @target.select { |row| row['project'] == old['project'] && row['csid'] == csid }
        if candidates.length > 1 || (candidates.first && consumed.include?(candidates.first['id']))
          @failures << "#{location(old)}: ambiguous destination identity"
          next
        end
        next if candidates.empty?

        new = candidates.first
        consumed << new['id']
        @pairs[old['id']] = new
        @ids[old['id']] = new['id']
        explain("#{rename.first['code']} [report.json]", location(old)) unless rename.empty?
      end
    end

    def generated_item(row)
      projects = @history.fetch('projects', []).each_with_object({}) { |p, h| h[p['id']] = p['identifier'] }
      candidates = @history.fetch('items', []).select do |item|
        item['synthetic'] && item['csid'] == row['csid'] && projects[item['project_id']] == row['project']
      end
      item = candidates.length == 1 && candidates.first
      proof = if item && item['synthetic'] == 'group' && item['key'].match?(/\Aitem:group-\d+\z/)
                entry('synthetic_chapter') { |e| e.dig('detail', 'around') == item['key'].sub('group-', '') }
              elsif item && item['synthetic'] == 'datum'
                entry('datum_created') { |e| e['subject'] == item['key'] && e.dig('detail', 'variable') == row['csid'] }
              elsif item && item['synthetic'] == 'data_section' && item['key'] == "item:data-#{item['project_id']}" &&
                    item['tracker'] == 'csData' && row['tracker'] == 'csData' && row['subject'] == 'Project data' && row['parent_id'].nil?
                # Explicitly authorized code rule: Plan#plan_data! creates one
                # section per project containing a nonempty rqVar.
                sources = @source.select { |source| source['project'] == row['project'] }.map { |source| source['id'] }
                datum = entry('datum_created') { |e| sources.any? { |id| e.dig('detail', 'requirement') == "item:#{id}" } }
                unmapped = entry('field_value_unmapped') { |e| e.dig('detail', 'field') == 'rqVar' && sources.any? { |id| e['subject'] == "item:#{id}" } }
                { 'code' => 'data_section [Plan#plan_data!]' } if datum || unmapped
              end
      if proof && row['journals'].empty? && row['time'] == 0 && row['watchers'].empty?
        explain("#{proof['code']} [report.json + .cshistory/items]", location(row))
      else
        @unexplained << "#{location(row)}: only in target; no exact generation evidence (or unexpected history/time/watchers)"
      end
    end

    def compare_item(old, new)
      context = location(old)
      if old.key?('tracker')
        tracker = if old['tracker'] == Rules::REQUIREMENT_TRACKER
                    old['legacy_rq_type'] == 'Info' ? 'csInfo' : Rules::REQUIREMENT.fetch('name')
                  else
                    Rules::TRACKERS.fetch(old['tracker'], {}).fetch('name', old['tracker'])
                  end
        @failures << "#{context}: current tracker differs from Plan#target_tracker" unless tracker == new['tracker']
      end
      %w[author author_login created updated closed watchers watcher_logins time].each do |key|
        @failures << "#{context}: #{key} differs" unless old[key] == new[key]
      end
      journals = old['journals'].sort_by { |j| [j['at'].to_s, j['id']] }.reject do |journal|
        proof = entry('history_journal_dropped') do |e|
          e['subject'] == "journal ##{journal['id']}" && e.dig('detail', 'item') == "item:#{old['id']}"
        end
        next false unless proof

        if journal['notes'].strip.empty? && journal['raw_details'].all? { |d| dropped_detail(old, d, journal['id']) }
          explain('history_journal_dropped [report.json]', "#{context} journal ##{journal['id']}")
          true
        else
          @failures << "#{context} journal ##{journal['id']}: drop report would hide notes or unreported details"
          false
        end
      end
      target = new['journals'].sort_by { |j| [j['at'].to_s, j['id']] }
      @failures << "#{context}: #{journals.length} journals -> #{target.length}" unless journals.length == target.length
      journals.zip(target).each do |before, after|
        next unless after

        where = "#{context} journal ##{before['id']}"
        %w[at by by_login private].each { |key| @failures << "#{where}: #{key} differs" unless before[key] == after[key] }
        expected_notes = references(before['notes'], "journal ##{before['id']}")
        if expected_notes != after['notes']
          @failures << "#{where}: notes differ (including item reference identity)"
        elsif before['notes'] != after['notes']
          explain('item references [HistoryBuilder#references + identity mapping]', where)
        end
        compare_details(old, new, before, after, where)
      end
    end

    def references(text, subject)
      return text unless text.is_a?(String)

      text.gsub(REFERENCE_PATTERN) do |token|
        id = Regexp.last_match(1).to_i
        if @ids.key?(id)
          "##{@ids[id]}"
        elsif entry('reference_neutralized') { |e| e['subject'] == subject && e.dig('detail', 'reference') == id }
          "!##{id}"
        else
          message = "#{subject}: source reference ##{id} has neither a mapped identity nor reference_neutralized evidence"
          @unexplained << message unless @unexplained.include?(message)
          token
        end
      end
    end

    def reference_evidence(old, detail, journal_id, code)
      return nil unless detail['property'] == 'attr' && REFS.key?(detail['prop_key'])

      entry(code) do |e|
        d = e.fetch('detail', {})
        e['subject'] == "detail ##{detail['id']}" && d['item'] == "item:#{old['id']}" &&
          d['journal'] == journal_id && d['field'] == detail['prop_key'] &&
          d['old_value'] == detail['old_value'] && d['value'] == detail['value'] &&
          d['missing'].is_a?(Array) && !d['missing'].empty? && (d['missing'] - %w[old new]).empty?
      end
    end

    # HistoryBuilder#translate_attachment: an attachment the item no longer
    # has (deleted from the source, or migrated with another container) is
    # written with id 0 and reported with every identifier. The reason must
    # agree with the source: a deleted attachment is missing there, one not
    # migrated with this item still exists.
    def attachment_evidence(old, detail, journal_id)
      return nil unless detail['property'] == 'attachment'

      field = detail['field']
      deleted = field == { 'missing_attachment' => detail['prop_key'] }
      present = field.is_a?(Hash) && field.key?('filename')
      sides = { 'old_value' => 'old', 'value' => 'new' }.reject { |column, _side| detail[column].to_s.empty? }.values
      entry('history_attachment_cleared') do |e|
        d = e.fetch('detail', {})
        e['subject'] == "detail ##{detail['id']}" && d['item'] == "item:#{old['id']}" && d['journal'] == journal_id &&
          d['attachment'] == detail['prop_key'] && d['old_value'] == detail['old_value'] && d['value'] == detail['value'] &&
          d['missing'] == sides &&
          ((d['reason'] == 'deleted from the source' && deleted) || (d['reason'] == 'not migrated with this item' && present))
      end
    end

    def dropped_detail(old, detail, journal_id)
      regular = entry('history_detail_dropped') do |e|
        e['subject'] == "detail ##{detail['id']}" && e.dig('detail', 'item') == "item:#{old['id']}" && !e.dig('detail', 'reason').to_s.empty?
      end
      return regular if regular

      proof = reference_evidence(old, detail, journal_id, 'history_reference_dropped')
      return nil unless proof

      missing = proof['detail']['missing']
      proof if (missing.include?('old') || detail['old_value'].to_s.empty?) && (missing.include?('new') || detail['value'].to_s.empty?)
    end

    def signature(detail)
      custom_definition = detail['property'] == 'cf' ? [detail['field_format'], detail['multiple']] : nil
      [detail['property'], detail['field'], custom_definition, detail['old_value'], detail['value'], detail['old_ref'], detail['value_ref']]
    end

    def expected_detail(detail, new, cleared = nil, attachment = nil)
      result = detail.dup
      reasons = []
      if attachment
        result['prop_key'] = '0'
        result['field'] = { 'missing_attachment' => '0' }
        reasons << 'history_attachment_cleared [report.json; HistoryBuilder#translate_attachment]'
      end
      if cleared
        cleared['detail']['missing'].each do |side|
          result[side == 'old' ? 'old_value' : 'value'] = nil
          result[side == 'old' ? 'old_ref' : 'value_ref'] = nil
        end
        reasons << 'history_reference_cleared [report.json; HistoryBuilder#translate_reference]'
      end
      if detail['property'] == 'cf' && (native = Rules::NATIVE_ISSUE_FIELDS[detail['field']])
        return [result, reasons] if native['requirement'] && new.key?('tracker') && new['tracker'] != Rules::REQUIREMENT.fetch('name')

        result['property'], result['field'] = 'attr', native.fetch('field')
        %w[old_value value].each do |side|
          value = detail[side]
          result[side] = native['map'] && !value.nil? ? native['map'].fetch(value.to_s, value) : value
        end
        reasons << "native field #{detail['field']} -> #{result['field']} [Rules::NATIVE_ISSUE_FIELDS; HistoryBuilder#translate_custom_field_detail]"
      end
      if detail['ref']
        %w[old_ref value_ref].each do |side|
          ref = result[side]
          next unless ref.is_a?(Hash)

          mapped = ref.dup
          case detail['ref']
          when 'items'
            mapped['id'] = @ids.fetch(ref['id'], ref['id'])
            mapped['tracker'] = @pairs[ref['id']]['tracker'] if ref.key?('tracker') && @pairs[ref['id']]
          when 'statuses'
            if Rules::STATUSES.key?(ref['name'])
              mapped['name'] = Rules::STATUSES[ref['name']] || new['tracker_default_status']
            end
          when 'trackers'
            mapped['name'] = if ref['name'] == Rules::REQUIREMENT_TRACKER
                               Rules::REQUIREMENT.fetch('name')
                             else
                               Rules::TRACKERS.fetch(ref['name'], {}).fetch('name', ref['name'])
                             end
          end
          result[side] = mapped
          reasons << "#{detail['ref']} reference [Rules; HistoryBuilder::ATTR_REFS]" if mapped != ref
        end
        # Compare referenced identities, not their database primary keys.
        %w[old_value value].each do |side|
          result[side] = nil if result[side == 'old_value' ? 'old_ref' : 'value_ref'].is_a?(Hash)
        end
      elsif detail['property'] == 'attr' && detail['prop_key'] == 'description'
        %w[old_value value].each { |side| result[side] = references(detail[side], "detail ##{detail['id']}") }
        reasons << 'description references [HistoryBuilder#references]' if result != detail
      end
      [result, reasons]
    end

    def compare_details(old, new, before, after, where)
      remaining = after['raw_details'].dup
      before['raw_details'].each do |detail|
        if (proof = dropped_detail(old, detail, before['id']))
          reason = proof.dig('detail', 'reason') || 'all reference sides missing'
          category = if reason.end_with?('on an item that is not a requirement')
                       'D2 requirement field on non-requirement'
                     elsif reason.match?(/\Arelation with (item #\d+, not in the source|an AD\/RD\/CD item)/)
                       'D3 relation endpoint not migrated'
                     else
                       proof['code']
                     end
          explain("#{category} [report.json/#{proof['code']}]", "#{where} detail ##{detail['id']}: #{reason}")
          next
        end
        cleared = reference_evidence(old, detail, before['id'], 'history_reference_cleared')
        attachment = attachment_evidence(old, detail, before['id'])
        expected, reasons = expected_detail(detail, new, cleared, attachment)
        index = remaining.index { |candidate| signature(actual_detail(candidate)) == signature(expected) }
        unless index
          @failures << "#{where} detail ##{detail['id']}: missing or changed #{detail['property']}/#{detail['field']}"
          next
        end
        actual = remaining.delete_at(index)
        if signature(detail) != signature(actual)
          explain(reasons.empty? ? 'database IDs remapped [HistoryBuilder references]' : reasons.uniq.join('; '), "#{where} detail ##{detail['id']}")
        end
        next if detail['rendered'] == actual['rendered']

        native = detail['property'] == 'cf' && Rules::NATIVE_ISSUE_FIELDS.key?(detail['field'])
        forms_equal = (native || cleared) && canonical_render?(detail, old['render_templates']) && canonical_render?(actual, new['render_templates'])
        if rendered_equal?(detail, actual, expected) || forms_equal
          explain('rendering [exact field label / mapped values / item IDs / hours]', "#{where} detail ##{detail['id']}")
        else
          @unexplained << "#{where} detail ##{detail['id']}: rendered text #{detail['rendered'].inspect} -> #{actual['rendered'].inspect}"
        end
      end
      remaining.each { |detail| @failures << "#{where}: unexpected target detail ##{detail['id']} #{detail['property']}/#{detail['field']}" }
      # The aggregate renderer can group/reorder details. Do not ignore a
      # discrepancy that is absent from the individual renders.
      [[before, old], [after, new]].each do |journal, row|
        next if journal['details'].sort == journal['raw_details'].flat_map { |d| d['rendered'] }.sort

        if grouped_rendering?(journal, row['render_templates'])
          explain('R5b multiple custom field values grouped in one line [IssuesHelper#details_to_strings]',
                  "#{where} (journal ##{journal['id']})")
        else
          @unexplained << "#{where}: aggregate rendering cannot be accounted for by individual details (journal ##{journal['id']})"
        end
      end
    end

    # R5b. Redmine 4.2 and 7 (IssuesHelper#details_to_strings) render every
    # change of a journal on its own line except those of a multiple custom
    # field: the values added to one such field go in one "added" line, and
    # the removed ones in one "deleted" line, each list joined with ", ". The
    # aggregate is accepted only if it is exactly those lines: the other
    # changes as rendered alone, and for each multiple field the lines that
    # hold exactly the multiset of its added and removed values (as the same
    # renderer displays each one), in any order.
    def grouped_rendering?(journal, templates)
      return false unless templates

      remaining = journal['details'].dup
      take = lambda do |line|
        index = remaining.index(line)
        index && remaining.delete_at(index)
      end
      groups = {}
      journal['raw_details'].each do |detail|
        unless detail['property'] == 'cf' && detail['multiple']
          return false unless detail['rendered'].all? { |line| take.call(line) }

          next
        end
        group = (groups[detail['prop_key']] ||= { 'label' => detail['label'], 'added' => [], 'deleted' => [] })
        return false unless group['label'] == detail['label']

        # Redmine tests presence (nil), not emptiness.
        { 'old_value' => %w[deleted display_old], 'value' => %w[added display_value] }.each do |side, (list, display)|
          next if detail[side].nil?
          return false unless detail[display].is_a?(String) && !detail[display].empty?

          group[list] << detail[display]
        end
      end
      groups.each_value do |group|
        { 'added' => '%{value}', 'deleted' => '%{old}' }.each do |list, placeholder|
          next if group[list].empty?

          prefix, suffix = templates.fetch(list).gsub('%{label}') { group['label'] }.split(placeholder, 2)
          return false unless suffix

          line = remaining.find do |candidate|
            candidate.start_with?(prefix) && candidate.end_with?(suffix) && candidate.length >= prefix.length + suffix.length &&
              joined_values?(candidate[prefix.length...(candidate.length - suffix.length)], group[list])
          end
          return false unless line && take.call(line)
        end
      end
      remaining.empty?
    end

    # Whether text is exactly the values (a multiset) joined with ", " in
    # some order. Values may themselves hold ", ".
    def joined_values?(text, values)
      return text.empty? if values.empty?

      values.uniq.any? do |value|
        rest = values.dup
        rest.delete_at(rest.index(value))
        if rest.empty?
          text == value
        else
          text.start_with?("#{value}, ") && joined_values?(text[(value.length + 2)..], rest)
        end
      end
    end

    def actual_detail(detail)
      result = detail.dup
      if detail['ref']
        result['old_value'] = nil if detail['old_ref'].is_a?(Hash)
        result['value'] = nil if detail['value_ref'].is_a?(Hash)
      end
      result
    end

    def rendered_equal?(before, after, expected)
      # Transform only the source text using concrete old/new tokens. A
      # changed value must already have passed the structured comparison.
      lines = before['rendered'].dup
      pairs = []
      if before['field'] != after['field'] || (before['property'] == 'attr' && before['field'] == 'parent_id')
        unless before['label'].to_s.empty? || after['label'].to_s.empty?
          lines = lines.map { |line| line.sub(/\A#{Regexp.escape(before['label'])}(?=\s)/) { after['label'] } }
        end
      end
      %w[old_ref value_ref].each do |side|
        a, b = before[side], after[side]
        next unless a.is_a?(Hash) && b.is_a?(Hash)

        if before['ref'] == 'items'
          pairs << ["##{a['id']}", "##{b['id']}"] if @ids[a['id']] == b['id']
          pairs << [a['tracker'], b['tracker']] if @ids[a['id']] == b['id']
        elsif %w[statuses trackers].include?(before['ref'])
          pairs << [a['name'], b['name']]
        end
      end
      %w[old_value value].each do |side|
        pairs << [before[side], expected[side]] if before[side] != expected[side] && !before['ref']
      end
      pairs.reject! { |a, b| !a.is_a?(String) || !b.is_a?(String) || a.empty? || a == b }
      # Two references can start with the same tracker text but become two
      # different trackers. A global replacement cannot prove that case.
      return false if pairs.group_by(&:first).any? { |_token, values| values.map(&:last).uniq.length > 1 }

      # One pass avoids chained replacements (e.g. #1 -> #2 -> #3).
      replacements = pairs.to_h
      pattern = replacements.empty? ? nil : Regexp.union(replacements.keys.sort_by { |key| -key.length }.map { |key| /(?<![\w])#{Regexp.escape(key)}(?![\w])/ })
      lines = lines.map { |line| pattern ? line.gsub(pattern) { |token| replacements.fetch(token) } : line }
      if before['property'] == 'attr' && before['field'] == 'estimated_hours'
        lines = lines.map do |line|
          line.gsub(/(?<![\d.])(\d+)\.(\d{2}) h\b/) do |token|
            minutes = Rational("#{Regexp.last_match(1)}.#{Regexp.last_match(2)}") * 60
            minutes.denominator == 1 ? format('%d:%02d h', minutes.to_i / 60, minutes.to_i % 60) : token
          end
        end
      end
      lines == after['rendered']
    end

    def canonical_render?(detail, templates)
      return false unless templates

      old, value = detail['display_old'], detail['display_value']
      blank_old, blank_value = detail['old_value'].to_s.empty?, detail['value'].to_s.empty?
      # R6: legacy text custom fields intentionally render no values. Raw
      # old/new values have still been compared, including long text.
      if detail['property'] == 'cf' && detail['field_format'] == 'text'
        return detail['rendered'] == [templates.fetch('changed_no_detail').gsub('%{label}') { detail['label'] }]
      end
      return false if (!blank_old && old.nil?) || (!blank_value && value.nil?)

      keys = if blank_old && !blank_value
               detail['property'] == 'cf' && detail['multiple'] ? ['added'] : ['set_to']
             elsif !blank_old && blank_value
               ['deleted']
             elsif !blank_old && !blank_value
               ['changed']
             else
               []
             end
      keys.any? do |key|
        tokens = { '%{label}' => detail['label'], '%{old}' => old.to_s, '%{new}' => value.to_s, '%{value}' => value.to_s }
        line = templates.fetch(key).gsub(/%\{(?:label|old|new|value)\}/) { |token| tokens.fetch(token) }
        detail['rendered'] == [line]
      end
    end
  end

  def self.read_history(path)
    require_relative '../exporter/legacy_snapshot_format'
    result = SnapshotsGen::LegacySnapshot::Verifier.new(path).verify
    raise ArgumentError, "history package does not verify: #{result.errors.first(5).join('; ')}" unless result.ok?
    raise ArgumentError, 'expected a .cshistory package' unless result.manifest['schema'] == 'snapshots_gen-history'

    tables = result.manifest.fetch('content').fetch('tables')
    decode = lambda do |read|
      %w[projects items].each_with_object({}) do |name, rows|
        table = tables.find { |candidate| candidate['name'] == name }
        raise ArgumentError, "history package lacks #{name}" unless table

        rows[name] = read.call(table.fetch('path')).lines.map { |line| JSON.parse(line) }
      end
    end
    if File.directory?(path)
      decode.call(->(relative) { File.read(File.join(path, relative)) })
    else
      Zip::File.open(path) { |archive| decode.call(->(relative) { archive.read(relative) }) }
    end
  rescue LoadError
    raise ArgumentError, '--history requires rubyzip; run in the converter image'
  rescue StandardError => e
    raise ArgumentError, e.message
  end

  def self.cli(argv)
    options = { import_reports: [] }
    parser = OptionParser.new do |p|
      p.banner = 'Usage: compare_history.rb SOURCE.jsonl TARGET.jsonl [REPORT.json] [options]'
      p.on('--history PATH', 'Verified .cshistory (exact identities of generated items)') { |v| options[:history] = read_history(v) }
      p.on('--import-report PATH', 'Real history import report; repeatable; discards fail the gate') { |v| options[:import_reports] << JSON.parse(File.read(v)) }
      p.on('--details', 'Show individual explained differences') { options[:details] = true }
      p.on('--show CSID', 'Print complete matching items (sensitive data)') { |v| options[:show] = v }
    end
    parser.parse!(argv)
    raise ArgumentError, parser.banner unless (2..3).cover?(argv.length)

    source, target = argv.first(2).map { |path| File.foreach(path).map { |line| JSON.parse(line) } }
    report = argv[2] ? JSON.parse(File.read(argv[2])) : {}
    comparison = Comparison.new(source, target, report, history: options.fetch(:history, {}), import_reports: options[:import_reports]).run
    comparison.print(details: options[:details], show: options[:show])
    comparison.ok? ? 0 : 1
  rescue ArgumentError, KeyError, TypeError, NoMethodError, JSON::ParserError, SystemCallError, OptionParser::ParseError => e
    warn "comparison error: #{e.message}"
    2
  end
end

exit HistoryComparison.cli(ARGV) if $PROGRAM_NAME == __FILE__
