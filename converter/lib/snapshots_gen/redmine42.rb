# frozen_string_literal: true

# Parts of this file are adapted from Redmine 4.2.10:
#   lib/redmine/wiki_formatting/markdown/formatter.rb (the Markdown renderer
#     and the options of its Redcarpet formatter),
#   app/helpers/application_helper.rb (LINKS_RE, MACROS_RE, catch_macros and
#     parse_non_pre_blocks),
#   lib/redmine/wiki_formatting.rb (AUTO_LINK_RE, auto_link!,
#     restore_redmine_links and the NullFormatter).
# Adapted by cosmoBots.eu on 2026-11-27, to find links in a text as that
# version of Redmine did, outside Rails. The notice of those files follows:
#
#   Redmine - project management software
#   Copyright (C) 2006-2023  Jean-Philippe Lang
#
#   This program is free software; you can redistribute it and/or
#   modify it under the terms of the GNU General Public License
#   as published by the Free Software Foundation; either version 2
#   of the License, or (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program; if not, write to the Free Software
#   Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# The adapted parts and the rest of this file are distributed, as part of
# snapshots_gen, under the GNU General Public License, version 3 only
# (GPL-3.0-only), as permitted by Redmine's "or later" clause: see LICENSE.
# Copyright (C) 2026 cosmoBots.eu.

require 'cgi'
require 'strscan'
require 'uri'

