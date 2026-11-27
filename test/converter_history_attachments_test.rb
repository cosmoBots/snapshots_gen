# frozen_string_literal: true

# History changes of attachments that do not reach the new instance with their
# item: deleted from the old instance, or present but migrated with another
# container. Their old id would name another file in the new instance, so the
# converter writes id 0 (no attachment has it), keeps the file names and
# reports every case; the importer then writes exactly what the package says.
# Every name and text is invented.

require 'minitest/autorun'
require_relative 'converter_snapshot_helper'

class ConverterHistoryAttachmentsTest < Minitest::Test
  include ConverterSnapshotHelper

  def journal(id, issue_id)
    { 'id' => id, 'journalized_id' => issue_id, 'journalized_type' => 'Issue', 'user_id' => 1, 'notes' => '',
      'private_notes' => false, 'created_on' => TIME }
  end

  def detail(id, journal_id, attachment_id, old_value, value)
    { 'id' => id, 'journal_id' => journal_id, 'property' => 'attachment', 'prop_key' => attachment_id.to_s,
      'old_value' => old_value, 'value' => value }
  end

  def attachment(id, issue_id, filename)
    { 'id' => id, 'container_type' => 'Issue', 'container_id' => issue_id, 'filename' => filename,
      'disk_filename' => "#{id}_#{filename}", 'filesize' => 3, 'digest' => 'x', 'author_id' => 1,
      'created_on' => TIME }
  end

  # Attachment 7 belongs to item 1 and has its file; 8 belongs to item 2;
  # 9 was deleted from the old instance.
  def tables
    base_tables([issue(1), issue(2)]).merge(
      'attachments' => [attachment(7, 1, 'kept.txt'), attachment(8, 2, 'other.txt')],
      'journals' => [journal(10, 1), journal(11, 1), journal(12, 1), journal(13, 1)],
      'journal_details' => [
        detail(100, 10, 7, nil, 'kept.txt'),     # migrated with this item
        detail(101, 11, 9, 'gone.txt', nil),     # deleted, removal
        detail(102, 12, 9, nil, 'gone.txt'),     # deleted, addition
        detail(103, 13, 8, nil, 'other.txt')     # migrated with item 2, not with item 1
      ]
    )
  end

  def test_attachments_that_do_not_reach_the_item_take_id_zero_and_are_reported
    convert(tables, attachment_files: [7, 8]) do |entities, report, plan|
      details = entities.fetch('journal_details').to_h { |row| [row['id'], row] }

      assert_equal %w[7 attachments], details.fetch(100).values_at('prop_key', 'prop_ref')
      [101, 102, 103].each do |id|
        assert_equal ['0', nil], details.fetch(id).values_at('prop_key', 'prop_ref'), "detail #{id}"
      end
      assert_equal ['gone.txt', nil], details.fetch(101).values_at('old_value', 'value')
      assert_equal [nil, 'gone.txt'], details.fetch(102).values_at('old_value', 'value')
      assert_equal [10, 11, 12, 13], entities.fetch('journals').map { |row| row['id'] }

      cleared = report.entries.select { |entry| entry['code'] == 'history_attachment_cleared' }
      assert_equal ['detail #101', 'detail #102', 'detail #103'], cleared.map { |entry| entry['subject'] }.sort
      csid = plan.item_for_issue(1).csid
      assert_equal({ 'item' => 'item:1', 'csid' => csid, 'journal' => 11, 'attachment' => '9', 'missing' => ['old'],
                     'reason' => 'deleted from the source', 'old_value' => 'gone.txt', 'value' => nil },
                   cleared.find { |entry| entry['subject'] == 'detail #101' }['detail'])
      assert_equal ['new'], cleared.find { |entry| entry['subject'] == 'detail #102' }.dig('detail', 'missing')
      assert_equal 'not migrated with this item', cleared.find { |entry| entry['subject'] == 'detail #103' }.dig('detail', 'reason')
      refute(report.entries.any? { |entry| entry['code'] == 'history_attachment_cleared' && entry['subject'] == 'detail #100' })
    end
  end
end
