# frozen_string_literal: true

# Step 7.4 on invented extracts: every failure the comparison must catch, and
# that a report entry only explains its own transformation.

require 'minitest/autorun'
require_relative 'compare_render'

class CompareRenderTest < Minitest::Test
  META = { 'format' => 'render-text-v2', 'kind' => 'meta', 'host' => 'old.example.test' }.freeze

  def item(id, csid = 'DEMO-0001', project = 'demo', tracker = 'rq')
    { 'id' => id, 'project' => project, 'csid' => csid, 'tracker' => tracker }
  end

  def text(type, id, item_identity, nodes = [['text', 'Same text']], **extra)
    { 'format' => 'render-text-v2', 'kind' => 'text', 'type' => type, 'id' => id, 'item' => item_identity, 'markers' => 0,
      'nodes' => nodes }.merge(extra.transform_keys(&:to_s))
  end

  def link_to_item(identity, text, fragment: nil)
    ['link', { 'kind' => 'item', 'item' => identity, 'rest' => '', 'fragment' => fragment }.compact, text]
  end

  def file(name, sha, id = 5, operation: 'download')
    { 'kind' => 'attachment', 'attachment' => { 'id' => id, 'filename' => name, 'sha256' => sha }, 'operation' => operation,
      'rest' => operation == 'thumbnail' ? '' : '/(name)' }
  end

  def attachment(id, filename, sha, container = ['item', 'demo', 'DEMO-0001', 1])
    { 'format' => 'render-text-v2', 'kind' => 'attachment', 'id' => id, 'filename' => filename, 'sha256' => sha,
      'container_type' => container[0] == 'item' ? 'Issue' : container[0].capitalize, 'container' => container,
      'project' => container[0] == 'none' ? nil : container[1] }
  end

  def report(*entries)
    { 'entries' => entries.map { |code, subject, detail| { 'code' => code, 'subject' => subject, 'detail' => detail || {} } } }
  end

  def compare(source, target, evidence = report)
    RenderComparison::Comparison.new([META] + source, [META.merge('host' => 'new.example.test')] + target, evidence).run
  end

  def test_items_pair_by_reported_identity
    source = [text('description', 1, item(1, 'AB-C-0001'))]
    target = [text('description', 101, item(101, 'ABC-0001'))]
    refute compare(source, target).ok?
    assert compare(source, target, report(['identity_prefix_normalized', 'item:1', { 'from' => 'AB-C-0001', 'to' => 'ABC-0001' }])).ok?
  end

  # Item links may change their number and tracker, nothing else.
  def test_item_link_text_changes_only_in_its_number_and_tracker
    two = item(2, 'DEMO-0002')
    source = [text('description', 1, item(1), [['text', 'See'], link_to_item(two, 'rq #2: Pump')])]
    target = [text('description', 101, item(101), [['text', 'See'], link_to_item(item(102, 'DEMO-0002', 'demo', 'csRq'), 'csRq #102: Pump')])]
    assert compare(source, target).ok?
    target[0]['nodes'][1][2] = 'csRq #102: Valve'
    refute compare(source, target).ok?
  end

  def test_swapped_links_note_fragments_and_operations_fail
    two = item(2, 'DEMO-0002')
    three = item(3, 'DEMO-0003')
    source = [text('description', 1, item(1), [['text', 'input'], link_to_item(two, '#2'), ['text', 'output'], link_to_item(three, '#3')])]
    swapped = [text('description', 101, item(101), [['text', 'input'], link_to_item(item(103, 'DEMO-0003'), '#103'),
                                                    ['text', 'output'], link_to_item(item(102, 'DEMO-0002'), '#102')])]
    refute compare(source, swapped).ok?
    note = [text('description', 1, item(1), [link_to_item(two, '#2-2', fragment: 'note-2')])]
    assert compare(note, [text('description', 101, item(101), [link_to_item(item(102, 'DEMO-0002'), '#102-2', fragment: 'note-2')])]).ok?
    refute compare(note, [text('description', 101, item(101), [link_to_item(item(102, 'DEMO-0002'), '#102-9', fragment: 'note-9')])]).ok?
    thumbnail = [text('description', 1, item(1), [['img', file('a.png', 's', operation: 'thumbnail')]])]
    refute compare(thumbnail, [text('description', 101, item(101), [['img', file('a.png', 's', 505)]])]).ok?
  end

  def test_fewer_or_other_images_and_old_host_and_placeholders_fail
    source = [text('description', 1, item(1), [['img', file('a.png', 'x')], ['img', file('b.png', 'y', 6)]])]
    assert compare(source, [text('description', 101, item(101), [['img', file('a.png', 'x', 7)], ['img', file('b.png', 'y', 8)]])]).ok?
    refute compare(source, [text('description', 101, item(101), [['img', file('a.png', 'x')], ['img', { 'kind' => 'broken' }]])]).ok?
    refute compare(source, [text('description', 101, item(101), [['img', file('a.png', 'x')], ['img', file('b.png', 'z')]])]).ok?
    old = { 'kind' => 'external', 'url' => 'https://old.example.test/attachments/download/5/a.png', 'host' => 'old.example.test' }
    result = compare([], [text('description', 101, item(101), [['img', old]])])
    assert(result.failures.any? { |line| line.include?('points to the old instance') })
    assert(compare([], [text('note', 7, item(101), markers: 2)]).failures.any? { |line| line.include?('2 placeholders left') })
    # An image that was already broken stays broken.
    broken = [text('description', 1, item(1), [['img', { 'kind' => 'broken' }]])]
    assert compare(broken, [text('description', 101, item(101), [['img', { 'kind' => 'broken' }]])]).ok?
  end

  # A dialect entry explains only its own change, never other text.
  def test_dialect_entry_explains_only_its_transformation
    dialect = report(['markdown_dialect', 'item:1', { 'kinds' => ['underline'] }])
    source = [text('description', 1, item(1), [['text', 'Voltage '], ['u'], ['text', 'nominal'], ['/u'], ['text', ' 5V']])]
    good = [text('description', 101, item(101), [['text', 'Voltage '], ['em'], ['text', 'nominal'], ['/em'], ['text', ' 5V']])]
    assert compare(source, good, dialect).ok?
    refute compare(source, good).ok?
    wrong = [text('description', 101, item(101), [['text', 'WRONG TEXT: '], ['em'], ['text', 'nominal'], ['/em'], ['text', ' 500V']])]
    refute compare(source, wrong, dialect).ok?
    strike = [text('description', 1, item(1), [['text', 'Moved to ~room 2~']])]
    struck = [text('description', 101, item(101), [['text', 'Moved to '], ['del'], ['text', 'room 2'], ['/del']])]
    assert compare(strike, struck, report(['markdown_dialect', 'item:1', { 'kinds' => ['strikethrough'] }])).ok?
    sup = [text('description', 1, item(1), [['text', 'Area x'], ['sup'], ['text', '2'], ['/sup'], ['text', ' m']])]
    assert compare(sup, [text('description', 101, item(101), [['text', 'Area x^2 m']])],
                   report(['markdown_dialect', 'item:1', { 'kinds' => ['superscript'] }])).ok?
  end

  # A lone "-" and an image with a quoted destination, as each Redmine
  # renders them (with whitespace between the tags).
  def test_empty_list_item_and_quoted_destination
    lone = [text('field', 1, item(1), [['text', '-']], field: 'Notes')]
    list = [text('field', 1, item(101), [['ul'], ['text', ' '], ['li'], ['/li'], ['text', "\n"], ['/ul']], field: 'Notes')]
    assert compare(lone, list, report(['markdown_dialect', 'item:1 Notes', { 'kinds' => ['empty_list_item'] }])).ok?
    refute compare(lone, list).ok?
    quoted = [text('note', 4, item(1), [['text', 'See '], ['img', { 'kind' => 'broken' }]], at: 't')]
    shown = [text('note', 40, item(101), [['text', 'See ![]("image (8).png")']], at: 't')]
    assert compare(quoted, shown, report(['markdown_dialect', 'journal #4', { 'kinds' => ['quoted_destination'] }])).ok?
    refute compare(quoted, shown).ok?
  end

  # Lists and underscores cannot be reproduced exactly: the same words,
  # links and images are required, and the text is listed for review.
  def test_dialect_that_cannot_be_reproduced_is_listed_for_review
    review = report(['markdown_dialect', 'journal #4', { 'kinds' => ['list_marker'] }])
    source = [text('note', 4, item(1), [['ul'], ['li'], ['text', 'a'], ['/li'], ['li'], ['text', 'b'], ['/li'], ['/ul']], at: 't')]
    target = [text('note', 40, item(101), [['ul'], ['li'], ['text', 'a'], ['/li'], ['/ul'], ['ul'], ['li'], ['text', 'b'], ['/li'], ['/ul']], at: 't')]
    result = compare(source, target, review)
    assert result.ok?
    assert_equal 1, result.review.length
    target[0]['nodes'][7] = ['text', 'c']
    refute compare(source, target, review).ok?
  end

  # Text that is not a link is compared as it is: numbers and words included.
  def test_literal_numbers_and_words_are_compared
    source = [text('description', 1, item(1), [['code'], ['text', 'Calibration #12'], ['/code']])]
    refute compare(source, [text('description', 101, item(101), [['code'], ['text', 'Deleted #999'], ['/code']])]).ok?
    refute compare([text('description', 1, item(1), [['text', 'a b']])], [text('description', 101, item(101), [['text', 'ab']])]).ok?
  end

  def test_announced_link_transformations
    gone = item(9, 'DEMO-0009')
    source = [text('description', 1, item(1), [['text', 'See '], link_to_item(gone, '#9')])]
    target = [text('description', 101, item(101), [['text', 'See #9']])]
    refute compare(source, target).ok?
    assert compare(source, target, report(['reference_neutralized', 'item:1', { 'reference' => 9 }])).ok?
    # A URL of the old instance that became a reference.
    url = 'https://old.example.test/issues/2'
    two = item(2, 'DEMO-0002')
    source = [text('description', 1, item(1), [link_to_item(two, url)])]
    target = [text('description', 101, item(101), [link_to_item(item(102, 'DEMO-0002'), '#102')])]
    refute compare(source, target).ok?
    assert compare(source, target, report(['instance_link_rewritten', 'item:1', { 'kind' => 'item', 'source_id' => 2, 'form' => 'reference' }])).ok?
  end

  def test_attachments_keep_their_bytes_and_their_container
    source = [attachment(1, 'a.pdf', 'A', ['project', 'alpha']), attachment(2, 'b.pdf', 'B', ['project', 'beta'])]
    assert compare(source, [attachment(11, 'a.pdf', 'A', ['project', 'alpha']), attachment(12, 'b.pdf', 'B', ['project', 'beta'])]).ok?
    swapped = [attachment(11, 'a.pdf', 'A', ['project', 'beta']), attachment(12, 'b.pdf', 'B', ['project', 'alpha'])]
    refute compare(source, swapped).ok?
    changed = [attachment(11, 'a.pdf', 'A', ['project', 'alpha']), attachment(12, 'b.pdf', 'changed', ['project', 'beta'])]
    refute compare(source, changed).ok?
    # Renamed CSIDs and items turned into documents.
    items = [attachment(3, 'c.png', 'C', ['item', 'demo', 'AB-C-0001', 1]), attachment(4, 'd.png', 'D', ['item', 'demo', 'DEMO-0005', 5])]
    moved = [attachment(13, 'c.png', 'C', ['item', 'demo', 'ABC-0001', 101]), attachment(14, 'd.png', 'D', ['document', 'demo', 'Plan'])]
    evidence = report(['identity_prefix_normalized', 'item:1', { 'to' => 'ABC-0001' }],
                      ['document_item_absorbed', '#5 AD 1', { 'document' => 'Plan', 'project' => 'demo' }])
    assert compare(items, moved, evidence).ok?
    # An orphan that is not migrated, announced; the same file migrated elsewhere.
    twins = [attachment(6, 'e.png', 'E', ['none', nil, nil]), attachment(7, 'e.png', 'E')]
    orphan = report(['attachment_without_container', 'attachment #6', {}])
    assert compare(twins, [attachment(17, 'e.png', 'E')], orphan).ok?
    refute compare(twins, [attachment(17, 'e.png', 'E')]).ok?
    # Attachments of projects that the source does not have are not compared.
    assert compare([], [attachment(20, 'help.png', 'h', ['wiki', 'csys_help', 'Help'])]).ok?
  end
end
