# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../exporter/legacy_snapshot_format'

class LegacySnapshotFormatTest < Minitest::Test
  LS = SnapshotsGen::LegacySnapshot

  COLUMNS = [
    { 'name' => 'id', 'type' => 'integer', 'sql_type' => 'int(11)', 'null' => false },
    { 'name' => 'subject', 'type' => 'string', 'sql_type' => 'varchar(255)', 'null' => true }
  ].freeze

  def setup
    @tmp = Dir.mktmpdir('legacy-snapshot-test')
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def finish(writer)
    writer.finish!(
      captured_at: '2026-10-14T00:00:00.000000Z',
      generator: { 'name' => 'test', 'version' => '0' },
      source: { 'label' => 'test' },
      consistency: { 'mode' => 'none' }
    )
  end

  def package(name = 'pkg')
    writer = LS::Writer.new(File.join(@tmp, name))
    yield writer if block_given?
    finish(writer)
    writer.directory
  end

  def errors(path)
    LS::Verifier.new(path).verify.errors
  end

  def test_empty_package_round_trips_through_zip
    directory = package
    assert_empty errors(directory)
    zip = LS::Writer.zip_directory(directory, File.join(@tmp, 'empty.cslegacy'))
    result = LS::Verifier.new(zip).verify
    assert result.ok?, result.errors.inspect
    assert_equal [], result.manifest.fetch('content').fetch('tables')
  end

  def test_package_with_table_asset_and_report
    blob = File.join(@tmp, 'blob.bin')
    File.binwrite(blob, "hello\x00world".b)
    directory = package do |writer|
      writer.write_table('issues', columns: COLUMNS, primary_key: ['id'], order_by: ['id']) do |emit|
        emit.call('id' => 1, 'subject' => 'first')
        emit.call('id' => 2, 'subject' => nil)
      end
      digest, bytes = writer.add_asset(blob)
      again, = writer.add_asset(blob)
      assert_equal digest, again
      writer.write_asset_index([
        { 'attachment_id' => 2, 'sha256' => nil, 'bytes' => nil, 'status' => 'missing' },
        { 'attachment_id' => 1, 'sha256' => digest, 'bytes' => bytes, 'status' => 'present' }
      ])
      writer.write_report_rows('gaps', [{ 'code' => 'attachment_file_missing', 'table' => 'attachments', 'id' => 2, 'detail' => {} }])
      writer.write_report_document('inventory', { 'tables' => { 'issues' => 2 } })
    end
    assert_empty errors(directory)
    zip = LS::Writer.zip_directory(directory, File.join(@tmp, 'full.cslegacy'))
    assert_empty errors(zip)
  end

  def test_tampered_row_is_detected
    directory = package do |writer|
      writer.write_table('issues', columns: COLUMNS, primary_key: ['id'], order_by: ['id']) do |emit|
        emit.call('id' => 1, 'subject' => 'first')
      end
    end
    path = File.join(directory, 'tables/issues.jsonl')
    File.write(path, File.read(path).sub('first', 'FIRST'))
    assert(errors(directory).any? { |error| error.include?('different SHA-256') })
  end

  def test_manifest_edit_is_detected
    directory = package
    path = File.join(directory, 'manifest.json')
    File.write(path, File.read(path).sub('"label":"test"', '"label":"other"'))
    assert_includes errors(directory), 'content_sha256 does not match the manifest content'
  end

  def test_unexpected_and_unreferenced_entries_are_detected
    directory = package
    File.write(File.join(directory, 'tables', 'extra.jsonl').tap { |path| FileUtils.mkdir_p(File.dirname(path)) }, "{}\n")
    blob = File.join(directory, 'assets', 'sha256', Digest::SHA256.hexdigest('x'))
    File.write(blob, 'x')
    found = errors(directory)
    assert(found.any? { |error| error.include?('unexpected entry tables/extra.jsonl') })
    assert(found.any? { |error| error.include?('is not referenced by the index') })
  end

  def test_rows_out_of_order_and_repeated_keys_are_detected
    directory = package do |writer|
      writer.write_table('issues', columns: COLUMNS, primary_key: ['id'], order_by: ['id']) do |emit|
        emit.call('id' => 2, 'subject' => 'b')
        emit.call('id' => 1, 'subject' => 'a')
        emit.call('id' => 1, 'subject' => 'c')
      end
    end
    found = errors(directory)
    assert(found.any? { |error| error.end_with?('is out of order') })
    assert(found.any? { |error| error.end_with?('repeats its primary key') })
  end

  def test_writer_rejects_rows_that_do_not_match_columns
    writer = LS::Writer.new(File.join(@tmp, 'bad'))
    assert_raises(LS::Error) do
      writer.write_table('issues', columns: COLUMNS, primary_key: ['id'], order_by: ['id']) do |emit|
        emit.call('id' => 1)
      end
    end
  end

  def test_value_encoding
    assert_equal [nil, nil], LS::Values.encode(nil, 'string')
    assert_equal [true, nil], LS::Values.encode(1, 'boolean')
    assert_equal [false, nil], LS::Values.encode(0, 'boolean')
    assert_equal ['12.5', nil], LS::Values.encode(BigDecimal('12.50'), 'decimal')
    assert_equal ['2023-04-05T10:11:12.000000Z', nil], LS::Values.encode(Time.utc(2023, 4, 5, 10, 11, 12), 'datetime')
    assert_equal ['2023-04-05T10:11:12.000000Z', nil], LS::Values.encode('2023-04-05 10:11:12', 'datetime')
    assert_equal ['2023-04-05', nil], LS::Values.encode(Date.new(2023, 4, 5), 'date')
    assert_equal [{ '$base64' => 'AAE=' }, nil], LS::Values.encode("\x00\x01".b, 'binary')
    encoded, problem = LS::Values.encode("caf\xE9".b, 'text')
    assert_equal :invalid_utf8, problem
    assert_equal({ '$base64' => Base64.strict_encode64("caf\xE9".b) }, encoded)
    assert_equal ['café', nil], LS::Values.encode('café', 'text')
  end

  def test_sort_key_orders_nulls_first_and_bytes_not_collation
    rows = [{ 'v' => 'b' }, { 'v' => nil }, { 'v' => 'B' }, { 'v' => 'a' }]
    sorted = rows.sort_by { |row| LS::Values.row_sort_key(row, ['v']) }.map { |row| row['v'] }
    assert_equal [nil, 'B', 'a', 'b'], sorted
  end
end
