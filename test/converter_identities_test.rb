# frozen_string_literal: true

# CSID prefixes that cosmoSys does not accept (anything but letters and
# digits): the project's own code and the prefix of another project (an item
# that was moved) are both made alphanumeric with the same rule; a collision
# that this creates is blocking, and so is a CSID that the next new items of a
# project would take again. Every name is invented.

require 'minitest/autorun'
require_relative 'converter_fixture'

class ConverterIdentitiesTest < Minitest::Test
  include ConverterFixture

  # alpha (ALP) with a child alpha-sub (SUB); beta (BET) is another tree.
  def tables(identifiers)
    base = base_tables
    issues = identifiers.each_with_index.map do |(project_id, _identifier), index|
      issue(index + 1, project_id, 1, "Item #{index + 1}")
    end
    base.merge(
      'issues' => issues,
      'cosmosys_issues' => identifiers.each_with_index.map do |(_project_id, identifier), index|
        { 'id' => index + 1, 'issue_id' => index + 1, 'identifier' => identifier, 'chapter_order' => index + 1 }
      end
    )
  end

  def entries(report, code)
    report.entries.select { |entry| entry['code'] == code }
  end

  def test_foreign_prefix_with_dashes_loses_them
    with_plan(tables([[1, 'ALP-0001'], [2, 'AB-CD-0007'], [2, 'BET-0004'], [3, 'BET-0001']])) do |_source, plan, report|
      assert_equal 'ABCD-0007', plan.item_for_issue(2).csid
      assert_equal 7, plan.item_for_issue(2).csidnum
      normalized = entries(report, 'identity_prefix_normalized')
      assert_equal [['item:2', { 'from' => 'AB-CD-0007', 'to' => 'ABCD-0007' }]],
                   normalized.map { |entry| [entry['subject'], entry['detail']] }
      # An alphanumeric foreign prefix is still kept as it was.
      kept = entries(report, 'identity_foreign_prefix_kept')
      assert_equal ['item:3'], kept.map { |entry| entry['subject'] }
      assert_equal 'BET-0004', plan.item_for_issue(3).csid
      refute report.blocking?
    end
  end

  def test_collision_created_by_the_normalization_is_blocking
    with_plan(tables([[1, 'ALP-0001'], [1, 'AB-0003'], [2, 'A-B-0003'], [3, 'A-B-0003']])) do |_source, plan, report|
      collisions = entries(report, 'identity_normalized_collision')
      assert_equal ['item:3'], collisions.map { |entry| entry['subject'] }
      assert_equal({ 'from' => 'A-B-0003', 'to' => 'AB-0003', 'other' => 'item:2', 'other_from' => 'AB-0003' },
                   collisions.first['detail'])
      assert report.blocking?
      # The colliding item still gets a CSID of its own (the next of its project).
      refute_equal 'AB-0003', plan.item_for_issue(3).csid
      # Another tree has no collision: AB-0003 there is unique.
      assert_equal 'AB-0003', plan.item_for_issue(4).csid
    end
  end

  # A project without items numbers its first item 1: an item of another
  # project of the tree with its code and number 1 or more blocks too.
  def test_empty_project_is_checked_as_well
    with_plan(tables([[1, 'S-UB-0001']])) do |_source, plan, report|
      assert_equal 'SUB-0001', plan.item_for_issue(1).csid
      future = entries(report, 'identity_future_collision')
      assert_equal [['item:1', { 'csid' => 'SUB-0001', 'project' => 'alpha-sub', 'next_number' => 1 }]],
                   future.map { |entry| [entry['subject'], entry['detail']] }
      assert report.blocking?
    end
  end

  def test_number_that_the_next_items_of_a_project_would_take_is_blocking
    with_plan(tables([[1, 'ALP-0001'], [1, 'ALP-0002'], [2, 'A-LP-0009'], [3, 'BET-0001']])) do |_source, plan, report|
      assert_equal 'ALP-0009', plan.item_for_issue(3).csid
      future = entries(report, 'identity_future_collision')
      assert_equal [['item:3', { 'csid' => 'ALP-0009', 'project' => 'alpha', 'next_number' => 3 }]],
                   future.map { |entry| [entry['subject'], entry['detail']] }
      assert report.blocking?
    end
    # Below the highest number of the project it is no risk.
    with_plan(tables([[1, 'ALP-0001'], [1, 'ALP-0012'], [2, 'A-LP-0009']])) do |_source, _plan, report|
      assert_empty entries(report, 'identity_future_collision')
      refute report.blocking?
    end
  end
end
