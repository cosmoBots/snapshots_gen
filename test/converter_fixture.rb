# frozen_string_literal: true

# Synthetic legacy snapshots for the converter tests: a few tables written
# with the real format writer, read back with the real Source and Plan. Every
# name and text is invented.

require 'tmpdir'
require_relative '../exporter/legacy_snapshot_format'
require_relative '../converter/lib/snapshots_gen/converter/source'
require_relative '../converter/lib/snapshots_gen/converter/report'
require_relative '../converter/lib/snapshots_gen/converter/plan'

module ConverterFixture
  LS = SnapshotsGen::LegacySnapshot
  Converter = SnapshotsGen::Converter

  TAG_COLUMNS = [
    { 'name' => 'id', 'type' => 'integer', 'sql_type' => 'int(11)', 'null' => false },
    { 'name' => 'name', 'type' => 'string', 'sql_type' => 'varchar(191)', 'null' => true },
    { 'name' => 'taggings_count', 'type' => 'integer', 'sql_type' => 'int(11)', 'null' => true },
    { 'name' => 'created_at', 'type' => 'datetime', 'sql_type' => 'datetime', 'null' => false },
    { 'name' => 'updated_at', 'type' => 'datetime', 'sql_type' => 'datetime', 'null' => false }
  ].freeze
  TAGGING_COLUMNS = [
    { 'name' => 'id', 'type' => 'integer', 'sql_type' => 'int(11)', 'null' => false },
    { 'name' => 'tag_id', 'type' => 'integer', 'sql_type' => 'int(11)', 'null' => true },
    { 'name' => 'taggable_type', 'type' => 'string', 'sql_type' => 'varchar(255)', 'null' => true },
    { 'name' => 'taggable_id', 'type' => 'integer', 'sql_type' => 'int(11)', 'null' => true },
    { 'name' => 'tagger_type', 'type' => 'string', 'sql_type' => 'varchar(255)', 'null' => true },
    { 'name' => 'tagger_id', 'type' => 'integer', 'sql_type' => 'int(11)', 'null' => true },
    { 'name' => 'context', 'type' => 'string', 'sql_type' => 'varchar(128)', 'null' => true },
    { 'name' => 'created_at', 'type' => 'datetime', 'sql_type' => 'datetime', 'null' => true }
  ].freeze
  TIME = '2021-03-04T05:06:07.000000Z'

  module_function

  # Two root projects (alpha with a child, beta), wiki pages with the same
  # title in two projects, items whose CSID is renumbered or repeated across
  # trees, and an AD item that the plan absorbs into a document.
  def base_tables
    {
      'trackers' => [{ 'id' => 1, 'name' => 'csInfo' }, { 'id' => 2, 'name' => 'rq' }],
      'issue_statuses' => [{ 'id' => 1, 'name' => 'csNone', 'is_closed' => false }],
      'users' => [{ 'id' => 1, 'type' => 'User', 'login' => 'author', 'firstname' => 'A', 'lastname' => 'B', 'admin' => false,
                    'status' => 1 }],
      'projects' => [
        { 'id' => 1, 'identifier' => 'alpha', 'name' => 'Alpha', 'parent_id' => nil, 'lft' => 1, 'rgt' => 4, 'status' => 1, 'is_public' => true },
        { 'id' => 2, 'identifier' => 'alpha-sub', 'name' => 'Alpha sub', 'parent_id' => 1, 'lft' => 2, 'rgt' => 3, 'status' => 1, 'is_public' => true },
        { 'id' => 3, 'identifier' => 'beta', 'name' => 'Beta', 'parent_id' => nil, 'lft' => 5, 'rgt' => 6, 'status' => 1, 'is_public' => true }
      ],
      'cosmosys_projects' => [{ 'id' => 1, 'project_id' => 1, 'prefix' => 'ALP' }, { 'id' => 2, 'project_id' => 2, 'prefix' => 'SUB' },
                              { 'id' => 3, 'project_id' => 3, 'prefix' => 'BET' }],
      'issues' => [
        issue(1, 1, 1, 'Chapter'), issue(2, 1, 1, 'Second'), issue(3, 2, 1, 'Sub item'),
        issue(4, 3, 1, 'Beta item'), issue(5, 1, 2, 'AD 1'), issue(6, 1, 1, 'Without CSID'), issue(7, 3, 1, 'Repeated')
      ],
      'cosmosys_issues' => [
        { 'id' => 1, 'issue_id' => 1, 'identifier' => 'ALP-0001', 'chapter_order' => 1 },
        { 'id' => 2, 'issue_id' => 2, 'identifier' => 'ALP-0002', 'chapter_order' => 2 },
        { 'id' => 3, 'issue_id' => 3, 'identifier' => 'SUB-0001', 'chapter_order' => 1 },
        { 'id' => 4, 'issue_id' => 4, 'identifier' => 'ALP-0001', 'chapter_order' => 1 },
        { 'id' => 5, 'issue_id' => 5, 'identifier' => 'ALP-0005', 'chapter_order' => 3 },
        { 'id' => 6, 'issue_id' => 6, 'identifier' => nil, 'chapter_order' => 4 },
        { 'id' => 7, 'issue_id' => 7, 'identifier' => 'ALP-0001', 'chapter_order' => 2 }
      ],
      'wikis' => [{ 'id' => 1, 'project_id' => 1, 'start_page' => 'Wiki' }, { 'id' => 2, 'project_id' => 3, 'start_page' => 'Wiki' }],
      'wiki_pages' => [
        { 'id' => 1, 'wiki_id' => 1, 'title' => 'Wiki', 'created_on' => TIME, 'protected' => false, 'parent_id' => nil },
        { 'id' => 2, 'wiki_id' => 2, 'title' => 'Wiki', 'created_on' => TIME, 'protected' => false, 'parent_id' => nil },
        { 'id' => 3, 'wiki_id' => 1, 'title' => 'Untagged_page', 'created_on' => TIME, 'protected' => false, 'parent_id' => nil }
      ]
    }
  end

  def issue(id, project_id, tracker_id, subject)
    { 'id' => id, 'project_id' => project_id, 'tracker_id' => tracker_id, 'status_id' => 1, 'subject' => subject,
      'description' => '', 'parent_id' => nil, 'author_id' => 1, 'created_on' => TIME, 'updated_on' => TIME }
  end

  # Writes a legacy snapshot directory. A table is either an Array of rows
  # (columns guessed from the values) or { columns:, rows: }.
  def legacy(directory, tables, settings: { 'text_formatting' => 'common_mark' }, redactions: [], plugins: nil)
    writer = LS::Writer.new(directory)
    tables.each do |name, spec|
      columns, rows = spec.is_a?(Hash) ? [spec.fetch(:columns), spec.fetch(:rows)] : [guess_columns(spec), spec]
      names = columns.map { |column| column['name'] }
      primary_key = names.include?('id') ? ['id'] : []
      order_by = primary_key.empty? ? names : primary_key
      rows = rows.map { |row| names.to_h { |column| [column, row[column]] } }
                 .sort_by { |row| LS::Values.row_sort_key(row, order_by) }
      writer.write_table(name, columns: columns, primary_key: primary_key, order_by: order_by) do |emit|
        rows.each { |row| emit.call(row) }
      end
    end
    writer.write_report_rows('redactions', redactions)
    inventory = { 'plugins' => plugins || [{ 'id' => 'additional_tags', 'version' => '1.0.4', 'name' => 'x', 'directory' => 'x' },
                                           { 'id' => 'additionals', 'version' => '3.0.5.2', 'name' => 'x', 'directory' => 'x' }] }
    writer.write_report_document('inventory', inventory)
    writer.finish!(captured_at: TIME, generator: { 'name' => 'test', 'version' => '0' },
                   source: { 'label' => 'test', 'redmine_version' => '4.2.10', 'settings' => settings },
                   consistency: { 'mode' => 'none' })
    directory
  end

  def guess_columns(rows)
    names = rows.flat_map(&:keys).uniq
    names.map do |name|
      sample = rows.map { |row| row[name] }.compact.first
      type = case sample
             when Integer then 'integer'
             when true, false then 'boolean'
             when Hash then 'string'
             else name.end_with?('_on', '_at') ? 'datetime' : 'text'
             end
      { 'name' => name, 'type' => type, 'sql_type' => type, 'null' => true }
    end
  end

  # Yields [source, plan, report] for a synthetic snapshot.
  def with_plan(tables, **options)
    Dir.mktmpdir('converter-fixture') do |tmp|
      path = legacy(File.join(tmp, 'legacy'), tables, **options)
      Converter::Source.open(path) do |source|
        report = Converter::Report.new
        plan = Converter::Plan.new(source, report).build!
        yield source, plan, report, tmp
      end
    end
  end
end