module SnapshotsGen
  # How Redmine 4.2 (the old instance) turns a text into HTML and finds its
  # links: the "markdown" formatter (Redcarpet 3.5.1 with the renderer and
  # options of lib/redmine/wiki_formatting/markdown/formatter.rb), the plain
  # formatter (no formatting), macros set apart first (catch_macros), and
  # parse_redmine_links applied to the HTML outside <pre> and <code>
  # (parse_non_pre_blocks) with its LINKS_RE. Adapted from Redmine 4.2.10
  # (GPL-2.0-or-later), Copyright (C) 2006-2023 Jean-Philippe Lang: see the
  # notice at the top of this file.
  #
  # Only the converter and the history comparison use it: they run in the
  # converter image, which has Redcarpet. The importer does not load it.
  module Redmine42
    begin
      verbose = $VERBOSE
      $VERBOSE = nil # Redcarpet 3.5 warns about its allocator on Ruby 3.
      require 'redcarpet'
    ensure
      $VERBOSE = verbose
    end

    # app/helpers/application_helper.rb, Redmine 4.2.
    LINKS_RE =
      %r{
              <a( [^>]+?)?>(?<tag_content>.*?)</a>|
              (?<leading>[\s\(,\-\[\>]|^)
              (?<esc>!)?
              (?<project_prefix>(?<project_identifier>[a-z0-9\-_]+):)?
              (?<prefix>attachment|document|version|forum|news|message|project|commit|source|export|user)?
              (
                (
                  (?<sep1>\#\#?)|
                  (
                    (?<repo_prefix>(?<repo_identifier>[a-z0-9\-_]+)\|)?
                    (?<sep2>r)
                  )
                )
                (
                  (?<identifier1>((\d)+|(note)))
                  (?<comment_suffix>
                    (\#note)?
                    -(?<comment_id>\d+)
                  )?
                )|
                (
                (?<sep3>:)
                (?<identifier2>[^"\s<>][^\s<>]*?|"[^"]+?")
                )|
                (
                (?<sep4>@)
                (?<identifier3>[A-Za-z0-9_\-@\.]*?)
                )
              )
              (?=
                (?=[[:punct:]][^A-Za-z0-9_/])|
                ,|
                \s|
                \]|
                <|
                $)
      }x.freeze

    MACROS_RE = /(
                  (!)?                        # escaping
                  (
                  \{\{                        # opening tag
                  ([\w]+)                     # macro name
                  (\(([^\n\r]*?)\))?          # optional arguments
                  ([\n\r].*?[\n\r])?          # optional block of text
                  \}\}                        # closing tag
                  )
                 )/mx.freeze

    # lib/redmine/wiki_formatting.rb, Redmine 4.2.
    AUTO_LINK_RE = %r{
                    (                          # leading text
                      <\w+[^>]*?>|             # leading HTML tag, or
                      [\s\(\[,;]|              # leading punctuation, or
                      ^                        # beginning of line
                    )
                    (
                      (?:https?://)|           # protocol spec, or
                      (?:s?ftps?://)|
                      (?:www\.)                # www.*
                    )
                    (
                      ([^<]\S*?)               # url
                      (\/)?                    # slash
                    )
                    ((?:&gt;)?|[^[:alnum:]_\=\/;\(\)\-]*?)             # post
                    (?=<|\s|$)
                   }x.freeze

    module_function

    def safe_uri?(uri)
      return true unless uri.to_s.include?(':')

      ['http', 'https', 'ftp', 'mailto', nil].include?(URI.parse(uri).scheme)
    rescue URI::Error
      false
    end

    def escape(value)
      CGI.escapeHTML(value.to_s)
    end

    # Redmine::WikiFormatting::Markdown::HTML. Code blocks are written as
    # <pre>, as Redmine does for a language it does not highlight.
    class Renderer < Redcarpet::Render::HTML
      def link(link, title, content)
        return nil unless Redmine42.safe_uri?(link)

        css = link.to_s.start_with?('/') ? '' : ' class="external"'
        title = title ? %( title="#{Redmine42.escape(title)}") : ''
        %(<a href="#{Redmine42.escape(link)}"#{title}#{css}>#{content}</a>)
      end

      def block_code(code, _language)
        "<pre>#{CGI.escapeHTML(code)}</pre>"
      end

      def image(link, title, alt_text)
        return nil unless Redmine42.safe_uri?(link)

        title = title ? %( title="#{Redmine42.escape(title)}") : ''
        %(<img src="#{Redmine42.escape(link)}" alt="#{Redmine42.escape(alt_text)}"#{title} />)
      end
    end

    def markdown
      return @markdown if @markdown

      verbose = $VERBOSE
      $VERBOSE = nil # Redcarpet 3.5 warns about its allocator on Ruby 3.
      @markdown = Redcarpet::Markdown.new(
        Renderer.new(filter_html: true, hard_wrap: true),
        autolink: true, fenced_code_blocks: true, space_after_headers: true, tables: true, strikethrough: true,
        superscript: true, no_intra_emphasis: true, footnotes: true, lax_spacing: true, underline: true
      )
    ensure
      $VERBOSE = verbose
    end

    # The HTML Redmine 4.2 makes of a text, before its links are parsed.
    # formatting: "markdown" or anything else (no formatting).
    def to_html(text, formatting)
      text = text.to_s.dup
      macros = 0
      text = text.gsub(MACROS_RE) { "{{macro(#{macros += 1})}}" }
      html = formatting == 'plain' ? plain(text) : markdown.render(text)
      restore_redmine_links(html)
    end

    # Redmine::WikiFormatting::NullFormatter.
    def plain(text)
      escaped = CGI.escapeHTML(text)
      linked = escaped.gsub(AUTO_LINK_RE) do
        all, leading, proto, url, post = Regexp.last_match(0), Regexp.last_match(1), Regexp.last_match(2), Regexp.last_match(3), Regexp.last_match(6)
        next all if /<a\s/i.match?(leading) || /![<>=]?/.match?(leading)

        if url[-1] == ')' && (url.count('(') - url.count(')')).negative?
          url = url[0..-2]
          post = ")#{post}"
        end
        href = "#{proto == 'www.' ? 'http://www.' : proto}#{url}"
        %(#{leading}<a class="external" href="#{escape(CGI.unescapeHTML(href))}">#{escape(CGI.unescapeHTML(proto + url))}</a>#{post})
      end
      paragraphs = linked.gsub("\r\n", "\n").split(/\n\n+/)
      paragraphs.map { |paragraph| "<p>#{paragraph.gsub("\n", "<br />\n")}</p>" }.join("\n\n")
    end

    def restore_redmine_links(html)
      html = html.gsub(%r{\[<a href="(.*?)">(.*?)</a>\]}) { "[[#{Regexp.last_match(2)}]]" }
      html.gsub(/(\w):&quot;(.+?)&quot;/) { "#{Regexp.last_match(1)}:\"#{Regexp.last_match(2)}\"" }
    end

    # The parts of the HTML where Redmine parses links: outside <pre> and
    # <code> (ApplicationHelper#parse_non_pre_blocks).
    def outside_code(html)
      scanner = StringScanner.new(html.to_s)
      tags = []
      parts = []
      until scanner.eos?
        scanner.scan(%r{(.*?)(<(/)?(pre|code)(.*?)>|\z)}im)
        text, closing, tag = scanner[1], scanner[3], scanner[4]
        parts << text if tags.empty?
        next unless tag

        if closing
          tags.pop if tags.last && tags.last.casecmp(tag).zero?
        else
          tags << tag.downcase
        end
      end
      parts
    end

    # The references parse_redmine_links finds in an HTML: one hash per
    # match, with the parts that say what it links to.
    def references(html)
      outside_code(html).flat_map do |part|
        part.to_enum(:scan, LINKS_RE).filter_map do
          match = Regexp.last_match
          next if match[:tag_content]

          { 'esc' => match[:esc], 'project_prefix' => match[:project_prefix], 'prefix' => match[:prefix],
            'sep' => match[:sep1] || match[:sep2] || match[:sep3] || match[:sep4],
            'identifier' => match[:identifier1] || match[:identifier2] || match[:identifier3],
            'comment_suffix' => match[:comment_suffix] }
        end
      end
    end

    # The href and src values of the HTML outside <pre> and <code>, with
    # the text of each link (to tell an autolink from a written link).
    def destinations(html)
      outside_code(html).flat_map do |part|
        links = part.scan(%r{<a\b([^>]*)>(.*?)</a>}m).filter_map do |attributes, content|
          href = attributes[/\bhref="([^"]*)"/, 1]
          href && { 'tag' => 'a', 'url' => CGI.unescapeHTML(href), 'text' => CGI.unescapeHTML(content.gsub(/<[^>]+>/, '')) }
        end
        images = part.scan(/<img\b([^>]*)>/).filter_map do |(attributes)|
          src = attributes[/\bsrc="([^"]*)"/, 1]
          src && { 'tag' => 'img', 'url' => CGI.unescapeHTML(src) }
        end
        links + images
      end
    end
  end
end
