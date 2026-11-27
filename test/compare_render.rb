# frozen_string_literal: true

# Step 7.4: compares how every text renders in the old and in the new
# instance, from two render_text.rb extracts and the conversion report. It is
# the check that does not share code with the converter: it only compares
# what each Redmine rendered. No Rails or third-party gems are needed.
#
#   ruby compare_render.rb SOURCE.jsonl TARGET.jsonl REPORT.json [--details]
#
# Each text is compared node by node, in document order: structural tags,
# text, links (destination, operation, query, fragment and text) and images.
# The only differences accepted are the concrete transformations that the
# conversion report announces for that very text:
#   - item links show the item number, and for "##" the tracker name, which
#     may change: only inside the text of a link to that same item;
#   - a URL of the old instance that became a reference or a link shows the
#     reference ("#N") or the file name instead of the URL
#     (instance_link_rewritten);
#   - an escaped reference shows as text (reference_neutralized), and a link
#     to a record that was not migrated leads nowhere (item_link_broken,
#     attachment_link_broken);
#   - Markdown dialect (markdown_dialect): underline becomes italics,
#     ~text~ becomes struck, x^2 loses its superscript, a lone "-" becomes an
#     empty list item, and an image with a quoted destination (broken in the
#     old instance) becomes its text.
# Other announced dialect differences (lists, runs of underscores) cannot be
# reproduced exactly: such a text passes only
# if its words, links and images are the same, and is listed for review by
# hand. Anything else is a failure (links, images, placeholders, links to the
# old instance, attachments) or an unexplained difference.
#
# Attachments: every attachment of the new instance must be a file of the
# old one with the same name and SHA-256 in the same logical container (the
# item by its project and CSID, the document, wiki page, project or version),
# and every attachment of the old one must be there unless the report says
# why not.
#
# Exit code: 0 when there are no failures and no unexplained differences, 1
# otherwise, 2 when the input cannot be read.
require 'cgi'
require 'json'
require 'optparse'
require_relative '../converter/lib/snapshots_gen/converter/rules'

