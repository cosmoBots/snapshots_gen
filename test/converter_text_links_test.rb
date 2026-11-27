# frozen_string_literal: true

# The converter writes every link to an item, a user or an attachment of the
# old instance as a placeholder, in every text the .csys and the history
# carry, and the history keeps the same rewriting as the current texts. Every
# name and text is invented.

require 'minitest/autorun'
require_relative 'converter_snapshot_helper'

class ConverterTextLinksTest < Minitest::Test
  include ConverterSnapshotHelper

  HOST = 'https://old.example.test'
  MARKDOWN = { 'text_formatting' => 'markdown' }.freeze

  def custom_field(id, name, format)
    { 'id' => id, 'type' => 'IssueCustomField', 'name' => name, 'field_format' => format, 'multiple' => false,
      'is_for_all' => true, 'default_value' => nil, 'possible_values' => nil, 'format_store' => nil }
  end

  # alpha (1) holds items 1 (a requirement) and 2; beta (2), another root
  # tree and so another .csys, holds item 3. Attachment 10 belongs to item 2,
  # 11 has no file; user 1 exists, 77 does not.
  def tables(description)
    issues = [issue(1, tracker_id: 2), issue(2), issue(3).merge('project_id' => 2)]
    issues[0]['description'] = description
    base = base_tables(issues)
    base['projects'] << { 'id' => 2, 'identifier' => 'beta', 'name' => 'Beta', 'parent_id' => nil, 'lft' => 3, 'rgt' => 4,
                          'status' => 1, 'is_public' => true, 'description' => "Start at #1 or #{HOST}/issues/3" }
    base['cosmosys_projects'] << { 'id' => 2, 'project_id' => 2, 'prefix' => 'BET' }
    base['cosmosys_issues'][2]['identifier'] = 'BET-0003'
    base.merge(
      'settings' => [{ 'id' => 1, 'name' => 'host_name', 'value' => 'old.example.test' },
                     { 'id' => 2, 'name' => 'protocol', 'value' => 'https' }],
      'custom_fields' => [custom_field(5, 'rqRationale', 'text'), custom_field(6, 'Notes', 'text'), custom_field(7, 'Code', 'string')],
      'custom_values' => [
        { 'id' => 1, 'customized_type' => 'Issue', 'customized_id' => 1, 'custom_field_id' => 5, 'value' => 'Because of #2 and #3' },
        { 'id' => 2, 'customized_type' => 'Issue', 'customized_id' => 1, 'custom_field_id' => 6, 'value' => 'See #3 and `#2`' },
        { 'id' => 3, 'customized_type' => 'Issue', 'customized_id' => 1, 'custom_field_id' => 7, 'value' => 'X #2' }
      ],
      'attachments' => [
        { 'id' => 10, 'container_type' => 'Issue', 'container_id' => 2, 'filename' => 'a b.png', 'author_id' => 1, 'created_on' => TIME },
        { 'id' => 11, 'container_type' => 'Issue', 'container_id' => 2, 'filename' => 'gone.png', 'author_id' => 1, 'created_on' => TIME }
      ],
      'documents' => [{ 'id' => 1, 'project_id' => 1, 'title' => 'Doc', 'description' => 'About #3', 'category_id' => nil,
                        'created_on' => TIME }],
      'journals' => [{ 'id' => 20, 'journalized_id' => 1, 'journalized_type' => 'Issue', 'user_id' => 1,
                       'notes' => "user#1 and user#77 on #3 ![](#{HOST}/attachments/download/10/a b.png)",
                       'private_notes' => false, 'created_on' => TIME }],
      'journal_details' => [
        { 'id' => 30, 'journal_id' => 20, 'property' => 'attr', 'prop_key' => 'description', 'old_value' => 'Was #2',
          'value' => description },
        { 'id' => 31, 'journal_id' => 20, 'property' => 'cf', 'prop_key' => '5', 'old_value' => nil, 'value' => 'Because of #2 and #3' },
        { 'id' => 32, 'journal_id' => 20, 'property' => 'cf', 'prop_key' => '6', 'old_value' => '#99', 'value' => 'See #3 and `#2`' }
      ]
    )
  end

  DESCRIPTION = "Depends on #2 and #3, not on #99. Code `#2`.\n" \
                "![](#{HOST}/attachments/download/10/a b.png) ![](#{HOST}/attachments/download/11/gone.png)\n" \
                "[the other](#{HOST}/issues/3), #{HOST}/issues/2 and user#1, user#77, #{HOST}/projects/beta"

  def test_every_text_gets_placeholders
    convert(tables(DESCRIPTION), attachment_files: [10], settings: MARKDOWN) do |entities, report, plan|
      item = plan.item_for_issue(1)
      # cosmoSys's rewriter would take "#2" (same .csys) in the code: it is protected.
      assert_equal "Depends on #snapshots-gen-item-2 and #snapshots-gen-item-3, not on !#99. Code `#snapshots-gen-hash-2`.\n" \
                   '![](/attachments/download/snapshots-gen-attachment-10/a b.png) ![](/attachments/download/0/gone.png)' \
                   "\n[the other](/issues/snapshots-gen-item-3), #snapshots-gen-item-2 and user#snapshots-gen-user-1, !user#77, " \
                   "#{HOST}/projects/beta", item.description
      assert_equal 'Because of #snapshots-gen-item-2 and #snapshots-gen-item-3', item.profile_fields['rq_rationale']
      fields = item.custom_fields.to_h { |entry| [entry['name'], entry['value']] }
      assert_equal 'See #snapshots-gen-item-3 and `#snapshots-gen-hash-2`', fields['Notes']
      assert_equal 'X #snapshots-gen-item-2', fields['Code']
      assert_equal 'About #snapshots-gen-item-3', plan.documents.fetch('document:1').description
      assert_equal 'Start at #snapshots-gen-item-1 or #snapshots-gen-item-3', plan.project_description(2)

      # The history: notes, the description change (no protection: cosmoSys
      # never reads it) and the text field changes.
      notes = entities.fetch('journals').first['notes']
      assert_equal 'user#snapshots-gen-user-1 and !user#77 on #snapshots-gen-item-3 ' \
                   '![](/attachments/download/snapshots-gen-attachment-10/a b.png)', notes
      details = entities.fetch('journal_details').to_h { |row| [row['id'], row] }
      assert_equal 'Was #snapshots-gen-item-2', details.fetch(30)['old_value']
      assert_equal item.description.sub('#snapshots-gen-hash-2', '#2'), details.fetch(30)['value']
      assert_equal ['attr', 'rq_rationale', 'Because of #snapshots-gen-item-2 and #snapshots-gen-item-3'],
                   details.fetch(31).values_at('property', 'prop_key', 'value')
      assert_equal ['!#99', 'See #snapshots-gen-item-3 and `#2`'], details.fetch(32).values_at('old_value', 'value')

      codes = report.entries.group_by { |entry| entry['code'] }
      assert_equal 'old.example.test', codes.fetch('source_host').first['subject']
      neutralized = codes.fetch('reference_neutralized').map { |entry| [entry['subject'], entry.dig('detail', 'reference')] }.sort
      assert_includes neutralized, ['item:1', 99]
      assert_includes neutralized, ['detail #32', 99]
      assert_equal [['detail #30', 77], ['item:1', 77], ['journal #20', 77]], codes.fetch('user_reference_neutralized').map { |entry| [entry['subject'], entry.dig('detail', 'reference')] }.sort
      assert_equal item.csid, codes.fetch('user_reference_neutralized').first.dig('detail', 'csid')
      rewritten = codes.fetch('instance_link_rewritten').select { |entry| entry['subject'] == 'item:1' }
      assert_equal [%w[attachment 10 path], %w[item 3 path], %w[item 2 reference]],
                   rewritten.map { |entry| [entry.dig('detail', 'kind'), entry.dig('detail', 'source_id').to_s, entry.dig('detail', 'form')] }
      assert_equal [['detail #30', 11], ['item:1', 11]], codes.fetch('attachment_link_broken').map { |entry| [entry['subject'], entry.dig('detail', 'attachment')] }.sort
      assert_equal ["#{HOST}/projects/beta"], codes.fetch('old_host_link_kept').map { |entry| entry.dig('detail', 'url') }.uniq
      counts = codes.fetch('text_placeholders').to_h { |entry| [entry['subject'], entry.dig('detail', 'count')] }
      assert_operator counts.fetch('item'), :>, 5
      assert_equal 2, counts.fetch('literal')
    end
  end
end
