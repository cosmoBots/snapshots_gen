# frozen_string_literal: true

# The links of a text, rewritten by the converter as placeholders and
# resolved by the importer. Every text and id is invented.

require 'minitest/autorun'
require_relative '../converter/lib/snapshots_gen/text_links'

class TextLinksTest < Minitest::Test
  TL = SnapshotsGen::TextLinks

  ITEMS = [12, 47, 83, 65].freeze
  USERS = [6, 20].freeze
  ATTACHMENTS = [7, 70].freeze
  HOST = TL::Host.new('old.example.test', 'https')

  def rewriter(markdown: true, protect: nil, host: HOST)
    TL::Rewriter.new(item: ->(id) { ITEMS.include?(id) }, user: ->(id) { USERS.include?(id) },
                     attachment: ->(id) { ATTACHMENTS.include?(id) }, host: host, markdown: markdown, protect: protect)
  end

  def rewrite(text, **options)
    rewriter(**options).rewrite(text).first
  end

  def events(text, **options)
    rewriter(**options).rewrite(text).last.map { |event| event['kind'] }
  end

  # New ids: items + 1000, users + 100, attachments + 500.
  def resolve(text)
    TL::Resolver.new(item: ->(id) { ITEMS.include?(id) ? id + 1000 : nil }, user: ->(id) { id + 100 },
                     attachment: ->(id) { id + 500 }).resolve(text)
  end

  def test_item_references_become_placeholders
    assert_equal 'See #snapshots-gen-item-12 and ##snapshots-gen-item-47.', rewrite('See #12 and ##47.')
    assert_equal 'See #1012 and ##1047.', resolve(rewrite('See #12 and ##47.'))
    # Markdown marks that become tags, a note suffix and a project prefix.
    assert_equal '**#1012** _#1047_ (#1083-3) proj:#1065, #1012#note-2', resolve(rewrite('**#12** _#47_ (#83-3) proj:#65, #12#note-2'))
    # A reference to an item that is not migrated is escaped.
    assert_equal 'Gone !#99 and !##98', rewrite('Gone #99 and ##98')
    assert_equal %w[item_neutralized item_neutralized], events('Gone #99 and ##98')
  end

  # In the same package, cosmoSys's rewriter can turn #83 to #47 and
  # then #47 (the old id of another item) to #91. A placeholder holds no
  # "#id" for its rewriter to take, and the importer resolves in one pass.
  def test_cosmosys_rewriter_cannot_chain_placeholders
    replacements = { '#83' => '#47', '#47' => '#91' }
    cosmosys = lambda do |text|
      replacements.sort_by { |source, _target| -source.length }.reduce(text) do |result, (source, target)|
        result.gsub(/(?<![A-Za-z0-9_-])#{Regexp.escape(source)}(?![A-Za-z0-9_-])/, target)
      end
    end
    assert_equal 'Depends on #91', cosmosys.call('Depends on #83'), 'the chain this fixes'
    converted = rewrite('Depends on #83', protect: ->(id) { [83, 47].include?(id) })
    assert_equal converted, cosmosys.call(converted)
    assert_equal 'Depends on #1083', resolve(cosmosys.call(converted))
  end

  def test_what_is_not_a_reference_is_kept_and_protected_from_cosmosys
    text = "# Title\n\n`#12` and\n```\n#47\n```\n[anchor](#83) x:y:#12 page#12 &#12; !#47 #12a <span style=\"color:#47\">x</span>"
    protect = ->(id) { [12, 47, 83].include?(id) }
    converted = rewrite(text, protect: protect)
    refute_match(/(?<![A-Za-z0-9_-])#(?:12|47|83)(?![A-Za-z0-9_-])/, converted)
    assert_equal text, resolve(converted)
    assert_equal ['literal'] * 7, events(text, protect: protect)
    # Outside a .csys (protect nil) nothing changes at all.
    assert_equal text, rewrite(text)
  end

  def test_user_references
    assert_equal 'by user#snapshots-gen-user-20 and !user#99', rewrite('by user#20 and user#99')
    assert_equal 'by user#120', resolve(rewrite('by user#20'))
    assert_equal 'by user#106', resolve(rewrite('by user#6'))
    assert_equal %w[user user_neutralized], events('by user#20 and user#99')
    assert_equal 'see !user#20', rewrite('see !user#20')
  end

  def test_attachment_urls_of_the_old_instance
    text = '![](https://old.example.test/attachments/download/7/a(1).png) [doc](https://OLD.example.test/attachments/70)'
    converted = rewrite(text)
    assert_equal '![](/attachments/download/snapshots-gen-attachment-7/a(1).png) [doc](/attachments/snapshots-gen-attachment-70)', converted
    assert_equal '![](/attachments/download/507/a(1).png) [doc](/attachments/570)', resolve(converted)
    # A relative path with spaces: Redcarpet took it, CommonMark needs <...>.
    assert_equal '![](</attachments/download/507/a (1).png>)', resolve(rewrite('![](/attachments/download/7/a (1).png)'))
    # With a scheme and a space Redcarpet made no image, only an autolink of
    # the URL up to the space: that is what is kept.
    assert_equal '![]([a](/attachments/download/507/a) b.png)', resolve(rewrite('![](https://old.example.test/attachments/download/7/a b.png)'))
    # Thumbnails and relative paths. HTML is not rendered by Redmine 4.2's
    # Markdown (filter_html): an <img> there was never an image, and stays.
    assert_equal '![](/attachments/thumbnail/507/200) [x](/attachments/download/570/x.pdf)',
                 resolve(rewrite('![](https://old.example.test/attachments/thumbnail/7/200) [x](/attachments/download/70/x.pdf)'))
    html = '<img src="https://old.example.test/attachments/thumbnail/7/200">'
    assert_equal html, rewrite(html)
    # An attachment that does not reach the new instance never names another one.
    assert_equal '![](/attachments/download/0/gone.png)', rewrite('![](https://old.example.test/attachments/download/8/gone.png)')
    assert_equal %w[attachment_broken], events('![](https://old.example.test/attachments/download/8/gone.png)')
    # A bare URL to a file becomes a link with its name.
    assert_equal 'See [x.pdf](/attachments/download/507/x.pdf).', resolve(rewrite('See https://old.example.test/attachments/download/7/x.pdf.'))
    # Other hosts are left alone.
    other = '![](https://elsewhere.example.test/attachments/download/7/a.png)'
    assert_equal other, rewrite(other)
    assert_empty events(other)
  end

  def test_item_urls_of_the_old_instance
    assert_equal '[here](/issues/1065) and #1065. Also #1065#note-2',
                 resolve(rewrite('[here](https://old.example.test/issues/65) and https://old.example.test/issues/65. Also https://old.example.test/issues/65#note-2'))
    assert_equal '[gone](/issues/0) and !#99', rewrite('[gone](https://old.example.test/issues/99) and https://old.example.test/issues/99')
    kept = 'https://old.example.test/projects/alpha/wiki'
    assert_equal kept, rewrite(kept)
    assert_equal %w[old_host_kept], events(kept)
    # Without a host, only relative paths are links into the instance.
    assert_equal 'https://old.example.test/issues/65', rewrite('https://old.example.test/issues/65', host: TL::Host.new(''))
  end

  # The angle rule (Markdown only): CommonMark refuses a destination with
  # spaces that Redcarpet accepted.
  def test_destinations_with_spaces
    assert_equal '![](<image (8).png>) ![](ok.png) [a](<b c.pdf>)', rewrite('![](image (8).png) ![](ok.png) [a](b c.pdf)')
    assert_equal %w[angle angle], events('![](image (8).png) ![](ok.png) [a](b c.pdf)')
    # Not with a scheme, quotes, a title, an exclamation mark or a line break,
    # and never inside code.
    kept = "![](http://x.test/a b) ![](\"a b\") ![](a b \"t\") ![](a!b c)\n![](\n![](x.png)) `![](a b)`\n```\n![](a b)\n```\n"
    assert_equal kept, rewrite(kept)
    assert_equal '![](a b)', rewrite('![](a b)', markdown: false)
  end

  def test_code_segments
    parts = TL.segments("a `b` c\n```\nd\n```\ne <pre>f</pre> ``g`` `h")
    assert_equal [['a ', false], ['`b`', true], [" c\n", false], ["```\nd\n```\n", true], ['e ', false], ['<pre>f</pre>', true],
                  [' ', false], ['``g``', true], [' `h', false]], parts
    assert_equal "a `b` c\n```\nd\n```\ne <pre>f</pre> ``g`` `h", parts.map(&:first).join
  end

  # Multibyte characters (2, 3 and 4 bytes) in and around inline code: the
  # parts join back into the exact input, and nothing in code is rewritten.
  def test_code_segments_with_multibyte_characters
    ["`é` tail", "`漢字 #12` end #12", "`😀` tail", "ñ `a` ü `b` 😀"].each do |text|
      assert_equal text, TL.segments(text).map(&:first).join
    end
    assert_equal "`漢字 #12` end #snapshots-gen-item-12", rewrite("`漢字 #12` end #12")
    assert_equal "`é` tail", rewrite("`é` tail")
  end

  # What Redmine 4.2 linked (Redcarpet with its formatter's options, then
  # parse_redmine_links on the HTML outside pre and code), case by case.
  def test_references_are_what_redmine_4_2_linked
    {
      '_#12' => '_#12',                            # literal: the underline never closes
      '|#12|' => '|#12|',                          # literal
      '***#12***' => '***#1012***',                # <strong><em>#12</em></strong>
      '\\#12' => '\\#1012',                        # Redcarpet drops the backslash
      '#012' => '#012',                            # only the canonical id links
      'user##20' => 'user##120',                   # "##" also for users
      '<code>#12</code>' => '<code>#1012</code>',  # filter_html removes the tag
      '`#12`' => '`#12`',                          # inline code
      "    #12\n" => "    #12\n",                  # indented code
      "```\n#12\n```\n" => "```\n#12\n```\n",      # fenced code
      'proj:#12, !#12 and #12-3' => 'proj:#1012, !#12 and #1012-3',
      '{{toc(#12)}} #12' => '{{toc(#12)}} #1012'   # macros are set apart first
    }.each { |text, expected| assert_equal expected, resolve(rewrite(text)), text }
  end

  # The key of a Markdown reference link or image is not a Redmine
  # reference: changing it would part the use from its definition.
  def test_markdown_reference_labels_are_kept
    text = "![diagram][#12] and [text][#12]\n\n[#12]: image.png\n"
    assert_equal text, rewrite(text)
    assert_equal %w[undecided undecided undecided], events(text)
  end

  # Indented code is code in both formatters: neither angles nor references.
  def test_indented_code_is_never_rewritten
    text = "Text\n\n    ![](a b.png)\n    #12\n"
    assert_equal text, rewrite(text)
    # A nested list is not code: its reference is rewritten.
    assert_equal "- a\n    - b #1012\n", resolve(rewrite("- a\n    - b #12\n"))
  end

  def test_urls_of_the_old_instance_in_every_form
    host = 'old.example.test'
    {
      "https://#{host}/issues/12?x=1" => '[#1012](/issues/1012?x=1)',
      "https://#{host}/issues/12#foo" => '[#1012](/issues/1012#foo)',
      "https://#{host}/issues/12#note-3" => '#1012#note-3',
      "[x](https://#{host}:443/issues/12)" => '[x](/issues/1012)',
      "[x](http://#{host}:80/issues/12)" => '[x](/issues/1012)',
      "[x](//#{host}/issues/12)" => '[x](/issues/1012)',
      "[x](https://#{host}:8443/issues/12)" => "[x](https://#{host}:8443/issues/12)"
    }.each { |text, expected| assert_equal expected, resolve(rewrite(text)), text }
    # A path prefix in host_name.
    prefixed = TL::Host.new("#{host}/redmine")
    assert_equal '[x](/issues/1012)', resolve(rewrite("[x](https://#{host}/redmine/issues/12)", host: prefixed))
    assert_equal "[x](https://#{host}/other/issues/12)", rewrite("[x](https://#{host}/other/issues/12)", host: prefixed)
  end

  # A source text that already holds something like a placeholder keeps it.
  def test_lookalikes_survive_the_round_trip
    resolver = TL::Resolver.new(item: ->(id) { id + 1000 }, user: ->(id) { id }, attachment: ->(id) { id })
    ['`#snapshots-gen-item-12`', 'user#snapshots-gen-user-3 and snapshots-gen-esc-x', '#12 and snapshots-gen-hash-4'].each do |text|
      assert_equal text.sub('#12 ', '#1012 '), resolver.resolve(rewrite(text)), text
    end
    assert_equal 1, TL::Resolver.new(item: ->(id) { id }, user: ->(id) { id }, attachment: ->(id) { id })
                                .tap { |r| r.resolve(rewrite('`#snapshots-gen-item-12`')) }.restored
  end

  def test_other_prefixes_are_counted_and_kept
    assert_equal 'document#3 version#4', rewrite('document#3 version#4')
    assert_equal %w[other_reference other_reference], events('document#3 version#4')
  end

  def test_leftover_and_nil
    assert_nil rewrite(nil)
    assert_match TL::LEFTOVER, rewrite('#12')
    refute_match TL::LEFTOVER, resolve(rewrite('#12 user#20 ![](/attachments/download/7/a.png)'))
  end
end