module RenderComparison
  FORMAT = 'render-text-v2'
  Rules = SnapshotsGen::Converter::Rules
  PRECISE = %w[underline strikethrough superscript empty_list_item quoted_destination].freeze
  REVIEW = %w[list_indent list_marker underscores].freeze

  class Comparison
    attr_reader :failures, :unexplained, :explained, :review, :compared, :unpaired

    def initialize(source, target, report)
      @source_meta, @source = split(source, 'source')
      @target_meta, @target = split(target, 'target')
      @entries = report.fetch('entries')
      @by_subject = @entries.group_by { |entry| entry['subject'] }
      @failures, @unexplained, @review = [], [], []
      @explained = Hash.new(0)
      @compared = 0
      @unpaired = Hash.new(0)
      @old_host = @source_meta['host'].to_s.downcase.split('/').first.to_s
      @renamed = @entries.select { |entry| %w[identity_renumbered identity_prefix_normalized].include?(entry['code']) }
                         .to_h { |entry| [entry['subject'], entry.dig('detail', 'to')] }
      @absorbed = @entries.select { |entry| entry['code'] == 'document_item_absorbed' }.to_h do |entry|
        [entry['subject'].to_s[/\A#(\d+)\s/, 1].to_i, [entry.dig('detail', 'project'), entry.dig('detail', 'document')]]
      end
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
      io.puts "To review by hand, same words, links and images (#{@review.length}):"
      @review.each { |line| io.puts "  #{line}" }
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

    def mapped_item(identity)
      return nil unless identity && identity['id']

      [identity['project'], @renamed.fetch("item:#{identity['id']}", identity['csid'])]
    end

    def source_field(name)
      native = Rules::NATIVE_ISSUE_FIELDS[name]
      native ? native['field'] : name
    end

    def source_key(row)
      case row['type']
      when 'description' then ['description', *mapped_item(row['item'])]
      when 'note' then ['note', *mapped_item(row['item']), row['at']]
      when 'field' then ['field', *mapped_item(row['item']), source_field(row['field'])]
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

    # Why a source text has no counterpart, when the report says so.
    def missing_reason(row)
      item = row['item'] && row['item']['id']
      return 'item turned into a document' if item && @absorbed.key?(item)
      if row['type'] == 'note' && Array(@by_subject["journal ##{row['id']}"]).any? { |entry| entry['code'] == 'history_journal_dropped' }
        return 'journal dropped'
      end
      return nil unless row['type'] == 'field'

      field_missing_reason(row['field'], item)
    end

    def field_missing_reason(name, item)
      native = Rules::NATIVE_ISSUE_FIELDS[name]
      return 'native field that is not text' if native && !Rules::TEXT_NATIVE_FIELDS.include?(native['field'])
      return 'field dropped' if Array(@by_subject[name]).any? { |entry| entry['code'] == 'field_dropped' }
      if Array(@by_subject["item:#{item}"]).any? { |entry| entry['code'] == 'field_dropped' && entry.dig('detail', 'field') == name }
        return 'field dropped'
      end
      if Rules::DATUM_FIELDS.include?(name) &&
         @entries.any? { |entry| entry['code'] == 'datum_created' && entry.dig('detail', 'requirement') == "item:#{item}" }
        return 'turned into project data'
      end
      if Rules::DOCUMENT_REFERENCE_FIELDS.key?(name) &&
         Array(@by_subject["item:#{item}"]).none? { |entry| entry['code'] == 'reference_text_kept' && entry.dig('detail', 'field') == name }
        return 'turned into catalog references'
      end
      nil
    end

    # The subject under which the converter reported this text.
    def subject(row)
      case row['type']
      when 'description' then "item:#{row['id']}"
      when 'note' then "journal ##{row['id']}"
      when 'field' then "item:#{row['id']} #{source_field(row['field'])}"
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

    def old_host?(destination)
      host = destination['host'].to_s
      !@old_host.empty? && host.split(':').first == @old_host.split(':').first
    end

    # Placeholders and links to the old instance, in every text of the new one.
    def check_target(row)
      @failures << "#{where(row)}: #{row['markers']} placeholders left" if row['markers'].to_i.positive?
      row['nodes'].each do |node|
        next unless %w[link img].include?(node[0]) && node[1]['kind'] == 'external' && old_host?(node[1])

        @failures << "#{where(row)}: points to the old instance (#{node[1]['url']})"
      end
    end

    def entries_for(row, code)
      Array(@by_subject[subject(row)]).select { |entry| entry['code'] == code }
    end

    # --- nodes -------------------------------------------------------------

    # What identifies a destination across instances.
    def destination_key(destination, source:)
      extra = [destination['query'], destination['fragment']]
      case destination['kind']
      when 'item'
        item = destination['item']
        return ['item', 'missing', destination['rest'], *extra] if item.key?('missing')

        ['item', *(source ? mapped_item(item) : [item['project'], item['csid']]), destination['rest'], *extra]
      when 'attachment'
        file = destination['attachment']
        return ['attachment', 'missing', destination['operation'], *extra] if file.key?('missing')

        ['attachment', file['filename'], file['sha256'], destination['operation'], destination['rest'], *extra]
      when 'user' then ['user', destination['user']['login'] || 'missing', *extra]
      when 'external' then ['external', destination['url']]
      when 'mailto' then ['mailto', destination['url']]
      when 'anchor' then ['anchor']
      when 'broken' then ['broken']
      else ['other', destination['path'] || destination['url'], *extra]
      end
    end

    # Item links show the number of the item and, for "##", its tracker.
    def link_text(destination, text)
      return text unless destination['kind'] == 'item' && destination['item']['tracker']

      tracker = destination['item']['tracker']
      text.sub(/\A#{Regexp.escape(tracker)} #\d+/, 'TRACKER #ITEM').sub(/\A#\d+/, '#ITEM')
    end

    # [type, key, text] plus, for links and images, [destination, raw text].
    def normalize(nodes, source:)
      nodes.map do |node|
        case node[0]
        when 'link' then ['link', destination_key(node[1], source: source), link_text(node[1], node[2]), node[1], node[2]]
        when 'img' then ['img', destination_key(node[1], source: source), nil, node[1], nil]
        else node
        end
      end
    end

    # Adjacent texts merged, whitespace collapsed and trimmed, empty texts
    # dropped.
    def comparable(nodes)
      merged = nodes.each_with_object([]) do |node, result|
        if node[0] == 'text' && result.last && result.last[0] == 'text'
          result.last[1] = "#{result.last[1]}#{node[1]}"
        else
          result << node.dup
        end
      end
      merged.map { |node| node[0] == 'text' ? ['text', node[1].gsub(/\s+/, ' ').strip] : node.first(3) }
            .reject { |node| node[0] == 'text' && node[1].empty? }
    end

    # The source nodes as the announced link transformations make them.
    # Returns the nodes and the report codes used.
    def transform(row, nodes)
      used = []
      rewritten = entries_for(row, 'instance_link_rewritten')
      neutralized = entries_for(row, 'reference_neutralized').map { |entry| entry.dig('detail', 'reference') }
      broken_items = entries_for(row, 'item_link_broken').map { |entry| entry.dig('detail', 'reference') }
      broken_files = entries_for(row, 'attachment_link_broken').map { |entry| entry.dig('detail', 'attachment') }
      result = nodes.map do |node|
        next node unless %w[link img].include?(node[0])

        destination = node[3]
        id = destination['kind'] == 'item' ? destination.dig('item', 'id') : destination.dig('attachment', 'id')
        if destination['kind'] == 'item' && node[0] == 'link' && neutralized.include?(id)
          used << 'reference_neutralized'
          next ['text', node[4].to_s.match?(/\A.+ #\d+(?:#note)?(?:-\d+)?: /) ? "###{id}" : node[4]]
        end
        if destination['kind'] == 'item' && broken_items.include?(id)
          used << 'item_link_broken'
          next [node[0], ['item', 'missing', *node[1].last(3)], node[2], destination, node[4]]
        end
        if destination['kind'] == 'attachment' && broken_files.include?(id)
          used << 'attachment_link_broken'
          key = node[0] == 'img' ? ['broken'] : ['attachment', 'missing', destination['operation'], destination['query'], destination['fragment']]
          next [node[0], key, node[2], destination, node[4]]
        end
        if node[0] == 'link' && node[4].to_s.match?(%r{\A(?:https?:)?//}i) &&
           rewritten.any? { |entry| entry.dig('detail', 'kind') == destination['kind'] && entry.dig('detail', 'source_id') == id }
          used << 'instance_link_rewritten'
          text = if destination['kind'] == 'item'
                   fragment = destination['fragment'].to_s
                   "#ITEM#{fragment.match?(/\Anote-\d+\z/) && destination['query'].nil? ? "##{fragment}" : ''}"
                 else
                   CGI.unescape(node[4].split(/[?#]/).first.split('/').last.to_s)
                 end
          next [node[0], node[1], text, destination, node[4]]
        end
        node
      end
      [result, used]
    end

    def dialect_kinds(row)
      entries_for(row, 'markdown_dialect').flat_map { |entry| Array(entry.dig('detail', 'kinds')) }.uniq
    end

    # The precise dialect transformations, on the source (underline,
    # superscript) or on the target (strikethrough, empty list item).
    def dialect(kinds, source_nodes, target_nodes)
      if kinds.include?('underline')
        source_nodes = source_nodes.map { |node| node[0] == 'u' ? ['em'] : (node[0] == '/u' ? ['/em'] : node) }
      end
      if kinds.include?('superscript')
        source_nodes = source_nodes.flat_map { |node| node[0] == 'sup' ? [['text', '^']] : (node[0] == '/sup' ? [] : [node]) }
      end
      if kinds.include?('strikethrough')
        target_nodes = target_nodes.map { |node| %w[del /del].include?(node[0]) ? ['text', '~'] : node }
      end
      if kinds.include?('quoted_destination')
        source_nodes = source_nodes.reject { |node| node[0] == 'img' && node[1] == ['broken'] }
        target_nodes = target_nodes.map do |node|
          node[0] == 'text' ? ['text', node[1].gsub(/!?\[[^\]]*\]\(\s*(["'])[^"']*\1\s*\)/, '')] : node
        end
      end
      if kinds.include?('empty_list_item')
        result = []
        index = 0
        while index < target_nodes.length
          if target_nodes[index, 4].map(&:first) == %w[ul li /li /ul]
            result << ['text', '-']
            index += 4
          else
            result << target_nodes[index]
            index += 1
          end
        end
        target_nodes = result
      end
      [source_nodes, target_nodes]
    end

    def links_and_images(nodes)
      nodes.select { |node| %w[link img].include?(node[0]) }
    end

    def words(nodes)
      nodes.flat_map { |node| node[0] == 'text' ? node[1].scan(/[[:alnum:]]+/) : (node[0] == 'link' ? node[2].to_s.scan(/[[:alnum:]]+/) : []) }
    end

    def compare_text(before, after)
      context = where(before)
      expected, used = transform(before, normalize(before['nodes'], source: true))
      actual = normalize(after['nodes'], source: false)
      kinds = dialect_kinds(before)
      blank = ->(nodes) { nodes.reject { |node| node[0] == 'text' && node[1].strip.empty? } }
      expected, actual = dialect(kinds & PRECISE, blank.call(expected), blank.call(actual))
      expected = comparable(expected)
      actual = comparable(actual)
      expected_links = links_and_images(expected)
      actual_links = links_and_images(actual)
      unless expected_links == actual_links
        index = (0...[expected_links.length, actual_links.length].max).find { |i| expected_links[i] != actual_links[i] }
        @failures << "#{context}: link or image #{index + 1} differs: #{describe(expected_links[index])} -> #{describe(actual_links[index])}"
        return
      end
      if expected == actual
        reasons = used + ((kinds & PRECISE).any? ? ['markdown_dialect'] : [])
        reasons.uniq.each { |reason| @explained["#{reason} [report.json]"] += 1 }
        return
      end
      if (kinds & REVIEW).any? && words(expected) == words(actual)
        @review << "#{context}: #{(kinds & REVIEW).join(', ')}"
        return
      end
      @unexplained << "#{context}: renders differently (#{first_difference(expected, actual)})"
    end

    def describe(node)
      node ? "#{node[0]} #{Array(node[1]).compact.join(' ')}#{node[2] ? " \"#{node[2]}\"" : ''}" : 'nothing'
    end

    def first_difference(expected, actual)
      index = (0...[expected.length, actual.length].max).find { |i| expected[i] != actual[i] }
      "node #{index + 1}: #{expected[index]&.first || 'nothing'} -> #{actual[index]&.first || 'nothing'}"
    end

    # --- attachments ------------------------------------------------------

    def expected_container(container)
      return container.first(3) unless container[0] == 'item'

      id = container[3]
      return ['document', *@absorbed[id]] if @absorbed.key?(id)

      ['item', container[1], @renamed.fetch("item:#{id}", container[2])]
    end

    def compare_attachments
      source = @source.select { |row| row['kind'] == 'attachment' }
      projects = source.map { |row| row['project'] }.compact.uniq
      target = @target.select { |row| row['kind'] == 'attachment' && projects.include?(row['project']) }
      unmatched = source.map { |row| [row, [expected_container(row['container']), row['filename'], row['sha256']]] }
      target.each do |row|
        key = [row['container'].first(3), row['filename'], row['sha256']]
        # The same file can also be in an attachment that is not migrated on
        # purpose: that one is taken last.
        index = unmatched.index { |candidate, expected| expected == key && !attachment_announced?(candidate) } ||
                unmatched.index { |_candidate, expected| expected == key }
        if index
          unmatched.delete_at(index)
        else
          @failures << "attachment ##{row['id']} (#{row['filename']}) of #{row['container'].first(3).compact.join(' ')}: " \
                       'no file of the source with this name and SHA-256 in this container'
        end
      end
      unmatched.each do |row, _expected|
        if attachment_announced?(row)
          @explained['attachment not migrated [report.json]'] += 1
        else
          @failures << "attachment ##{row['id']} (#{row['filename']}) is not in its container in the target and the report does not say why"
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
