# frozen_string_literal: true

require 'set'
require 'strscan'

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
  # The same code serves the converter (Rewriter), the importer (Resolver)
  # and the history comparison, so the three always agree. It only needs
  # Ruby's standard library.
  module TextLinks
    ITEM = 'snapshots-gen-item-'
    USER = 'snapshots-gen-user-'
    ATTACHMENT = 'snapshots-gen-attachment-'
    LITERAL = 'snapshots-gen-hash-'
    # Any placeholder left in a text means something was not resolved.
    LEFTOVER = /snapshots-gen-(?:item|user|attachment|hash)-\d+/.freeze
    LEFTOVER_LIKE = %w[%snapshots-gen-item-% %snapshots-gen-user-% %snapshots-gen-attachment-% %snapshots-gen-hash-%].freeze

    # The key pattern of cosmoSys's rewriter for a "#id" (see above).
    COSMOSYS_HASH = /(?<![A-Za-z0-9_-])#(\d+)(?![A-Za-z0-9_-])/.freeze

    # A reference as Redmine 4.2 parses it (ApplicationHelper LINKS_RE): after
    # a space, "(", ",", "-", "[", ">" or the start, an optional "!" escape,
    # an optional "project:" prefix, an optional object prefix, "#" or "##",
    # an id, an optional note suffix, and then the end of the word. Redmine
    # applies it to the HTML, so one or two Markdown marks that become tags
    # ("**", "_", "~", "^", "|") after such a start also count as a start.
    REFERENCE = /
      (?:(?<![^\s(,\-\[>])|(?<=\A[*_~^|])|(?<=[\s(,\-\[>][*_~^|])|(?<=\A[*_~^|]{2})|(?<=[\s(,\-\[>][*_~^|]{2}))
      (?<esc>!)?
      (?<project>[a-z0-9\-_]+:)?
      (?<prefix>attachment|document|version|forum|news|message|project|user)?
      (?<sep>\#\#?)
      (?<id>\d+)
      (?<suffix>(?:\#note)?-\d+)?
      (?=[[:punct:]](?:[^A-Za-z0-9_\/]|\z)|,|\s|\]|<|\z)
    /x.freeze

    # Absolute URLs, with balanced parentheses in the path (file names).
    URL = %r{(?<![\w.\-/])https?://[^/\s"'<>)\]]+(?:/(?:[^\s"'<>()\]]|\([^\s"'<>()\]]*\))*)?}i.freeze

    # One Markdown inline link or image: "[text](inner)" with one level of
    # parentheses inside.
    MARKDOWN_LINK = /(?<bang>!?)\[(?<label>[^\]\r\n]*)\]\((?<inner>(?:[^()\r\n]|\([^()\r\n]*\))*)\)/.freeze
    REFERENCE_DEFINITION = /^(?<lead>[ \t]{0,3}\[[^\]\r\n]+\]:[ \t]*)(?<dest><[^>\r\n]*>|\S+)/.freeze
    ANCHOR = %r{<a\b[^>]*>.*?</a\s*>}im.freeze
    AUTOLINK = %r{<(?<url>https?://[^>\s]+)>}i.freeze
    TAG = %r{</?[A-Za-z][^<>\n]*>}.freeze

    # Where code starts and ends. Indented code blocks are not recognized:
    # in a text they cannot be told from a nested list without parsing the
    # whole document.
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
            result << [ticks + rest[0, closing.end(0)], true]
            scanner.pos += closing.end(0)
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
      attr_reader :name, :protocol

      def initialize(name, protocol = 'https')
        @name = name.to_s.strip.sub(%r{\Ahttps?://}i, '').sub(%r{/+\z}, '')
        @protocol = protocol.to_s.strip.empty? ? 'https' : protocol.to_s.strip
      end

      def empty?
        @name.empty?
      end

      # The path of a URL of the old instance (starting with "/"), or nil.
      # Both schemes are taken: people paste either.
      def path(url)
        return nil if empty?

        match = url.match(%r{\Ahttps?://#{Regexp.escape(@name)}(?<path>/.*)?\z}i)
        match && (match[:path] || '/')
      end
    end

    # Rewrites a text of the old instance for the converter. The callables
    # say what the conversion knows:
    #   item.(id)       -> whether the item reaches the new instance
    #   user.(id)       -> whether the principal exists in the old instance
    #   attachment.(id) -> whether the attachment reaches the new instance
    #   protect.(id)    -> whether cosmoSys's rewriter would take "#id" in this
    #                      text (an item id of the same .csys); nil when the
    #                      text does not go through it
    # rewrite returns the new text and the events, one hash per change.
    class Rewriter
      def initialize(item:, user:, attachment:, host:, markdown: true, protect: nil)
        @item = item
        @user = user
        @attachment = attachment
        @host = host || Host.new('')
        @markdown = markdown
        @protect = protect
      end

      def rewrite(text)
        return [text, []] if text.nil?

        @events = []
        result = TextLinks.segments(text.to_s, markdown: @markdown).map do |part, code|
          code ? part : rewrite_plain(part)
        end.join
        result = protect_literals(result) if @protect
        [result, @events]
      end

      private

      def event(kind, **detail)
        @events << { 'kind' => kind }.merge(detail.transform_keys(&:to_s))
      end

      # Constructs whose inside is not a reference (link texts, tags and
      # URLs) are handled whole; references are looked for in the rest.
      def rewrite_plain(text)
        pattern = Regexp.union(ANCHOR, AUTOLINK, MARKDOWN_LINK, REFERENCE_DEFINITION, TAG, URL)
        output = +''
        position = 0
        after_construct = false
        text.to_enum(:scan, pattern).each do
          match = Regexp.last_match
          output << rewrite_references(text[position...match.begin(0)], position.zero? ? nil : output[-1], after_construct)
          output << rewrite_construct(match[0])
          position = match.end(0)
          after_construct = true
        end
        output << rewrite_references(text[position..].to_s, position.zero? ? nil : output[-1], after_construct)
        output
      end

      def rewrite_construct(token)
        if (match = token.match(/\A#{ANCHOR}\z/))
          token.sub(/\A<a\b[^>]*>/i) { |tag| rewrite_attributes(tag) }
        elsif (match = token.match(/\A#{AUTOLINK}\z/))
          replacement = bare_url(match[:url])
          replacement == match[:url] ? token : replacement
        elsif (match = token.match(/\A#{MARKDOWN_LINK}\z/))
          "#{match[:bang]}[#{match[:label]}](#{rewrite_inner(match[:inner])})"
        elsif (match = token.match(/\A#{REFERENCE_DEFINITION}\z/))
          match[:lead] + rewrite_destination(match[:dest])
        elsif token.match?(/\A#{TAG}\z/)
          rewrite_attributes(token)
        else
          bare_url(token)
        end
      end

      # The inside of "(...)" of a Markdown link: destination and title.
      def rewrite_inner(inner)
        match = inner.match(/\A(?<lead>\s*)(?<dest><[^>]*>|\S+)(?<rest>.*)\z/m)
        match ? "#{match[:lead]}#{rewrite_destination(match[:dest])}#{match[:rest]}" : inner
      end

      def rewrite_attributes(tag)
        tag.gsub(/(\b(?:href|src)\s*=\s*)(["']?)([^"'\s>]+)\2/i) do
          "#{Regexp.last_match(1)}#{Regexp.last_match(2)}#{rewrite_destination(Regexp.last_match(3), html: true)}#{Regexp.last_match(2)}"
        end
      end

      # A link destination: a URL of the old instance or a path of the
      # instance (the new one serves the same paths) naming an attachment or
      # an item becomes a path with a placeholder.
      def rewrite_destination(destination, html: false)
        bracketed = !html && destination.start_with?('<') && destination.end_with?('>')
        url = bracketed ? destination[1..-2] : destination
        path = url.start_with?('/') ? url : @host.path(url)
        return destination unless path

        rewritten = rewrite_path(path, absolute: !url.start_with?('/'), url: url)
        return destination unless rewritten

        bracketed ? "<#{rewritten}>" : rewritten
      end

      def rewrite_path(path, absolute:, url:)
        if (match = path.match(%r{\A/attachments/(?<kind>download/|thumbnail/)?(?<id>\d+)(?<rest>(?:[/?#].*)?)\z}))
          id = match[:id].to_i
          if @attachment.call(id)
            event('attachment', id: id, absolute: absolute)
            "/attachments/#{match[:kind]}#{ATTACHMENT}#{id}#{match[:rest]}"
          else
            event('attachment_broken', id: id, absolute: absolute)
            "/attachments/#{match[:kind]}0#{match[:rest]}"
          end
        elsif (match = path.match(%r{\A/issues/(?<id>\d+)(?<rest>(?:[/?#].*)?)\z}))
          id = match[:id].to_i
          if @item.call(id)
            event('issue_url', id: id, absolute: absolute, form: 'path')
            "/issues/#{ITEM}#{id}#{match[:rest]}"
          else
            # In the new instance that number is another item, or none.
            event('issue_url_broken', id: id, absolute: absolute)
            "/issues/0#{match[:rest]}"
          end
        else
          event('old_host_kept', url: url) if absolute
          nil
        end
      end

      # A URL in the text, outside any link: a link to an item of the old
      # instance becomes a reference to it ("#id"), one to an attachment a
      # Markdown link with its file name. Any other URL stays.
      def bare_url(url)
        trailing = url[/[.,;:!?]+\z/].to_s
        core = url[0, url.length - trailing.length]
        path = @host.path(core)
        return url unless path

        if (match = path.match(%r{\A/issues/(?<id>\d+)(?<note>#note-\d+)?\z}))
          id = match[:id].to_i
          unless @item.call(id)
            event('item_neutralized', id: id)
            return "!##{id}#{match[:note]}#{trailing}"
          end
          event('issue_url', id: id, absolute: true, form: 'reference')
          "##{ITEM}#{id}#{match[:note]}#{trailing}"
        elsif (match = path.match(%r{\A/attachments/(?:download/|thumbnail/)?(?<id>\d+)(?:/(?<name>[^/?#]+))?}))
          name = match[:name] || "attachment #{match[:id]}"
          destination = rewrite_path(path, absolute: true, url: core)
          "[#{name}](#{destination})#{trailing}"
        else
          event('old_host_kept', url: core)
          url
        end
      end

      # The start of a part counts as a start when nothing came before, or a
      # construct that Redmine renders as a tag (it ends in ">"), or a
      # character that REFERENCE accepts before a reference.
      def rewrite_references(text, previous, after_construct)
        return text if text.empty?

        lead = previous.nil? || after_construct || previous.match?(/[\s(,\-\[>]/) ? '' : 'x'
        rewritten = (lead + text).gsub(REFERENCE) { reference(Regexp.last_match) }
        rewritten[lead.length..]
      end

      def reference(match)
        token = match[0]
        id = match[:id].to_i
        return token if match[:esc]

        case match[:prefix]
        when nil
          if @item.call(id)
            event('item', id: id)
            "#{match[:project]}#{match[:sep][0..-2]}##{ITEM}#{id}#{match[:suffix]}"
          else
            event('item_neutralized', id: id)
            "!#{token}"
          end
        when 'user'
          return token unless match[:sep] == '#'

          if @user.call(id)
            event('user', id: id)
            "#{match[:project]}user##{USER}#{id}#{match[:suffix]}"
          else
            event('user_neutralized', id: id)
            "!#{token}"
          end
        else
          event('other_reference', prefix: match[:prefix], id: id)
          token
        end
      end

      def protect_literals(text)
        result, count = TextLinks.protect_literals(text, @protect)
        count.times { event('literal') }
        result
      end
    end

    # Replaces the placeholders with the ids of the new instance, in one
    # pass. The callables return the new id, or nil when it is unknown.
    class Resolver
      PATTERN = %r{
        (?<item>(?<item_lead>\#|/issues/)#{ITEM}(?<item_id>\d+))|
        (?<user>user\##{USER}(?<user_id>\d+))|
        (?<attachment>/attachments/(?<kind>download/|thumbnail/)?#{ATTACHMENT}(?<attachment_id>\d+))|
        (?<literal>\##{LITERAL}(?<literal_id>\d+))
      }x.freeze

      def initialize(item:, user:, attachment:)
        @item = item
        @user = user
        @attachment = attachment
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
              match[:item_lead] == '#' ? "!##{match[:item_id]}" : "/issues/0"
            end
          elsif match[:user]
            "user##{@user.call(match[:user_id].to_i) || 0}"
          elsif match[:attachment]
            "/attachments/#{match[:kind]}#{@attachment.call(match[:attachment_id].to_i) || 0}"
          else
            "##{match[:literal_id]}"
          end
        end
      end
    end
  end
end
