# frozen_string_literal: true

# Files of the Files module (attachments of a project or of one of its
# versions) travel in the history package, with their file, for the history
# importer to create; attachments that belong to nothing are not migrated and
# are reported. Every name and text is invented.

require 'minitest/autorun'
require_relative 'converter_snapshot_helper'

class ConverterProjectFilesTest < Minitest::Test
  include ConverterSnapshotHelper

  def attachment(id, type, container_id, filename)
    { 'id' => id, 'container_type' => type, 'container_id' => container_id, 'filename' => filename,
      'disk_filename' => "#{id}_#{filename}", 'filesize' => 3, 'digest' => 'x', 'author_id' => 1,
      'created_on' => TIME, 'description' => "About #{filename}", 'downloads' => 4, 'content_type' => 'application/pdf' }
  end

  # 1 and 2 are files of the project and of its version 5; 3 was uploaded
  # and never attached; 4 belonged to an item deleted from the source; 6 is
  # an item's.
  def tables
    base_tables([issue(1)]).merge(
      'versions' => [{ 'id' => 5, 'project_id' => 1, 'name' => 'v1', 'status' => 'open', 'sharing' => 'none' }],
      'attachments' => [attachment(1, 'Project', 1, 'plan.pdf'), attachment(2, 'Version', 5, 'release.pdf'),
                        attachment(3, nil, nil, 'pasted.png'), attachment(4, 'Issue', 99, 'old.png'),
                        attachment(6, 'Issue', 1, 'item.png')]
    )
  end

  def test_project_and_version_files_are_migrated_with_the_history
    convert(tables, attachment_files: [1, 2, 3, 4, 6]) do |entities, report, plan|
      assert_equal({ 1 => ['project', 1, 0], 2 => ['version', 5, 0] }, plan.project_files)
      rows = entities.fetch('attachments').to_h { |row| [row['id'], row] }
      assert_equal ['project', 1, 0, true, 'application/pdf', 3], rows.fetch(1).values_at('container', 'container_key', 'ordinal', 'migrated', 'content_type', 'bytes')
      assert_equal ['version', 5, 0, true], rows.fetch(2).values_at('container', 'container_key', 'ordinal', 'migrated')
      assert_equal [4, 'About plan.pdf'], rows.fetch(1).values_at('downloads', 'description')
      refute rows.fetch(3)['migrated']
      refute rows.fetch(4)['migrated']

      codes = report.entries.group_by { |entry| entry['code'] }
      assert_equal [['attachment #1', { 'project' => 'alpha', 'version' => nil }], ['attachment #2', { 'project' => 'alpha', 'version' => 'v1' }]],
                   codes.fetch('project_file_migrated').map { |entry| [entry['subject'], entry['detail']] }.sort
      assert_equal [['attachment #3', 'no container'], ['attachment #4', 'Issue #99 is not in the source']],
                   codes.fetch('attachment_without_container').map { |entry| [entry['subject'], entry.dig('detail', 'reason')] }
      refute(report.entries.any? { |entry| entry['code'] == 'unsupported_content' && entry['subject'].to_s.start_with?('attachments of') })
    end
  end

  def test_the_history_package_carries_their_files
    Dir.mktmpdir('project-files') do |tmp|
      Converter::Source.open(legacy(File.join(tmp, 'legacy'), tables, attachment_files: [1, 2, 6])) do |source|
        plan = Converter::Plan.new(source, Converter::Report.new).build!
        Converter::HistoryBuilder.new(plan, csys_packages: []).write(File.join(tmp, 'history'))
        result = LS::Verifier.new(File.join(tmp, 'history')).verify
        assert result.ok?, result.errors.join('; ')
        index = File.foreach(File.join(tmp, 'history', 'assets', 'index.jsonl')).map { |line| JSON.parse(line) }
        assert_equal [1, 2], index.map { |row| row['attachment_id'] }
        assert(index.all? { |row| File.binread(File.join(tmp, 'history', 'assets', 'sha256', row['sha256'])) == 'abc' })
      end
    end
  end
end
