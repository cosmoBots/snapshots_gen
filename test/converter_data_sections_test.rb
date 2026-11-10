# frozen_string_literal: true

# The "Project data" chapter generated around the requirement variables exists
# only in the new instance: the report names it with its CSID.

require 'minitest/autorun'
require_relative 'converter_snapshot_helper'

class ConverterDataSectionsTest < Minitest::Test
  include ConverterSnapshotHelper

  def test_project_data_chapter_is_reported_with_its_csid
    issues = [issue(1, tracker_id: 2), issue(2, tracker_id: 2), issue(3)]
    tables = base_tables(issues).merge(
      'custom_fields' => [{ 'id' => 1, 'name' => 'rqVar', 'type' => 'IssueCustomField', 'field_format' => 'string', 'multiple' => false },
                          { 'id' => 2, 'name' => 'rqValue', 'type' => 'IssueCustomField', 'field_format' => 'string', 'multiple' => false }],
      'custom_values' => [
        { 'id' => 1, 'customized_type' => 'Issue', 'customized_id' => 1, 'custom_field_id' => 1, 'value' => 'speed' },
        { 'id' => 2, 'customized_type' => 'Issue', 'customized_id' => 1, 'custom_field_id' => 2, 'value' => '3' },
        { 'id' => 3, 'customized_type' => 'Issue', 'customized_id' => 2, 'custom_field_id' => 1, 'value' => 'mass' }
      ]
    )
    convert(tables) do |_entities, report, plan|
      sections = report.entries.select { |entry| entry['code'] == 'data_section_created' }
      assert_equal ['item:data-1'], sections.map { |entry| entry['subject'] }
      section = plan.items.fetch('item:data-1')
      refute_nil section.csid
      assert_equal({ 'project' => 'alpha', 'csid' => section.csid, 'data' => 2 }, sections.first['detail'])
      assert_equal 2, report.count('datum_created')
    end
  end
end
