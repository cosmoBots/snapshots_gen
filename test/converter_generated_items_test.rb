# frozen_string_literal: true

# Items that exist only in the new instance (a "Group: ..." chapter around a
# requirement with children, a "Project data" chapter and its data) are named
# in the report with their final CSID, one item_generated entry each, so a
# checker can recognise them without reading the converter. Source items keep
# their identity entries as before. Every name and text is invented.

require 'minitest/autorun'
require_relative 'converter_snapshot_helper'

class ConverterGeneratedItemsTest < Minitest::Test
  include ConverterSnapshotHelper

  FIELDS = [{ 'id' => 1, 'name' => 'rqVar', 'type' => 'IssueCustomField', 'field_format' => 'string', 'multiple' => false },
            { 'id' => 2, 'name' => 'rqValue', 'type' => 'IssueCustomField', 'field_format' => 'string', 'multiple' => false }].freeze

  def value(id, issue_id, field_id, text)
    { 'id' => id, 'customized_type' => 'Issue', 'customized_id' => issue_id, 'custom_field_id' => field_id, 'value' => text }
  end

  def test_every_generated_item_is_reported_with_its_final_csid
    # Requirement 1 has a child (2), so it is wrapped in a chapter, and a
    # valid variable, so it gives a datum under a data chapter.
    tables = base_tables([issue(1, tracker_id: 2), issue(2, parent_id: 1), issue(3)]).merge(
      'custom_fields' => FIELDS, 'custom_values' => [value(1, 1, 1, 'speed'), value(2, 1, 2, '3')]
    )
    convert(tables) do |_entities, report, plan|
      generated = report.entries.select { |entry| entry['code'] == 'item_generated' }.to_h { |entry| [entry['subject'], entry['detail']] }
      assert_equal %w[item:data-1 item:datum-1 item:group-1], generated.keys.sort
      synthetic = plan.items.values.select(&:synthetic?)
      assert_equal synthetic.map(&:key).sort, generated.keys.sort
      synthetic.each do |item|
        refute_nil item.csid
        assert_equal item.csid, generated.fetch(item.key)['csid'], item.key
        assert_equal 'alpha', generated.fetch(item.key)['project'], item.key
      end
      assert_equal({ 'kind' => 'group', 'project' => 'alpha', 'csid' => plan.items.fetch('item:group-1').csid,
                     'from' => 'item:1' }, generated.fetch('item:group-1'))
      assert_equal({ 'kind' => 'data_section', 'project' => 'alpha', 'csid' => plan.items.fetch('item:data-1').csid,
                     'from' => nil }, generated.fetch('item:data-1'))
      assert_equal({ 'kind' => 'datum', 'project' => 'alpha', 'csid' => 'speed', 'from' => 'item:1' }, generated.fetch('item:datum-1'))

      # Source items: identity entries only for source items, as before.
      identities = report.entries.select { |entry| entry['code'].start_with?('identity_') }.map { |entry| entry['subject'] }
      assert(identities.all? { |subject| subject.match?(/\Aitem:\d+\z/) }, identities.inspect)
    end
  end
end
