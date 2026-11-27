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
    text = '![](https://old.example.test/attachments/download/7/a (1).png) [doc](https://OLD.example.test/attachments/70)'
    converted = rewrite(text)
    assert_equal '![](/attachments/download/snapshots-gen-attachment-7/a (1).png) [doc](/attachments/snapshots-gen-attachment-70)',
                 converted
    assert_equal '![](/attachments/download/507/a (1).png) [doc](/attachments/570)', resolve(converted)
    # Thumbnails, relative paths and HTML attributes.
    assert_equal '<img src="/attachments/thumbnail/507/200"> [x](/attachments/download/570/x.pdf)',
                 resolve(rewrite('<img src="https://old.example.test/attachments/thumbnail/7/200"> [x](/attachments/download/70/x.pdf)'))
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

  def test_code_segments
    parts = TL.segments("a `b` c\n```\nd\n```\ne <pre>f</pre> ``g`` `h")
    assert_equal [['a ', false], ['`b`', true], [" c\n", false], ["```\nd\n```\n", true], ['e ', false], ['<pre>f</pre>', true],
                  [' ', false], ['``g``', true], [' `h', false]], parts
    assert_equal "a `b` c\n```\nd\n```\ne <pre>f</pre> ``g`` `h", parts.map(&:first).join
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
