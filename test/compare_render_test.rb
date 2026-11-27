# frozen_string_literal: true

# Step 7.4 on invented extracts: every failure the comparison must catch, and
# what the conversion report explains.

require 'minitest/autorun'
require_relative 'compare_render'

class CompareRenderTest < Minitest::Test
  META = { 'format' => 'render-text-v1', 'kind' => 'meta', 'host' => 'old.example.test' }.freeze

  def item(id, csid = 'DEMO-0001', project = 'demo')
    { 'id' => id, 'project' => project, 'csid' => csid }
  end

  def text(type, id, item_identity, **extra)
    { 'format' => 'render-text-v1', 'kind' => 'text', 'type' => type, 'id' => id, 'item' => item_identity, 'markers' => 0,
      'tags' => { 'p' => 1 }, 'visible' => 'Same text', 'images' => [], 'links' => [] }.merge(extra.transform_keys(&:to_s))
  end

  def image(filename, sha)
    { 'attachment' => { 'filename' => filename, 'sha256' => sha } }
  end

  def attachment(id, filename, sha, project = 'demo')
    { 'format' => 'render-text-v1', 'kind' => 'attachment', 'id' => id, 'filename' => filename, 'sha256' => sha,
      'container_type' => 'Issue', 'project' => project }
  end

  def report(*entries)
    { 'entries' => entries.map { |code, subject, detail| { 'code' => code, 'subject' => subject, 'detail' => detail || {} } } }
  end

  def compare(source, target, evidence = report)
    RenderComparison::Comparison.new([META] + source, [META.merge('host' => 'new.example.test')] + target, evidence).run
  end

  def test_same_rendering_is_ok_and_items_pair_by_reported_identity
    source = [text('description', 1, item(1, 'AB-C-0001')), attachment(5, 'a.png', 'x')]
    target = [text('description', 101, item(101, 'ABC-0001')), attachment(505, 'a.png', 'x')]
    refute compare(source, target).ok?, 'without the identity entry the description has no counterpart and the CSID differs'
    result = compare(source, target, report(['identity_prefix_normalized', 'item:1', { 'from' => 'AB-C-0001', 'to' => 'ABC-0001' }]))
    assert result.ok?, result.failures.inspect
    assert_equal 1, result.compared
  end

  def test_fewer_or_other_images_fail
    source = [text('description', 1, item(1), images: [image('a.png', 'x'), image('b.png', 'y')])]
    assert compare(source, [text('description', 101, item(101), images: [image('a.png', 'x'), image('b.png', 'y')])]).ok?
    lost = compare(source, [text('description', 101, item(101), images: [image('a.png', 'x'), { 'broken' => 'b c.png' }])])
    assert(lost.failures.any? { |line| line.include?('2 images in the source, 1 in the target') })
    other = compare(source, [text('description', 101, item(101), images: [image('a.png', 'x'), image('b.png', 'z')])])
    assert(other.failures.any? { |line| line.include?('image b.png') })
    # An image that was already broken in the source is not counted.
    broken = [text('description', 1, item(1), images: [{ 'broken' => '"x.png"' }])]
    assert compare(broken, [text('description', 101, item(101))]).ok?
  end

  def test_links_to_the_old_instance_and_placeholders_fail
    source = [text('description', 1, item(1), images: [image('a.png', 'x')])]
    old = { 'external' => 'https://old.example.test/attachments/download/5/a.png', 'host' => 'old.example.test' }
    result = compare(source, [text('description', 101, item(101), images: [old])])
    assert(result.failures.any? { |line| line.include?('points to the old instance') })
    assert(result.failures.any? { |line| line.include?('1 images in the source, 0 in the target') })
    leftover = compare([], [text('note', 7, item(101), markers: 2)])
    assert(leftover.failures.any? { |line| line.include?('2 placeholders left') })
  end

  # A link that leads to another item.
  def test_links_must_lead_to_the_same_item_user_and_file
    source = [text('description', 1, item(1), links: [{ 'item' => item(2, 'DEMO-0002') }, { 'user' => { 'login' => 'ana' } },
                                                       image('f.pdf', 's')])]
    same = [text('description', 101, item(101), links: [{ 'item' => item(102, 'DEMO-0002') }, { 'user' => { 'login' => 'ana' } },
                                                         image('f.pdf', 's')])]
    assert compare(source, same).ok?
    wrong = [text('description', 101, item(101), links: [{ 'item' => item(103, 'DEMO-0003') }, { 'user' => { 'login' => 'bob' } },
                                                          image('f.pdf', 'other')])]
    result = compare(source, wrong)
    assert_equal 6, result.failures.length, result.failures.inspect
  end

  def test_a_lost_link_needs_its_report_entry
    source = [text('description', 1, item(1), links: [{ 'item' => item(9, 'DEMO-0009') }], tags: { 'a' => 1, 'p' => 1 })]
    target = [text('description', 101, item(101))]
    refute compare(source, target).ok?
    result = compare(source, target, report(['reference_neutralized', 'item:1', { 'reference' => 9 }]))
    assert result.ok?, (result.failures + result.unexplained).inspect
    assert_equal({ 'reference_neutralized [report.json]' => 1 }, result.explained)
  end

  def test_rendering_differences_need_the_dialect_entry
    source = [text('note', 4, item(1), at: 't', tags: { 'u' => 1 })]
    target = [text('note', 40, item(101), at: 't', tags: { 'em' => 1 })]
    result = compare(source, target)
    assert_equal 1, result.unexplained.length
    assert compare(source, target, report(['markdown_dialect', 'journal #4', { 'kinds' => ['underline'] }])).ok?
    # Item numbers and the tracker name of a link are not a difference.
    numbers = compare([text('note', 4, item(1), at: 't', visible: 'See rq #12: x')],
                      [text('note', 40, item(101), at: 't', visible: 'See csRq #512: x')])
    assert numbers.ok?
  end

  def test_attachments_keep_their_bytes_and_losses_are_announced
    source = [attachment(1, 'a.png', 'x'), attachment(2, 'b.png', 'y'), attachment(3, 'c.png', 'z', nil)]
    target = [attachment(11, 'a.png', 'x'), attachment(12, 'b.png', 'changed')]
    result = compare(source, target)
    assert(result.failures.any? { |line| line.include?('#12 (b.png)') })
    assert(result.failures.any? { |line| line.include?('#2 (b.png) is not in the target') })
    assert(result.failures.any? { |line| line.include?('#3 (c.png) is not in the target') })
    fixed = compare(source, [attachment(11, 'a.png', 'x'), attachment(12, 'b.png', 'y')],
                    report(['attachment_without_container', 'attachment #3', { 'reason' => 'no container' }]))
    assert fixed.ok?, fixed.failures.inspect
    # The same file in an announced orphan and in a migrated attachment.
    twins = [attachment(3, 'c.png', 'z', nil), attachment(4, 'c.png', 'z')]
    assert compare(twins, [attachment(14, 'c.png', 'z')], report(['attachment_without_container', 'attachment #3', {}])).ok?
    # Attachments of projects that the source does not have (help pages) are not compared.
    assert compare([], [attachment(20, 'help.png', 'h', 'csys_help')]).ok?
  end
end
