# frozen_string_literal: true

# Step 7.4: compares how every text renders in the old and in the new
# instance, from two render_text.rb extracts and the conversion report. No
# Rails or third-party gems are needed.
#
#   ruby compare_render.rb SOURCE.jsonl TARGET.jsonl REPORT.json [--details]
#
# Failures (exit 1):
#   - a text of the new instance still holds a placeholder of the conversion;
#   - a link or an image of the new instance points to the old instance;
#   - a text shows fewer images than in the old instance, or another file;
#   - a link to an item, a user or an attachment leads to another one than in
#     the old instance (items paired by identity, users by login,
#     attachments by file name and SHA-256), or disappears without the
#     report entry that announces it;
#   - an attachment of the new instance has no attachment with the same file
#     name and SHA-256 in the old one, or one of the old instance is missing
#     without a report entry that announces it.
# A text that renders differently otherwise (other tags or visible text) is
# explained when the report announces it for that text (Markdown dialect,
# rewritten links to the old instance, escaped references, broken links), and
# unexplained if not. Both counts must be 0.
require 'json'
require 'optparse'
require_relative '../converter/lib/snapshots_gen/converter/rules'

module RenderComparison
  FORMAT = 'render-text-v1'
  Rules = SnapshotsGen::Converter::Rules
  # Report entries that announce, for one text, that it renders differently.
  EXPLAINING = %w[markdown_dialect instance_link_rewritten reference_neutralized user_reference_neutralized
                  attachment_link_broken item_link_broken link_destination_bracketed].freeze

  class Comparison
    attr_reader :failures, :unexplained, :explained, :compared, :unpaired

    def initialize(source, target, report)
      @source_meta, @source = split(source, 'source')
      @target_meta, @target = split(target, 'target')
      @entries = report.fetch('entries')
      @by_subject = @entries.group_by { |entry| entry['subject'] }
      @failures, @unexplained = [], []
      @explained = Hash.new(0)
      @compared = 0
      @unpaired = Hash.new(0)
      @old_host = @source_meta['host'].to_s.downcase.split('/').first.to_s
      pair_items
    end

    def run
      targets = @target.select { |row| row['kind'] == 'text' }.group_by { |row| target_key(row) }
      @target.each { |row| check_target(row) if row['kind'] == 'text' }
      seen = Hash.new(0)
      @source.select { |row| row['kind'] == 'text' }.each do |row|
        key = source_key(row)
        index = (seen[key] += 1) - 1
        other = key && Array(targets[key])[index]
        unless other
          reason = missing_reason(row)
          if reason
            @unpaired["#{row['type']} (#{reason})"] += 1
          else
            @failures << "#{where(row)}: no counterpart in the target"
          end
          next
        end
        @compared += 1
        compare_text(row, other)
      end
      compare_attachments
      self
    end

    def ok?
      @failures.empty? && @unexplained.empty?
    end

    def print(io = $stdout, details: false)
      io.puts "Texts: #{@source.count { |row| row['kind'] == 'text' }} in the source, " \
              "#{@target.count { |row| row['kind'] == 'text' }} in the target, #{@compared} compared"
      io.puts "Not compared, as the report says: #{@unpaired.empty? ? 'none' : @unpaired.sort.map { |type, count| "#{type} #{count}" }.join(', ')}"
      io.puts "Explained differences (#{@explained.values.sum}):"
      @explained.sort.each { |reason, count| io.puts "  #{reason}: #{count}" }
      io.puts "Unexplained differences (#{@unexplained.length}):"
      @unexplained.each { |line| io.puts "  #{line}" } if details || @unexplained.length <= 50
      io.puts "Failures (#{@failures.length}):"
      @failures.each { |line| io.puts "  #{line}" }
    end

    private

    def split(rows, side)
      meta = rows.find { |row| row['kind'] == 'meta' }
      raise ArgumentError, "the #{side} extract is not a render_text.rb extract (#{FORMAT})" unless meta && rows.all? { |row| row['format'] == FORMAT }

      [meta, rows.reject { |row| row['kind'] == 'meta' }]
    end

    # A source item => [project, CSID] in the target: the same CSID unless
    # the report renumbered or normalized it.
    def pair_items
      @renamed = @entries.select { |entry| %w[identity_renumbered identity_prefix_normalized].include?(entry['code']) }
                         .to_h { |entry| [entry['subject'], entry.dig('detail', 'to')] }
    end

    def mapped_item(identity)
      return nil unless identity && identity['id']

      [identity['project'], @renamed.fetch("item:#{identity['id']}", identity['csid'])]
    end

    def source_key(row)
      case row['type']
      when 'description' then ['description', *mapped_item(row['item'])]
      when 'note' then ['note', *mapped_item(row['item']), row['at']]
      when 'field'
        native = Rules::NATIVE_ISSUE_FIELDS[row['field']]
        ['field', *mapped_item(row['item']), native ? native['field'] : row['field']]
      when 'wiki' then ['wiki', row.dig('page', 'project'), row.dig('page', 'title'), row.dig('page', 'version')]
      when 'document' then ['document', row.dig('document', 'project'), row.dig('document', 'title')]
      when 'project' then ['project', row['project']]
      end
    end

    def target_key(row)
      case row['type']
      when 'description' then ['description', row.dig('item', 'project'), row.dig('item', 'csid')]
      when 'note' then ['note', row.dig('item', 'project'), row.dig('item', 'csid'), row['at']]
      when 'field' then ['field', row.dig('item', 'project'), row.dig('item', 'csid'), row['field']]
      when 'wiki' then ['wiki', row.dig('page', 'project'), row.dig('page', 'title'), row.dig('page', 'version')]
      when 'document' then ['document', row.dig('document', 'project'), row.dig('document', 'title')]
      when 'project' then ['project', row['project']]
      end
    end

    # Why a source text has no counterpart, when the report says so: its item
    # became a document, its journal or its field was dropped.
    def missing_reason(row)
      item = row['item'] && row['item']['id']
      if item && @entries.any? { |entry| entry['code'] == 'document_item_absorbed' && entry['subject'].to_s.start_with?("##{item} ") }
        'item turned into a document'
      elsif row['type'] == 'note' && @by_subject["journal ##{row['id']}"].to_a.any? { |entry| entry['code'] == 'history_journal_dropped' }
        'journal dropped'
      elsif row['type'] == 'field' && @by_subject["item:#{row['id']}"].to_a.any? { |entry| entry['code'] == 'field_dropped' && entry.dig('detail', 'field') == row['field'] }
        'field dropped'
      end
    end

    # The subject under which the converter reported this text.
    def subject(row)
      case row['type']
      when 'description' then "item:#{row['id']}"
      when 'note' then "journal ##{row['id']}"
      when 'field'
        native = Rules::NATIVE_ISSUE_FIELDS[row['field']]
        "item:#{row['id']} #{native ? native['field'] : row['field']}"
      when 'wiki' then "wiki version ##{row['id']}"
      when 'document' then "document:#{row['id']}"
      when 'project' then "project:#{row['id']}"
      end
    end

    def where(row)
      item = row['item']
      label = item ? "#{item['project']}/#{item['csid']}" : (row['page'] || row['document'] || row['project']).to_s
      "#{row['type']} #{label}#{row['field'] ? " #{row['field']}" : ''}#{row['at'] ? " #{row['at']}" : ''}"
    end

    def old_host?(link)
      host = link['host'].to_s
      !@old_host.empty? && (host == @old_host || host.start_with?("#{@old_host}:"))
    end

    # Placeholders and links to the old instance, in every text of the new one.
    def check_target(row)
      @failures << "#{where(row)}: #{row['markers']} placeholders left" if row['markers'].to_i.positive?
      (row['links'] + row['images']).each do |link|
        @failures << "#{where(row)}: points to the old instance (#{link['external']})" if link['external'] && old_host?(link)
      end
    end

    def evidence?(row, codes, detail = {})
      Array(@by_subject[subject(row)]).any? do |entry|
        codes.include?(entry['code']) && detail.all? { |key, value| entry.dig('detail', key).to_s == value.to_s }
      end
    end

    def compare_text(before, after)
      context = where(before)
      compare_images(before, after, context)
      compare_links(before, after, context)
      return if before['tags'] == after['tags'] && normalized(before['visible']) == normalized(after['visible'])

      reasons = Array(@by_subject[subject(before)]).map { |entry| entry['code'] }.uniq & EXPLAINING
      if reasons.empty?
        @unexplained << "#{context}: renders differently (#{tag_difference(before['tags'], after['tags'])})"
      else
        reasons.each { |reason| @explained["#{reason} [report.json]"] += 1 }
      end
    end

    # Item links show the item number and, for "##", its tracker: both may
    # change. Everything else must read the same.
    def normalized(text)
      text.to_s.gsub(/\b[\w-]+ #\d+/, '#N').gsub(/#\d+/, '#N').gsub(/\s+/, '')
    end

    def tag_difference(before, after)
      (before.keys | after.keys).sort.filter_map do |tag|
        delta = after.fetch(tag, 0) - before.fetch(tag, 0)
        "#{tag}#{delta.positive? ? '+' : ''}#{delta}" unless delta.zero?
      end.join(' ').then { |text| text.empty? ? 'visible text' : text }
    end

    def working(images)
      images.reject { |image| image.key?('broken') || (image['external'] && old_host?(image)) }
    end

    def image_identity(image)
      image['attachment'] ? ['attachment', image['attachment']['filename'], image['attachment']['sha256']] : ['external', image['external']]
    end

    def compare_images(before, after, context)
      source = before['images'].reject { |image| image.key?('broken') }
      target = working(after['images'])
      if target.length < source.length
        @failures << "#{context}: #{source.length} images in the source, #{target.length} in the target"
        return
      end
      missing = multiset_difference(source.map { |image| image_identity(image) }, target.map { |image| image_identity(image) })
      missing.each { |identity| @failures << "#{context}: image #{identity[1]} is not the same file in the target" }
    end

    def link_identity(link)
      if link['item']
        link['item'].key?('missing') ? ['item', 'missing'] : ['item', *mapped_item(link['item'])]
      elsif link['user'] then ['user', link['user']['login'] || 'missing']
      elsif link['attachment'] then ['attachment', link['attachment']['filename'], link['attachment']['sha256']]
      end
    end

    def target_link_identity(link)
      if link['item']
        link['item'].key?('missing') ? ['item', 'missing'] : ['item', link['item']['project'], link['item']['csid']]
      elsif link['user'] then ['user', link['user']['login'] || 'missing']
      elsif link['attachment'] then ['attachment', link['attachment']['filename'], link['attachment']['sha256']]
      end
    end

    # Links to items, users and attachments must lead to the same record. A
    # source link may be missing in the target only with the entry that
    # announces it for this text (an escaped reference, a broken link).
    def compare_links(before, after, context)
      source = before['links'].filter_map { |link| link_identity(link) && [link, link_identity(link)] }
      target = after['links'].filter_map { |link| target_link_identity(link) }
      remaining = target.dup
      source.each do |link, identity|
        index = remaining.index(identity)
        if index
          remaining.delete_at(index)
          next
        end
        next if announced_loss?(before, link)

        @failures << "#{context}: link to #{identity.join(' ')} leads elsewhere or is gone in the target"
      end
      remaining.each do |identity|
        next if identity == %w[item missing] || identity == %w[user missing]

        @failures << "#{context}: link to #{identity.join(' ')} that the source does not have"
      end
    end

    def announced_loss?(row, link)
      if link['item'] && link['item']['id']
        evidence?(row, %w[reference_neutralized item_link_broken], 'reference' => link['item']['id'])
      elsif link['item'] || (link['user'] && link['user'].key?('missing'))
        true # it led nowhere in the source either
      elsif link['attachment']
        link['attachment'].key?('missing') || evidence?(row, %w[attachment_link_broken])
      elsif link['user']
        evidence?(row, %w[user_reference_neutralized])
      end
    end

    def multiset_difference(left, right)
      remaining = right.dup
      left.reject do |value|
        index = remaining.index(value)
        index && remaining.delete_at(index)
      end
    end

    # Every attachment of a migrated project must be a file of the source,
    # byte for byte; every source attachment must be in the target unless the
    # report says why not.
    def compare_attachments
      source = @source.select { |row| row['kind'] == 'attachment' }
      projects = source.map { |row| row['project'] }.compact.uniq
      target = @target.select { |row| row['kind'] == 'attachment' && projects.include?(row['project']) }
      unmatched = source.dup
      target.each do |row|
        # The same file can be in several attachments, some of them not
        # migrated on purpose: an announced one is taken last.
        same = ->(candidate) { [candidate['filename'], candidate['sha256']] == [row['filename'], row['sha256']] }
        index = unmatched.index { |candidate| same.call(candidate) && !attachment_announced?(candidate) } || unmatched.index(&same)
        if index
          unmatched.delete_at(index)
        else
          @failures << "attachment ##{row['id']} (#{row['filename']}) of #{row['project']}: no file of the source with this name and SHA-256"
        end
      end
      unmatched.each do |row|
        if attachment_announced?(row)
          @explained['attachment not migrated [report.json]'] += 1
        else
          @failures << "attachment ##{row['id']} (#{row['filename']}) is not in the target and the report does not say why"
        end
      end
    end

    def attachment_announced?(row)
      @entries.any? do |entry|
        case entry['code']
        when 'attachment_missing' then entry.dig('detail', 'attachment').to_s == row['id'].to_s
        when 'attachment_without_container' then entry['subject'] == "attachment ##{row['id']}"
        when 'unsupported_content' then entry['subject'] == "attachments of #{row['container_type']}"
        else false
        end
      end
    end
  end

  def self.cli(argv)
    options = {}
    parser = OptionParser.new do |p|
      p.banner = 'Usage: compare_render.rb SOURCE.jsonl TARGET.jsonl REPORT.json [--details]'
      p.on('--details', 'List every unexplained difference') { options[:details] = true }
    end
    parser.parse!(argv)
    raise ArgumentError, parser.banner unless argv.length == 3

    source, target = argv.first(2).map { |path| File.foreach(path).map { |line| JSON.parse(line) } }
    comparison = Comparison.new(source, target, JSON.parse(File.read(argv[2]))).run
    comparison.print(details: options[:details])
    comparison.ok? ? 0 : 1
  rescue ArgumentError, KeyError, TypeError, NoMethodError, JSON::ParserError, SystemCallError, OptionParser::ParseError => e
    warn "comparison error: #{e.message}"
    2
  end
end

exit RenderComparison.cli(ARGV) if $PROGRAM_NAME == __FILE__
