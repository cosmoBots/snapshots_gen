# frozen_string_literal: true

# A synthetic legacy snapshot written with the real format writer and read
# back through the real Source, Plan and HistoryBuilder. Every name and text is
# invented. Columns are guessed from the values.

require 'tmpdir'
require_relative '../exporter/legacy_snapshot_format'
require_relative '../converter/lib/snapshots_gen/converter/source'
require_relative '../converter/lib/snapshots_gen/converter/report'
require_relative '../converter/lib/snapshots_gen/converter/plan'
require_relative '../converter/lib/snapshots_gen/converter/history_builder'

module ConverterSnapshotHelper
  LS = SnapshotsGen::LegacySnapshot
  Converter = SnapshotsGen::Converter
  TIME = '2021-03-04T05:06:07.000000Z'

  module_function

  def issue(id, tracker_id: 1, parent_id: nil)
    { 'id' => id, 'project_id' => 1, 'tracker_id' => tracker_id, 'status_id' => 1, 'subject' => "Item #{id}",
      'description' => '', 'parent_id' => parent_id, 'author_id' => 1, 'created_on' => TIME, 'updated_on' => TIME }
  end

  # One project (alpha) with the given issues, each with a CSID.
  def base_tables(issues)
    {
      'trackers' => [{ 'id' => 1, 'name' => 'csInfo' }, { 'id' => 2, 'name' => 'rq' }],
      'issue_statuses' => [{ 'id' => 1, 'name' => 'csNone', 'is_closed' => false }],
      'users' => [{ 'id' => 1, 'type' => 'User', 'login' => 'author', 'firstname' => 'A', 'lastname' => 'B',
                    'admin' => false, 'status' => 1 }],
      'projects' => [{ 'id' => 1, 'identifier' => 'alpha', 'name' => 'Alpha', 'parent_id' => nil, 'lft' => 1,
                       'rgt' => 2, 'status' => 1, 'is_public' => true }],
      'cosmosys_projects' => [{ 'id' => 1, 'project_id' => 1, 'prefix' => 'ALP' }],
      'issues' => issues,
      'cosmosys_issues' => issues.map do |row|
        { 'id' => row['id'], 'issue_id' => row['id'], 'identifier' => format('ALP-%04d', row['id']), 'chapter_order' => row['id'] }
      end
    }
  end

  # attachment_files: ids of attachment rows whose file the package carries.
  def legacy(directory, tables, attachment_files: [])
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
    unless attachment_files.empty?
      blob = File.join(directory, '..', 'blob')
      File.binwrite(blob, 'abc')
      writer.write_asset_index(attachment_files.map do |id|
        digest, bytes = writer.add_asset(blob)
        { 'attachment_id' => id, 'sha256' => digest, 'bytes' => bytes, 'status' => 'present' }
      end)
    end
    writer.write_report_rows('redactions', [])
    writer.write_report_document('inventory', { 'plugins' => [] })
    writer.finish!(captured_at: TIME, generator: { 'name' => 'test', 'version' => '0' },
                   source: { 'label' => 'test', 'redmine_version' => '4.2.10', 'settings' => { 'text_formatting' => 'common_mark' } },
                   consistency: { 'mode' => 'none' })
    directory
  end

  # Yields the history entities, the report and the plan of a conversion.
  def convert(tables, attachment_files: [])
    Dir.mktmpdir('converter-snapshot') do |tmp|
      Converter::Source.open(legacy(File.join(tmp, 'legacy'), tables, attachment_files: attachment_files)) do |source|
        report = Converter::Report.new
        plan = Converter::Plan.new(source, report).build!
        entities = Converter::HistoryBuilder.new(plan, csys_packages: []).entities
        yield entities, report, plan
      end
    end
  end
end
