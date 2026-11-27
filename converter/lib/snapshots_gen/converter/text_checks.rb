# frozen_string_literal: true

require_relative '../text_links'

module SnapshotsGen
  module Converter
    # What a text will show differently in the new instance without anything
    # being lost, so the report can list it for a person to review: Markdown
    # that Redcarpet (the "markdown" formatter of Redmine 4.2) and CommonMark
    # (Redmine 7) render differently, and formulas of a MathJax plugin, which
    # the new instance does not render by itself. Code is never looked at.
    module TextChecks
      module_function

      # Redcarpet with Redmine 4.2's options (underline, superscript,
      # strikethrough, lax_spacing) against CommonMark:
      #   underline       _text_ was underlined; now it is italics
      #   underscores     a run of underscores against a word (blanks to
      #                   fill in, "____mm") was taken as emphasis; now it
      #                   shows as written
      #   strikethrough   ~text~ was shown with its tildes; now it is struck
      #   superscript     x^2 was a superscript; now the caret shows
      #   list_indent     a list indented four columns past the text of a
      #                   numbered item was nested; now it is part of the text
      #   list_marker     a list whose items change from * to - or + (or to
      #                   numbers) was one list; now it is two
      #   quoted_destination  ![]("name") was an image (broken: no file has
      #                   that name with its quotes); now it is text
      #   empty_list_item a line with only "-", "*" or "+" was text; now it is
      #                   an empty list item
      DIALECT = {
        'underline' => /(?<![\w_\\])_(?![_\s])[^_\n]*?[^_\s\\]_(?![\w_])|(?<![\w_\\])_[^_\s\\]_(?![\w_])/,
        'underscores' => /(?<!\w)_{2,}(?=[^\W_])|(?<=[^\W_])_{2,}(?!\w)/,
        'strikethrough' => /(?<![~\\])~(?![~\s])[^~\n]*?(?<![~\s\\])~(?!~)/,
        'superscript' => /(?<=[^\s^\\])\^(?=[^\s^])/,
        'quoted_destination' => /!?\[[^\]\n]*\]\(\s*["'][^)\n]*\)/,
        'empty_list_item' => /^ {0,3}[-*+][ \t]*$/
      }.freeze

      def dialect_differences(text)
        plain = plain_text(text)
        # Underscores, tildes and carets of a URL are not Markdown.
        prose = plain.gsub(/\]\([^)\n]*\)/, '] ').gsub(TextLinks::URL, ' ')
        kinds = DIALECT.select { |kind, pattern| (kind == 'quoted_destination' ? plain : prose).match?(pattern) }.keys
        kinds << 'list_indent' if list_indent?(plain)
        kinds << 'list_marker' if list_marker_change?(plain)
        kinds
      end

      # Formulas a MathJax plugin rendered anywhere in a page: $...$ and
      # \(...\) inline, $$...$$ and \[...\] as blocks, and its macro {{mj(...)}}.
      LATEX = /\$\$(?<block>.+?)\$\$|\\\[(?<bracket>.+?)\\\]|\\\((?<paren>.+?)\\\)|(?<![\\$])\$(?!\$)(?<inline>[^$\n]*?[^$\s\\])\$(?!\$)/m.freeze
      MACRO = /\{\{\s*mj\b/.freeze

      def latex_formulas(text)
        plain = plain_text(text)
        counts = Hash.new(0)
        plain.scan(LATEX) do
          match = Regexp.last_match
          counts[match[:block] || match[:bracket] ? 'block' : 'inline'] += 1
        end
        counts['macro'] = plain.scan(MACRO).length if plain.match?(MACRO)
        counts
      end

      def plain_text(text)
        TextLinks.segments(text.to_s.gsub("\r\n", "\n")).reject { |_part, code| code }.map(&:first).join
      end

      def list_indent?(text)
        content_column = nil
        text.split("\n").any? do |line|
          if (match = line.match(/\A( *)\d+[.)]( +)\S/))
            content_column = match[1].length + line[/\A *\d+[.)]/].strip.length + match[2].length
            next false
          end
          if line.strip.empty? || line.match?(/\A\S/)
            content_column = nil if line.match?(/\A\S/)
            next false
          end
          indent = line[/\A */].length
          content_column && line.match?(/\A *[-*+] +\S/) && indent >= content_column + 4
        end
      end

      # Redcarpet (with lax_spacing) kept items separated by blank lines in
      # one list; a new paragraph after a blank line ends it.
      def list_marker_change?(text)
        previous = nil
        blank = false
        text.split("\n").any? do |line|
          # A thematic break ("* * *", "---") ends a list.
          if line.match?(/\A {0,3}([-*_])( *\1){2,} *\z/)
            previous = nil
            next false
          end
          match = line.match(/\A( *)([-*+]|\d+[.)]) +\S/)
          marker = match && (match[2].match?(/\d/) ? 'ordered' : match[2])
          changed = match && previous && previous[0] == match[1].length && previous[1] != marker
          if match
            previous = [match[1].length, marker]
          elsif !line.strip.empty? && blank && line.match?(/\A\S/)
            previous = nil
          end
          blank = line.strip.empty?
          changed
        end
      end
    end
  end
end
