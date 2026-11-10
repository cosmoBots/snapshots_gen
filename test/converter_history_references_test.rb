# frozen_string_literal: true

# History changes that name a record deleted from the old instance: a parent
# item, a version, a status... The converter must leave that side empty (never
# a number that would name another record in the new instance), keep the
# journal when something is left, and report every case, so the importer never
# has to drop anything on its own. Every name and text is invented.

require 'minitest/autorun'
require 'tmpdir'
require_relative '../exporter/legacy_snapshot_format'
require_relative '../converter/lib/snapshots_gen/converter/source'
require_relative '../converter/lib/snapshots_gen/converter/report'
require_relative '../converter/lib/snapshots_gen/converter/plan'
require_relative '../converter/lib/snapshots_gen/converter/history_builder'

class ConverterHistoryReferencesTest < Minitest::Test
  LS = SnapshotsGen::LegacySnapshot
  Converter = SnapshotsGen::Converter
  TIME = '2021-03-04T05:06:07.000000Z'

  def issue(id, parent_id = nil)
    { 'id' => id, 'project_id' => 1, 'tracker_id' => 1, 'status_id' => 1, 'subject' => "Item #{id}",
      'description' => '', 'parent_id' => parent_id, 'author_id' => 1, 'created_on' => TIME, 'updated_on' => TIME }
  end

  def journal(id, issue_id, notes = '')
    { 'id' => id, 'journalized_id' => issue_id, 'journalized_type' => 'Issue', 'user_id' => 1, 'notes' => notes,
      'private_notes' => false, 'created_on' => TIME }
  end

  def detail(id, journal_id, prop_key, old_value, value)
    { 'id' => id, 'journal_id' => journal_id, 'property' => 'attr', 'prop_key' => prop_key,
      'old_value' => old_value, 'value' => value }
  end

  # Items 1, 2 and 3 exist; 90 and 91 were deleted from the old instance.
  # Version 5 exists, version 6 was deleted.
  def tables
    {
      'trackers' => [{ 'id' => 1, 'name' => 'csInfo' }],
      'issue_statuses' => [{ 'id' => 1, 'name' => 'csNone', 'is_closed' => false }],
      'users' => [{ 'id' => 1, 'type' => 'User', 'login' => 'author', 'firstname' => 'A', 'lastname' => 'B',
                    'admin' => false, 'status' => 1 }],
      'projects' => [{ 'id' => 1, 'identifier' => 'alpha', 'name' => 'Alpha', 'parent_id' => nil, 'lft' => 1,
                       'rgt' => 2, 'status' => 1, 'is_public' => true }],
      'cosmosys_projects' => [{ 'id' => 1, 'project_id' => 1, 'prefix' => 'ALP' }],
      'issues' => [issue(1), issue(2), issue(3, 2)],
      'cosmosys_issues' => [1, 2, 3].map { |id| { 'id' => id, 'issue_id' => id, 'identifier' => format('ALP-%04d', id), 'chapter_order' => id } },
      'versions' => [{ 'id' => 5, 'project_id' => 1, 'name' => 'v1', 'status' => 'open', 'sharing' => 'none' }],
      'journals' => [journal(10, 3), journal(11, 3), journal(12, 3), journal(13, 3, 'A note'), journal(14, 3),
                     journal(15, 3), journal(16, 3)],
      'journal_details' => [
        detail(100, 10, 'parent_id', '90', '2'),   # moved away from a deleted parent
        detail(101, 11, 'parent_id', '91', nil),   # removed from a deleted parent
        detail(102, 12, 'parent_id', '90', '91'),  # between two deleted parents
        detail(103, 13, 'parent_id', '90', '91'),  # the same, in a journal with notes
        detail(104, 14, 'parent_id', '1', '2'),    # both alive
        detail(105, 15, 'fixed_version_id', '6', '5'),
        detail(106, 16, 'parent_id', nil, '90'),
        detail(107, 16, 'subject', 'Old', 'New')
      ]
    }
  end

  def legacy(directory, tables)
    writer = LS::Writer.new(directory)
    tables.each do |name, rows|
      names = rows.flat_map(&:keys).uniq
      columns = names.map do |column|
        sample = rows.map { |row| row[column] }.compact.first
        type = case sample
               when Integer then 'integer'
               when true, false then 'boolean'
               else column.end_with?('_on', '_at') ? 'datetime' : 'text'
               end
        { 'name' => column, 'type' => type, 'sql_type' => type, 'null' => true }
      end
      rows = rows.map { |row| names.to_h { |column| [column, row[column]] } }.sort_by { |row| row['id'] }
      writer.write_table(name, columns: columns, primary_key: ['id'], order_by: ['id']) do |emit|
        rows.each { |row| emit.call(row) }
      end
    end
    writer.write_report_rows('redactions', [])
    writer.write_report_document('inventory', { 'plugins' => [] })
    writer.finish!(captured_at: TIME, generator: { 'name' => 'test', 'version' => '0' },
                   source: { 'label' => 'test', 'redmine_version' => '4.2.10', 'settings' => { 'text_formatting' => 'common_mark' } },
                   consistency: { 'mode' => 'none' })
    directory
  end

  def convert
    Dir.mktmpdir('converter-references') do |tmp|
      Converter::Source.open(legacy(File.join(tmp, 'legacy'), tables)) do |source|
        report = Converter::Report.new
        plan = Converter::Plan.new(source, report).build!
        entities = Converter::HistoryBuilder.new(plan, csys_packages: []).entities
        yield entities, report, plan
      end
    end
  end

  def test_deleted_records_are_cleared_never_kept_as_numbers
    convert do |entities, report, plan|
      details = entities.fetch('journal_details').to_h { |row| [row['id'], row] }
      journals = entities.fetch('journals').map { |row| row['id'] }

      assert_equal [nil, '2'], details.fetch(100).values_at('old_value', 'value')
      assert_equal 'items', details.fetch(100)['value_ref']
      assert_equal %w[1 2], details.fetch(104).values_at('old_value', 'value')
      assert_equal [nil, '5'], details.fetch(105).values_at('old_value', 'value')
      assert_equal [nil, 'Old'], [details.fetch(106, nil), details.fetch(107)['old_value']]
      refute details.key?(101)
      refute details.key?(102)
      refute details.key?(103)

      # No detail names an item or version missing from the source.
      details.each_value do |row|
        ids = row.values_at('old_value', 'value').compact.map(&:to_i)
        case row['value_ref']
        when 'items' then ids.each { |id| assert plan.item_for_issue(id), "detail #{row['id']} names item #{id}" }
        when 'versions' then assert_empty ids - [5]
        end
      end

      # Journals: 11 and 12 had nothing else; 13 keeps its notes, 16 its subject.
      assert_equal [10, 13, 14, 15, 16], journals

      csid = plan.item_for_issue(3).csid
      cleared = report.entries.select { |entry| entry['code'] == 'history_reference_cleared' }
      assert_equal ['detail #100', 'detail #105'], cleared.map { |entry| entry['subject'] }.sort
      entry = cleared.find { |row| row['subject'] == 'detail #100' }
      assert_equal({ 'item' => 'item:3', 'csid' => csid, 'journal' => 10, 'field' => 'parent_id', 'missing' => ['old'],
                     'old_value' => '90', 'value' => '2' }, entry['detail'])
      dropped = report.entries.select { |entry| entry['code'] == 'history_reference_dropped' }
      assert_equal ['detail #101', 'detail #102', 'detail #103', 'detail #106'], dropped.map { |row| row['subject'] }.sort
      assert_equal %w[old new], dropped.find { |row| row['subject'] == 'detail #102' }.dig('detail', 'missing')
      assert_equal [11, 12], report.entries.select { |row| row['code'] == 'history_journal_dropped' }
                                    .map { |row| row['subject'][/\d+/].to_i }.sort
      assert_equal csid, report.entries.find { |row| row['code'] == 'history_journal_dropped' }.dig('detail', 'csid')
    end
  end
end
