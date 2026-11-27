# frozen_string_literal: true

require 'set'
require 'strscan'
require 'uri'

module SnapshotsGen
  # Links inside the texts of a migration (descriptions, notes, text fields,
  # wiki versions, documents and the values of their history). Ids of items,
  # users and attachments change between the old and the new instance, so the
  # converter writes every link that names one as a placeholder, and the
  # history importer replaces each placeholder with the new id in a single
  # pass, once every record exists.
  #
  # The placeholders never match the pattern with which cosmoSys 0.2.10
  # rewrites "#id" while it imports a .csys
  # (MaterializationReferenceRewriter#rewrite_text). That rewriter applies its
  # replacements one after the other on the same text, so an id it has already
  # rewritten can be rewritten again as another one; with placeholders it
  # finds nothing to rewrite. A "#123" that is not a reference (code, an
  # anchor, an escaped "!#123") but that the rewriter would still take is
  # protected the same way, and restored as it was.
  #
  # What is a link is decided as Redmine 4.2 decided it: the Rewriter renders
  # the text with the formatter of the old instance (SnapshotsGen::Redmine42)
  # and, for each candidate, renders it again with its digits replaced by a
  # sentinel, to see what the old instance made of that very candidate. A
  # candidate whose digits change the rendering of the text (the key of a
  # Markdown reference link, for instance) cannot be decided that way: it is
  # left as it was and reported.
  #
  # The same code serves the converter (Rewriter), the importer (Resolver)
  # and the history comparison. The Resolver only needs Ruby's standard
  # library; the Rewriter loads Redcarpet, which the converter image has.
  module TextLinks
    ITEM = 'snapshots-gen-item-'
    USER = 'snapshots-gen-user-'
    ATTACHMENT = 'snapshots-gen-attachment-'
    LITERAL = 'snapshots-gen-hash-'
    # Any placeholder left in a text means something was not resolved.
    LEFTOVER = /snapshots-gen-(?:item|user|attachment|hash)-\d+/.freeze
    LEFTOVER_LIKE = %w[%snapshots-gen-item-% %snapshots-gen-user-% %snapshots-gen-attachment-% %snapshots-gen-hash-%].freeze
    # A text of the source that already holds something that looks like a
    # placeholder is escaped (snapshots-gen- becomes snapshots-gen-esc-) and
    # restored by the Resolver.

    # The key pattern of cosmoSys's rewriter for a "#id" (see above).
    COSMOSYS_HASH = /(?<![A-Za-z0-9_-])#(\d+)(?![A-Za-z0-9_-])/.freeze

    # Absolute URLs, with balanced parentheses in the path (file names).
    URL = %r{(?<![\w.\-/])https?://[^/\s"'<>)\]]+(?:/(?:[^\s"'<>()\]]|\([^\s"'<>()\]]*\))*)?}i.freeze

    # One Markdown inline link or image: "[text](inner)" with one level of
    # parentheses inside.
    MARKDOWN_LINK = /(?<bang>!?)\[(?<label>[^\]\r\n]*)\]\((?<inner>(?:[^()\r\n]|\([^()\r\n]*\))*)\)/.freeze

    # A link to an attachment or an item of an instance, relative or with a
    # host (with or without a scheme), with what follows the id.
    INSTANCE_URL = %r{
      (?:(?<![\w.\-/:])(?:(?<scheme>https?):)?//(?<host>[^/?\#\s<>"'\[\]()]+)(?<prefix>(?:/[^/?\#\s<>"'\[\]()]+)*?)|(?<![\w.\-/:]))
      (?<path>/(?<kind>attachments/(?<operation>download/|thumbnail/)?|issues/)(?<id>\d+))
      (?<rest>(?:[/?\#](?:[^\s<>"'\[\]()]|\([^\s<>"'()\[\]]*\))*)?)
    }x.freeze
    LOOKALIKE = 'snapshots-gen-'
    ESCAPED = 'snapshots-gen-esc-'

    # The angle rule: a destination that CommonMark would not accept because
    # it has spaces (Redcarpet, the "markdown" formatter of Redmine 4.2, did)
    # is put between "<" and ">". Only a destination without a scheme, quotes,
    # "<", ">", "[", "]", "!" or a line break, with balanced parentheses.
    ANGLE_DESTINATION = /\A[^()<>"'\r\n\[\]!]*(?:\([^()<>"'\r\n]*\)[^()<>"'\r\n\[\]!]*)*\z/.freeze

    # Where code starts and ends, for the checks of TextChecks (the Rewriter
    # asks the formatter instead). Indented code blocks are not recognized.
    FENCE = /\A(?<indent>[ \t]*)(?<fence>`{3,}|~{3,})/.freeze

    module_function

    # Splits a text into [part, code?] pairs: fenced code blocks, <pre> and
    # <code> elements and inline code spans are code. Joined again, the parts
    # are the text.
    def segments(text, markdown: true)
      text = text.to_s
      return [[text, false]] unless markdown

      result = []
      plain = +''
      lines = text.split(/(?<=\n)/)
      index = 0
      while index < lines.length
        line = lines[index]
        opening = line.match(FENCE)
        if opening && !(opening[:fence].start_with?('`') && line[opening.end(0)..].to_s.include?('`'))
          char = opening[:fence][0]
          size = opening[:fence].length
          block = +line
          index += 1
          while index < lines.length
            block << lines[index]
            closing = lines[index].match(/\A[ \t]*(#{Regexp.escape(char)}{#{size},})[ \t]*\r?\n?\z/)
            index += 1
            break if closing
          end
          result.concat(inline_segments(plain)) unless plain.empty?
          plain = +''
          result << [block, true]
        else
          plain << line
          index += 1
        end
      end
      result.concat(inline_segments(plain)) unless plain.empty?
      result
    end

    def inline_segments(text)
      result = []
      scanner = StringScanner.new(text)
      plain = +''
      until scanner.eos?
        if (element = scanner.scan(%r{<(pre|code)\b[^>]*>.*?</\1\s*>}im))
          result << [plain, false] unless plain.empty?
          plain = +''
          result << [element, true]
        elsif (ticks = scanner.scan(/`+/))
          rest = scanner.rest
          paragraph = rest.split(/\n[ \t]*\n/, 2).first.to_s
          closing = paragraph.match(/(?<!`)#{ticks}(?!`)/)
          if closing
            result << [plain, false] unless plain.empty?
            plain = +''
            span = rest[0, closing.end(0)]
            result << [ticks + span, true]
            # StringScanner#pos counts bytes; MatchData#end counts characters.
            scanner.pos += span.bytesize
          else
            plain << ticks
          end
        else
          plain << scanner.getch
        end
      end
      result << [plain, false] unless plain.empty?
      result
    end

    # Every "#id" that cosmoSys's rewriter would take and protect.(id)
    # accepts becomes a literal placeholder. Returns [text, count].
    def protect_literals(text, protect)
      count = 0
      result = text.to_s.gsub(COSMOSYS_HASH) do
        id = Regexp.last_match(1).to_i
        next Regexp.last_match(0) unless protect.call(id)

        count += 1
        "##{LITERAL}#{id}"
      end
      [result, count]
    end

    # The old instance's host, as Redmine's settings give it ("host_name",
    # which may carry a port and a path prefix, and "protocol"). Links to it
    # are links into the old instance.
    class Host
      DEFAULT_PORTS = [80, 443].freeze
      attr_reader :name, :protocol

      def initialize(name, protocol = 'https')
        @name = name.to_s.strip.sub(%r{\Ahttps?://}i, '').sub(%r{/+\z}, '')
        @protocol = protocol.to_s.strip.empty? ? 'https' : protocol.to_s.strip
        authority, prefix = @name.split('/', 2)
        @host, port = authority.to_s.downcase.split(':', 2)
        @port = port && port.to_i
        @prefix = prefix.to_s.empty? ? '' : "/#{prefix}"
      end

      def empty?
        @name.empty?
      end

      # Whether an authority ("host" or "host:port", from a URL with scheme
      # or scheme-relative) is the old instance. A default port written out
      # is the same server.
      def authority?(authority)
        return false if empty? || authority.nil?

        host, port = authority.downcase.split(':', 2)
        return false unless host == @host

        port = port && port.to_i
        @port ? port == @port : (port.nil? || DEFAULT_PORTS.include?(port))
      end

      # The path of a URL of the old instance (starting with "/"), or nil.
      # Both schemes are taken, and scheme-relative URLs: people paste either.
      def path(url)
        match = url.to_s.match(%r{\A(?:https?:)?//(?<authority>[^/?#\s]+)(?<path>[/?#].*)?\z}i)
        return nil unless match && authority?(match[:authority])

        path = match[:path] || '/'
        return path if @prefix.empty?

        path.start_with?("#{@prefix}/") ? path.delete_prefix(@prefix) : nil
      end
    end

    # Rewrites a text of the old instance for the converter. The callables
    # say what the conversion knows:
    #   item.(id)       -> whether the item reaches the new instance
    #   user.(id)       -> whether the old instance linked user#id (a user of
    #                      type User; groups, the anonymous user and missing
    #                      ids showed as text)
    #   attachment.(id) -> whether the attachment reaches the new instance
    #   protect.(id)    -> whether cosmoSys's rewriter would take "#id" in this
    #                      text (an item id of the same .csys); nil when the
    #                      text does not go through it
    # markdown: the text was formatted with "markdown" (false: no formatting);
    # angle: apply the angle rule (Redcarpet sources only).
    # rewrite returns the new text and the events, one hash per change.
    class Rewriter
      def initialize(item:, user:, attachment:, host:, markdown: true, angle: markdown, protect: nil)
        require_relative 'redmine42'
        @item = item
        @user = user
        @attachment = attachment
        @host = host || Host.new('')
        @formatting = markdown ? 'markdown' : 'plain'
        @angle = angle && markdown
        @protect = protect
      end

      def rewrite(text)
        return [text, []] if text.nil?

        @events = []
        @text = text.to_s
        @base = Redmine42.to_html(@text, @formatting)
        @sentinel = sentinel
        edits = url_edits
        edits = angle_edits(edits) if @angle
        reference_edits(edits)
        lookalike_edits(edits)
        result = apply(@text, edits)
        report_other_old_host_links
        result = protect_literals(result) if @protect
        [result, @events]
      end

      private

      def event(kind, **detail)
        @events << { 'kind' => kind }.merge(detail.transform_keys(&:to_s))
      end

      # Digits that appear nowhere in the text or its rendering.
      def sentinel
        candidate = 7_770_000_001
        candidate += 1 while @text.include?(candidate.to_s) || @base.include?(candidate.to_s)
        candidate.to_s
      end

      # The rendering of the text with the characters from start to finish
      # replaced by the sentinel, or nil when that changes anything else of
      # the rendering than those characters.
      def probe(text, start, finish, base = @base)
        original = text[start...finish]
        html = Redmine42.to_html(text[0...start] + @sentinel + text[finish..].to_s, @formatting)
        html.gsub(@sentinel, original) == base ? html : nil
      end

      # Edits are [start, finish, replacement] over the original text.
      def overlaps?(edits, start, finish)
        edits.any? { |from, to, _replacement| start < to && finish > from }
      end

      def apply(text, edits)
        result = text.dup
        edits.sort_by { |from, _to, _replacement| -from }.each do |from, to, replacement|
          result[from...to] = replacement
        end
        result
      end

      # --- links to attachments and items, and URLs of the old instance ---

      def url_edits
        edits = []
        @text.to_enum(:scan, INSTANCE_URL).each do
          match = Regexp.last_match
          absolute = !match[:host].nil?
          # The host, and the path prefix of host_name if it has one.
          next if absolute && @host.path("//#{match[:host]}#{match[:prefix]}/") != '/'

          start = match.begin(0)
          id_start = match.begin(:id)
          id_finish = match.end(:id)
          html = probe(@text, id_start, id_finish)
          next unless html

          use = Redmine42.destinations(html).find { |entry| entry['url'].include?(@sentinel) }
          next unless use # not a link in the old instance (code, plain text...)

          finish = match.end(0)
          bare = use['tag'] == 'a' && use['text'].include?(@sentinel)
          if bare
            # The autolink ends where Redmine ended it (trailing punctuation).
            shown = use['text'].sub(@sentinel, match[:id])
            index = @text.index(shown, start)
            finish = start + shown.length if index == start
          end
          kind = match[:kind].start_with?('issues') ? 'item' : 'attachment'
          id = match[:id].to_i
          rest = @text[match.end(:id)...finish]
          operation = match[:operation].to_s
          replacement = bare ? bare_replacement(kind, id, operation, rest) : path_replacement(kind, id, operation, rest, absolute)
          edits << [start, finish, replacement] if replacement
        end
        edits
      end

      def path_replacement(kind, id, operation, rest, absolute)
        if kind == 'attachment'
          if @attachment.call(id)
            event('attachment', id: id, absolute: absolute, form: 'path')
            "/attachments/#{operation}#{ATTACHMENT}#{id}#{rest}"
          else
            event('attachment_broken', id: id, absolute: absolute)
            "/attachments/#{operation}0#{rest}"
          end
        elsif @item.call(id)
          event('issue_url', id: id, absolute: absolute, form: 'path')
          "/issues/#{ITEM}#{id}#{rest}"
        else
          event('issue_url_broken', id: id, absolute: absolute)
          "/issues/0#{rest}"
        end
      end

      # A URL in the text, outside any link. In Markdown it becomes a
      # reference ("#id", with its note) or, when that cannot hold it, a link
      # with a relative path; without formatting only a plain item URL can
      # become a reference, anything else stays and is reported.
      def bare_replacement(kind, id, operation, rest)
        if kind == 'item'
          note = rest.match(/\A#(note-\d+)\z/)
          unless @item.call(id)
            event('item_neutralized', id: id)
            return "!##{id}#{note ? "##{note[1]}" : ''}"
          end
          if rest.empty? || note
            event('issue_url', id: id, absolute: true, form: 'reference')
            return "##{ITEM}#{id}#{note ? "##{note[1]}" : ''}"
          end
          return nil.tap { event('old_host_kept', url: "/issues/#{id}#{rest}") } unless @formatting == 'markdown'

          event('issue_url', id: id, absolute: true, form: 'link')
          "[##{ITEM}#{id}](/issues/#{ITEM}#{id}#{rest})"
        else
          return nil.tap { event('old_host_kept', url: "/attachments/#{operation}#{id}#{rest}") } unless @formatting == 'markdown'

          name = rest[%r{\A/([^/?#]+)}, 1]
          label = name ? URI.decode_www_form_component(name) : "attachment #{id}"
          if @attachment.call(id)
            event('attachment', id: id, absolute: true, form: 'link')
            "[#{label}](/attachments/#{operation}#{ATTACHMENT}#{id}#{rest})"
          else
            event('attachment_broken', id: id, absolute: true)
            "[#{label}](/attachments/#{operation}0#{rest})"
          end
        end
      rescue ArgumentError
        nil
      end

      # Links of the old instance to anything else (projects, wiki...) stay.
      def report_other_old_host_links
        Redmine42.destinations(@base).each do |use|
          path = @host.path(use['url'])
          next unless path && !path.match?(%r{\A/(?:attachments/(?:download/|thumbnail/)?\d|issues/\d)})

          event('old_host_kept', url: use['url'])
        end
      end

      # --- destinations with spaces (Redcarpet only) ---------------------

      # A destination that Redcarpet took with its spaces (it is the src or
      # href of the rendering) and that CommonMark would not take: written
      # between "<" and ">", with the links inside it already rewritten.
      def angle_edits(edits)
        @text.to_enum(:scan, MARKDOWN_LINK).each do
          match = Regexp.last_match
          start = match.begin(:inner)
          finish = match.end(:inner)
          inner = match[:inner]
          # Redcarpet took this very destination: digits put in front of it
          # show in a src or href of the rendering, and nothing else changes.
          probed = Redmine42.to_html(@text.dup.insert(start + inner[/\A\s*/].length, @sentinel), @formatting)
          next unless probed.gsub(@sentinel, '') == @base &&
                      Redmine42.destinations(probed).any? { |use| use['url'].start_with?(@sentinel) }

          inside = edits.select { |from, to, _replacement| from >= start && to <= finish }
          next if edits.any? { |from, to, _replacement| from < finish && to > start && !inside.include?([from, to, _replacement]) }

          rewritten = apply(inner, inside.map { |from, to, replacement| [from - start, to - start, replacement] })
          next unless rewritten.match?(ANGLE_DESTINATION)

          destination = rewritten.strip
          next unless destination.include?(' ') && !destination.match?(/\A[a-z][a-z0-9+.-]*:/i)

          edits -= inside
          edits << [start, finish, "<#{destination}>"]
          event('angle', destination: destination)
        end
        edits
      end

      # --- references (#id, ##id, user#id) --------------------------------

      def reference_edits(edits)
        @text.to_enum(:scan, /#(\d+)/).map { Regexp.last_match }.each do |match|
          start = match.begin(1)
          finish = match.end(1)
          digits = match[1]
          next if overlaps?(edits, start, finish)
          # Redmine links an item only by its canonical id ("#012" is text).
          next if digits.length > 1 && digits.start_with?('0')

          html = probe(@text, start, finish)
          unless html
            event('undecided', id: digits.to_i)
            next
          end
          reference = Redmine42.references(html).find { |found| found['identifier'] == @sentinel }
          next unless reference && reference['sep'].start_with?('#')
          next if reference['esc']

          edit = reference_edit(start, finish, digits.to_i, reference)
          edits << edit if edit
        end
      end

      def reference_edit(start, finish, id, reference)
        case reference['prefix']
        when nil
          return [start, finish, "#{ITEM}#{id}"].tap { event('item', id: id) } if @item.call(id)

          escape(start, finish, id, reference, 'item_neutralized')
        when 'user'
          return [start, finish, "#{USER}#{id}"].tap { event('user', id: id) } if @user.call(id)

          escape(start, finish, id, reference, 'user_neutralized')
        else
          event('other_reference', prefix: reference['prefix'], id: id)
          nil
        end
      end

      # A reference that must not link in the new instance is escaped with
      # "!" before it, as Redmine escapes; checked by rendering it again.
      def escape(start, finish, id, reference, kind)
        position = start
        reference['sep'].length.times do
          position -= 1 while position.positive? && @text[position - 1] == '\\'
          position -= 1 if position.positive? && @text[position - 1] == '#'
        end
        position -= 1 while position.positive? && @text[position - 1] == '\\'
        [reference['prefix'], reference['project_prefix']].compact.each do |part|
          position -= part.length if @text[position - part.length, part.length] == part
        end
        escaped = @text.dup.insert(position, '!')
        html = Redmine42.to_html(escaped[0...(start + 1)] + @sentinel + escaped[(finish + 1)..].to_s, @formatting)
        if Redmine42.references(html).none? { |found| found['identifier'] == @sentinel && !found['esc'] }
          event(kind, id: id)
          [position, position, '!']
        else
          event('undecided', id: id)
          nil
        end
      end

      # --- texts that already hold something like a placeholder ------------

      def lookalike_edits(edits)
        @text.to_enum(:scan, /#{LOOKALIKE}/o).each do
          start = Regexp.last_match.begin(0)
          finish = start + LOOKALIKE.length
          next if overlaps?(edits, start, finish)

          edits << [start, finish, ESCAPED]
          event('lookalike')
        end
      end

      def protect_literals(text)
        result, count = TextLinks.protect_literals(text, @protect)
        count.times { event('literal') }
        result
      end
    end

    # Replaces the placeholders with the ids of the new instance, in one
    # pass, and restores what the source already held that looked like one.
    # The callables return the new id, or nil when it is unknown.
    class Resolver
      PATTERN = %r{
        (?<item>(?<item_lead>\#|/issues/)#{ITEM}(?<item_id>\d+))|
        (?<user>user(?<user_sep>\#\#?)#{USER}(?<user_id>\d+))|
        (?<attachment>/attachments/(?<kind>download/|thumbnail/)?#{ATTACHMENT}(?<attachment_id>\d+))|
        (?<literal>\##{LITERAL}(?<literal_id>\d+))|
        (?<escaped>#{ESCAPED})
      }x.freeze

      # How many escaped lookalikes it has restored.
      attr_reader :restored

      def initialize(item:, user:, attachment:)
        @item = item
        @user = user
        @attachment = attachment
        @restored = 0
      end

      def resolve(text)
        return text if text.nil?

        text.to_s.gsub(PATTERN) do
          match = Regexp.last_match
          if match[:item]
            id = @item.call(match[:item_id].to_i)
            if id
              "#{match[:item_lead]}#{id}"
            else
              match[:item_lead] == '#' ? "!##{match[:item_id]}" : '/issues/0'
            end
          elsif match[:user]
            "user#{match[:user_sep]}#{@user.call(match[:user_id].to_i) || 0}"
          elsif match[:attachment]
            "/attachments/#{match[:kind]}#{@attachment.call(match[:attachment_id].to_i) || 0}"
          elsif match[:literal]
            "##{match[:literal_id]}"
          else
            @restored += 1
            LOOKALIKE
          end
        end
      end
    end
  end
end
