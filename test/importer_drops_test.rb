# frozen_string_literal: true

# What the history importer drops is named by its source journal, its item and
# the item CSID, and the history-import report keeps a stable shape. Runs
# without Redmine: only the translation of references is exercised.

require 'minitest/autorun'
require_relative '../importer/history_importer'

class ImporterDropsTest < Minitest::Test
  Run = SnapshotsGen::Importer::Run

  def run_with_items
    run = Run.new(nil, 'dry_run' => true)
    run.instance_variable_set(:@issue_key, { 3 => 'item:3' })
    run.instance_variable_set(:@item_map, { 'item:3' => 300 })
    run.instance_variable_set(:@csid_by_key, { 'item:3' => 'ALP-0003' })
    run
  end

  def test_a_reference_the_converter_did_not_clear_is_dropped_with_its_journal_and_csid
    run = run_with_items
    journal = { 'id' => 10, 'item_key' => 'item:3' }
    kept = { 'id' => 100, 'property' => 'attr', 'prop_key' => 'parent_id', 'value_ref' => 'items',
             'old_value' => nil, 'value' => '3' }
    lost = kept.merge('id' => 101, 'old_value' => '90')
    assert_equal({ 'property' => 'attr', 'prop_key' => 'parent_id', 'old_value' => nil, 'value' => '300' },
                 run.send(:translate, kept, 300, journal))
    assert_nil run.send(:translate, lost, 300, journal)

    summary = run.summary
    assert_equal 'snapshots_gen-history-import-v1', summary['format']
    assert summary['dry_run']
    assert_equal [{ 'kind' => 'journal_detail', 'id' => 101, 'reason' => 'items 90 not found', 'journal' => 10,
                    'item' => 'item:3', 'csid' => 'ALP-0003' }], summary['dropped']
    assert_equal({ 'journal_detail' => 1 }, summary['dropped_counts'])
  end
end
