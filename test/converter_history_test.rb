# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'converter_fixture'
require_relative '../converter/lib/snapshots_gen/converter/history_builder'

# Tag list changes in the history: the old plugin wrote them as attr/tag_list
# details with the printed lists as text. They must reach the history package
# exactly as they are.
class ConverterHistoryTest < Minitest::Test
  include ConverterFixture

  def journal(id, issue_id)
    { 'id' => id, 'journalized_id' => issue_id, 'journalized_type' => 'Issue', 'user_id' => 1, 'notes' => '',
      'private_notes' => false, 'created_on' => ConverterFixture::TIME }
  end

  def detail(id, journal_id, prop_key, old_value, value)
    { 'id' => id, 'journal_id' => journal_id, 'property' => 'attr', 'prop_key' => prop_key, 'old_value' => old_value,
      'value' => value }
  end

  def test_tag_list_details_survive_literally
    details = [
      # A journal with only a tag change, from nothing to a quoted name with a comma.
      detail(1, 1, 'tag_list', nil, '"A,B", c, #snapshots-gen-item-7'),
      # A mixed journal.
      detail(2, 2, 'subject', 'Old', 'New'),
      detail(3, 2, 'tag_list', "x, 'y'", "x, 'y', Z  "),
      # The whole list removed.
      detail(4, 3, 'tag_list', 'a, A, café', '')
    ]
    tables = ConverterFixture.base_tables.merge(
      'journals' => [journal(1, 1), journal(2, 2), journal(3, 4)],
      'journal_details' => details
    )
    ConverterFixture.with_plan(tables) do |_source, plan, report, tmp|
      builder = SnapshotsGen::Converter::HistoryBuilder.new(plan, csys_packages: [])
      entities = builder.entities
      assert_equal [1, 2, 3], entities.fetch('journals').map { |row| row['id'] }
      kept = entities.fetch('journal_details').sort_by { |row| row['id'] }
      assert_equal [1, 2, 3, 4], kept.map { |row| row['id'] }
      assert_equal 0, report.count('history_detail_dropped')
      assert_equal 0, report.count('history_journal_dropped')

      # And through the package, as the importer reads it.
      directory = File.join(tmp, 'history')
      builder.write(directory)
      assert_empty SnapshotsGen::LegacySnapshot::Verifier.new(directory).verify.errors
      packaged = File.foreach(File.join(directory, 'tables', 'journal_details.jsonl'), encoding: 'UTF-8')
                     .map { |line| JSON.parse(line) }
      [kept, packaged].each do |rows|
        details.each do |source_detail|
          row = rows.find { |entry| entry['id'] == source_detail['id'] }
          assert_equal [source_detail['property'], source_detail['prop_key'], nil, nil],
                       row.values_at('property', 'prop_key', 'value_ref', 'prop_ref')
          assert_equal [source_detail['old_value'], source_detail['value']], row.values_at('old_value', 'value')
        end
      end
      assert_equal [nil, '"A,B", c, #snapshots-gen-item-7'], packaged.first.values_at('old_value', 'value')
      assert_equal ['a, A, café', ''], packaged.last.values_at('old_value', 'value')
    end
  end
end
