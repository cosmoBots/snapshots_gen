# frozen_string_literal: true

# rqVar and rqValue of requirements: a valid, unique variable key becomes a
# datum under a "Project data" chapter, which the report names with its CSID.
# A key cosmoSys would refuse, and an rqValue without rqVar, stay on the
# requirement as custom fields with their history, and a project without data
# gets no chapter.

require 'minitest/autorun'
require_relative 'converter_snapshot_helper'

class ConverterDataSectionsTest < Minitest::Test
  include ConverterSnapshotHelper

  FIELDS = [{ 'id' => 1, 'name' => 'rqVar', 'type' => 'IssueCustomField', 'field_format' => 'string', 'multiple' => false },
            { 'id' => 2, 'name' => 'rqValue', 'type' => 'IssueCustomField', 'field_format' => 'string', 'multiple' => false }].freeze

  def value(id, issue_id, field_id, text)
    { 'id' => id, 'customized_type' => 'Issue', 'customized_id' => issue_id, 'custom_field_id' => field_id, 'value' => text }
  end

  def journal(id, issue_id)
    { 'id' => id, 'journalized_id' => issue_id, 'journalized_type' => 'Issue', 'user_id' => 1, 'notes' => '',
      'private_notes' => false, 'created_on' => TIME }
  end

  def cf_detail(id, journal_id, field_id, old_value, new_value)
    { 'id' => id, 'journal_id' => journal_id, 'property' => 'cf', 'prop_key' => field_id.to_s,
      'old_value' => old_value, 'value' => new_value }
  end

  def kept(item, name)
    Array(item.custom_fields).find { |entry| entry['name'] == name }&.fetch('value')
  end

  def test_project_data_chapter_is_reported_with_its_csid
    issues = [issue(1, tracker_id: 2), issue(2, tracker_id: 2), issue(3), issue(4, tracker_id: 2)]
    tables = base_tables(issues).merge(
      'custom_fields' => FIELDS,
      'custom_values' => [value(1, 1, 1, 'speed'), value(2, 1, 2, '3'), value(3, 2, 1, 'mass'), value(4, 4, 1, 'Speed')],
      'journals' => [journal(10, 1)],
      'journal_details' => [cf_detail(100, 10, 2, '2', '3')]
    )
    convert(tables) do |entities, report, plan|
      sections = report.entries.select { |entry| entry['code'] == 'data_section_created' }
      assert_equal ['item:data-1'], sections.map { |entry| entry['subject'] }
      section = plan.items.fetch('item:data-1')
      refute_nil section.csid
      assert_equal({ 'project' => 'alpha', 'csid' => section.csid, 'data' => 2 }, sections.first['detail'])
      assert_equal 2, report.count('datum_created')

      # A datum takes the variable: the requirement and its history lose it.
      assert_nil kept(plan.items.fetch('item:1'), 'rqVar')
      assert_empty entities.fetch('journal_details')
      # The same key again, in another case, is repeated in the tree.
      assert_equal 'Speed', kept(plan.items.fetch('item:4'), 'rqVar')
      entry = report.entries.find { |row| row['code'] == 'datum_field_kept' }
      assert_equal ['item:4', 'variable key repeated in the project tree'], [entry['subject'], entry.dig('detail', 'reason')]
    end
  end

  def test_variables_that_cannot_be_data_stay_as_custom_fields
    issues = [issue(1, tracker_id: 2), issue(2, tracker_id: 2), issue(3, tracker_id: 2)]
    tables = base_tables(issues).merge(
      'custom_fields' => FIELDS,
      'custom_values' => [value(1, 1, 1, 'Group 1'), value(2, 1, 2, ''), value(3, 2, 1, ''), value(4, 2, 2, '7')],
      'journals' => [journal(10, 1), journal(11, 2)],
      'journal_details' => [cf_detail(100, 10, 1, 'Group 0', 'Group 1'), cf_detail(101, 11, 2, nil, '7')]
    )
    convert(tables) do |entities, report, plan|
      # No datum, so no chapter.
      assert_empty plan.items.values.select { |item| %w[data_section datum].include?(item.profile) }
      assert_equal 0, report.count('data_section_created')
      assert_equal 0, report.count('datum_created')

      # The current values stay on the requirements, with their definitions.
      assert_equal 'Group 1', kept(plan.items.fetch('item:1'), 'rqVar')
      assert_equal '7', kept(plan.items.fetch('item:2'), 'rqValue')
      assert_nil kept(plan.items.fetch('item:3'), 'rqVar')
      assert_equal %w[rqValue rqVar], entities.fetch('custom_fields').map { |row| row['name'] }.sort
      assert_equal({ 'item:1' => 'invalid variable key', 'item:2' => 'rqValue without rqVar' },
                   report.entries.select { |row| row['code'] == 'datum_field_kept' }
                         .to_h { |row| [row['subject'], row.dig('detail', 'reason')] })
      refute(report.entries.any? { |row| row['code'] == 'field_value_unmapped' && row.dig('detail', 'field') == 'rqVar' })
      refute(report.entries.any? { |row| row['code'] == 'field_dropped' && %w[rqVar rqValue].include?(row['subject']) })

      # Their history stays as changes of those fields.
      details = entities.fetch('journal_details').sort_by { |row| row['id'] }
      assert_equal [[100, 'cf', '1', 'custom_fields', 'Group 0', 'Group 1'], [101, 'cf', '2', 'custom_fields', nil, '7']],
                   details.map { |row| row.values_at('id', 'property', 'prop_key', 'prop_ref', 'old_value', 'value') }
      assert_equal 0, report.count('history_detail_dropped')
    end
  end
end
