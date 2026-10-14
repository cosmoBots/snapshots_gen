# frozen_string_literal: true

# Writer and verifier of the legacy snapshot format, version 1
# (docs/legacy-snapshot-format.md).
#
# This file runs on both sides of a migration: inside an old instance under
# Ruby 2.7 and rubyzip 2.3, and in the converter under a current Ruby and
# rubyzip 3. Keep it to syntax and APIs that both understand.

require 'base64'
require 'bigdecimal'
require 'date'
require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'securerandom'
require 'set'
require 'time'
require 'tmpdir'

module SnapshotsGen
  module LegacySnapshot
    SCHEMA = 'cosmosys-legacy-snapshot'
    SCHEMA_VERSION = '1'
    # The converter's history package uses the same container.
    HISTORY_SCHEMA = 'snapshots_gen-history'
    SUPPORTED_SCHEMAS = { SCHEMA => ['1'], HISTORY_SCHEMA => ['1'] }.freeze
    MANIFEST_PATH = 'manifest.json'
    ASSET_INDEX_PATH = 'assets/index.jsonl'
    ASSET_PATTERN = %r{\Aassets/sha256/[0-9a-f]{64}\z}.freeze
    TABLE_NAME_PATTERN = /\A[A-Za-z0-9_]+\z/.freeze
    REPORT_NAME_PATTERN = /\A[a-z0-9_]+\z/.freeze
    ASSET_STATUSES = %w[present missing unreadable].freeze

    class Error < StandardError; end

    module CanonicalJson
      module_function

      def generate(value)
        JSON.generate(normalize(value))
      end

      def normalize(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, child), result| result[key.to_s] = normalize(child) }
               .sort.to_h
        when Array
          value.map { |child| normalize(child) }
        when Time
          value.utc.iso8601(6)
        when DateTime
          value.to_time.utc.iso8601(6)
        when Date
          value.iso8601
        when BigDecimal
          value.to_s('F')
        else
          value
        end
      end
    end

    # Encoding of database values by the Rails abstract type of their column.
    module Values
      module_function

      # Returns [encoded value, problem]. The problem is nil, or :invalid_utf8
      # when a textual value had to be kept as raw bytes.
      def encode(value, type)
        return [nil, nil] if value.nil?

        case type.to_s
        when 'binary'
          [{ '$base64' => Base64.strict_encode64(value.to_s.b) }, nil]
        when 'boolean'
          [boolean(value), nil]
        when 'integer', 'bigint'
          [Integer(value), nil]
        when 'float'
          [Float(value), nil]
        when 'decimal'
          [BigDecimal(value.to_s).to_s('F'), nil]
        when 'datetime', 'timestamp'
          [datetime(value), nil]
        when 'date'
          [value.respond_to?(:iso8601) ? value.to_date.iso8601 : Date.parse(value.to_s).iso8601, nil]
        when 'time'
          [value.respond_to?(:strftime) ? value.strftime('%H:%M:%S') : value.to_s, nil]
        else
          text(value)
        end
      end

      def boolean(value)
        return value if value == true || value == false
        return value.to_i != 0 if value.is_a?(Numeric)

        %w[1 t true y yes].include?(value.to_s.strip.downcase)
      end

      def datetime(value)
        time = case value
               when Time then value
               when DateTime then value.to_time
               else Time.parse("#{value} UTC")
               end
        time.utc.iso8601(6)
      end

      def text(value)
        string = value.to_s
        utf8 = string.dup.force_encoding(Encoding::UTF_8)
        return [utf8, nil] if utf8.valid_encoding?

        [{ '$base64' => Base64.strict_encode64(string.b) }, :invalid_utf8]
      end

      # Total order used by order_by (see the format document).
      def sort_key(value)
        case value
        when nil then [0, 0]
        when Integer, Float then [1, value]
        when String then [2, value.b]
        when false then [3, 0]
        when true then [3, 1]
        when Hash then [4, value['$base64'].to_s.b]
        else [5, value.to_s.b]
        end
      end

      def row_sort_key(row, columns)
        columns.map { |column| sort_key(row[column]) }
      end
    end

    # JSONL file that hashes and counts what it writes.
    class JsonlFile
      attr_reader :rows

      def initialize(path)
        @path = path
        FileUtils.mkdir_p(File.dirname(path))
        @io = File.open(path, 'wb')
        @digest = Digest::SHA256.new
        @rows = 0
        @bytes = 0
      end

      def <<(object)
        line = CanonicalJson.generate(object) + "\n"
        @io.write(line)
        @digest.update(line)
        @rows += 1
        @bytes += line.bytesize
        self
      end

      def close(relative_path)
        @io.close
        { 'path' => relative_path, 'sha256' => @digest.hexdigest, 'bytes' => @bytes, 'rows' => @rows }
      end
    end

    class Writer
      attr_reader :directory

      def initialize(directory, schema: SCHEMA, schema_version: SCHEMA_VERSION)
        @schema = schema
        @schema_version = schema_version
        @directory = directory.to_s
        raise Error, "#{@directory} already exists" if File.exist?(@directory)

        FileUtils.mkdir_p(File.join(@directory, 'assets', 'sha256'))
        @tables = []
        @reports = []
        @asset_index = nil
        @blobs = {}
      end

      # Yields a callable that takes one row (a Hash keyed by column name).
      def write_table(name, columns:, primary_key:, order_by:, redacted_columns: [])
        raise Error, "invalid table name #{name.inspect}" unless name.to_s.match?(TABLE_NAME_PATTERN)

        names = columns.map { |column| column.fetch('name') }
        expected = names.sort
        relative = "tables/#{name}.jsonl"
        file = JsonlFile.new(File.join(directory, relative))
        begin
          yield(lambda do |row|
            unless row.keys.map(&:to_s).sort == expected
              raise Error, "row of #{name} does not match its columns: #{row.keys.inspect}"
            end

            file << row
          end)
        ensure
          entry = file.close(relative)
        end
        @tables << entry.merge(
          'name' => name.to_s,
          'columns' => columns,
          'primary_key' => primary_key,
          'order_by' => order_by,
          'redacted_columns' => redacted_columns.sort
        )
        entry
      end

      # Copies a file into the asset store. Returns [sha256, bytes].
      def add_asset(source_path)
        temporary = File.join(directory, 'assets', ".incoming-#{SecureRandom.hex(8)}")
        digest = Digest::SHA256.new
        bytes = 0
        File.open(source_path, 'rb') do |input|
          File.open(temporary, 'wb') do |output|
            while (chunk = input.read(1024 * 1024))
              digest.update(chunk)
              output.write(chunk)
              bytes += chunk.bytesize
            end
          end
        end
        hex = digest.hexdigest
        target = File.join(directory, 'assets', 'sha256', hex)
        if File.exist?(target)
          File.delete(temporary)
        else
          File.rename(temporary, target)
          @blobs[hex] = bytes
        end
        [hex, bytes]
      ensure
        File.delete(temporary) if temporary && File.exist?(temporary)
      end

      def write_asset_index(rows)
        file = JsonlFile.new(File.join(directory, ASSET_INDEX_PATH))
        rows.sort_by { |row| row.fetch('attachment_id') }.each { |row| file << row }
        @asset_index = file.close(ASSET_INDEX_PATH)
      end

      def write_report_rows(name, rows)
        raise Error, "invalid report name #{name.inspect}" unless name.to_s.match?(REPORT_NAME_PATTERN)

        relative = "reports/#{name}.jsonl"
        file = JsonlFile.new(File.join(directory, relative))
        rows.each { |row| file << row }
        @reports << file.close(relative).merge('name' => name.to_s)
      end

      def write_report_document(name, document)
        raise Error, "invalid report name #{name.inspect}" unless name.to_s.match?(REPORT_NAME_PATTERN)

        relative = "reports/#{name}.json"
        content = CanonicalJson.generate(document) + "\n"
        File.open(File.join(directory, relative).tap { |path| FileUtils.mkdir_p(File.dirname(path)) }, 'wb') do |io|
          io.write(content)
        end
        @reports << { 'name' => name.to_s, 'path' => relative,
                      'sha256' => Digest::SHA256.hexdigest(content), 'bytes' => content.bytesize }
      end

      def finish!(captured_at:, generator:, source:, consistency:, excluded_tables: [], extra: {})
        write_asset_index([]) unless @asset_index
        content = extra.merge(
          'captured_at' => captured_at,
          'generator' => generator,
          'source' => source,
          'consistency' => consistency,
          'tables' => @tables.sort_by { |entry| entry.fetch('name') },
          'excluded_tables' => excluded_tables.sort_by { |entry| entry.fetch('name') },
          'assets' => { 'index' => @asset_index, 'count' => @blobs.length, 'bytes' => @blobs.values.sum },
          'reports' => @reports.sort_by { |entry| entry.fetch('name') }
        )
        normalized = CanonicalJson.normalize(content)
        manifest = {
          'schema' => @schema,
          'schema_version' => @schema_version,
          'content_sha256' => Digest::SHA256.hexdigest(CanonicalJson.generate(normalized)),
          'content' => normalized
        }
        File.open(File.join(directory, MANIFEST_PATH), 'wb') { |io| io.write(CanonicalJson.generate(manifest)) }
        manifest
      end

      # Packs a finished directory into a ZIP archive. Requires rubyzip.
      def self.zip_directory(directory, target)
        require 'zip'
        raise Error, "#{target} already exists" if File.exist?(target)

        files = []
        Find.find(directory) do |path|
          next if File.directory?(path)

          files << path.delete_prefix("#{directory}/")
        end
        Zip::OutputStream.open(target) do |zip|
          files.sort.each do |relative|
            zip.put_next_entry(relative)
            File.open(File.join(directory, relative), 'rb') { |input| IO.copy_stream(input, zip) }
          end
        end
        target
      end
    end

    class Verifier
      Result = Struct.new(:errors, :manifest) do
        def ok?
          errors.empty?
        end
      end

      def initialize(path)
        @path = path.to_s
      end

      def verify
        if File.directory?(@path)
          verify_directory(@path)
        else
          Dir.mktmpdir('snapshots_gen-verify') do |directory|
            errors = extract_zip(@path, directory)
            return Result.new(errors, nil) if errors.any?

            verify_directory(directory)
          end
        end
      rescue Error, JSON::ParserError, SystemCallError => error
        Result.new(["#{error.class}: #{error.message}"], nil)
      end

      private

      def extract_zip(path, directory)
        require 'zip'
        errors = []
        names = Set.new
        Zip::File.open(path) do |archive|
          archive.each do |entry|
            name = entry.name
            next if entry.directory?

            if name.start_with?('/') || name.split('/').include?('..') || name.include?('\\')
              errors << "unsafe entry name #{name.inspect}"
              next
            end
            errors << "symbolic link #{name.inspect}" if entry.symlink?
            errors << "duplicate entry #{name.inspect}" unless names.add?(name)
            next if errors.any?

            target = File.join(directory, name)
            FileUtils.mkdir_p(File.dirname(target))
            entry.get_input_stream { |input| File.open(target, 'wb') { |output| IO.copy_stream(input, output) } }
          end
        end
        errors
      end

      def verify_directory(directory)
        errors = []
        manifest_path = File.join(directory, MANIFEST_PATH)
        return Result.new(['manifest.json is missing'], nil) unless File.file?(manifest_path)

        raw = File.binread(manifest_path)
        manifest = JSON.parse(raw)
        errors << 'manifest.json is not canonical JSON' unless CanonicalJson.generate(manifest) == raw.dup.force_encoding('UTF-8')
        unless SUPPORTED_SCHEMAS.fetch(manifest['schema'], []).include?(manifest['schema_version'].to_s)
          errors << "unsupported schema #{manifest['schema'].inspect} #{manifest['schema_version'].inspect}"
          return Result.new(errors, manifest)
        end
        content = manifest.fetch('content')
        actual = Digest::SHA256.hexdigest(CanonicalJson.generate(content))
        errors << 'content_sha256 does not match the manifest content' unless actual == manifest['content_sha256']

        allowed = Set[MANIFEST_PATH]
        content.fetch('tables').each do |table|
          allowed << table.fetch('path')
          errors.concat(verify_table(directory, table))
        end
        content.fetch('reports').each do |report|
          allowed << report.fetch('path')
          errors.concat(verify_file(directory, report))
        end
        index = content.fetch('assets').fetch('index')
        allowed << index.fetch('path')
        errors.concat(verify_assets(directory, content.fetch('assets'), allowed))

        Find.find(directory) do |path|
          next if File.directory?(path)

          relative = path.delete_prefix("#{directory}/")
          errors << "symbolic link #{relative}" if File.symlink?(path)
          errors << "unexpected entry #{relative}" unless allowed.include?(relative)
        end
        Result.new(errors, manifest)
      end

      def verify_file(directory, entry)
        path = File.join(directory, entry.fetch('path'))
        return ["#{entry['path']} is missing"] unless File.file?(path)

        errors = []
        errors << "#{entry['path']} has a different SHA-256" unless Digest::SHA256.file(path).hexdigest == entry['sha256']
        errors << "#{entry['path']} has a different size" unless File.size(path) == entry['bytes']
        if entry.key?('rows')
          lines = 0
          File.foreach(path) { lines += 1 }
          errors << "#{entry['path']} has #{lines} lines, expected #{entry['rows']}" unless lines == entry['rows']
        end
        errors
      end

      def verify_table(directory, table)
        errors = verify_file(directory, table)
        return errors if errors.any?

        names = table.fetch('columns').map { |column| column.fetch('name') }
        expected = names.sort
        order_by = table.fetch('order_by')
        primary_key = table.fetch('primary_key')
        unknown = (order_by + primary_key + table.fetch('redacted_columns')) - names
        errors << "#{table['name']} refers to unknown columns #{unknown.join(', ')}" if unknown.any?
        return errors if unknown.any?

        previous = nil
        keys = Set.new
        File.foreach(File.join(directory, table.fetch('path')), encoding: 'UTF-8').with_index(1) do |line, number|
          row = JSON.parse(line)
          location = "#{table['path']}:#{number}"
          unless row.is_a?(Hash) && CanonicalJson.generate(row) + "\n" == line
            errors << "#{location} is not a canonical JSON object"
            next
          end
          errors << "#{location} does not match the declared columns" unless row.keys.sort == expected
          key = Values.row_sort_key(row, order_by)
          errors << "#{location} is out of order" if previous && (previous <=> key) == 1
          previous = key
          next if primary_key.empty?

          errors << "#{location} repeats its primary key" unless keys.add?(primary_key.map { |column| row[column] })
        end
        errors
      end

      def verify_assets(directory, assets, allowed)
        index = assets.fetch('index')
        errors = verify_file(directory, index)
        return errors if errors.any?

        referenced = Set.new
        File.foreach(File.join(directory, index.fetch('path')), encoding: 'UTF-8').with_index(1) do |line, number|
          row = JSON.parse(line)
          location = "#{index['path']}:#{number}"
          unless ASSET_STATUSES.include?(row['status'])
            errors << "#{location} has an unknown status #{row['status'].inspect}"
            next
          end
          next unless row['status'] == 'present'

          digest = row['sha256'].to_s
          relative = "assets/sha256/#{digest}"
          unless relative.match?(ASSET_PATTERN)
            errors << "#{location} has an invalid SHA-256"
            next
          end
          referenced << digest
          allowed << relative
          blob = File.join(directory, relative)
          errors << "#{location} has a different size than its blob" if File.file?(blob) && File.size(blob) != row['bytes']
        end
        blobs = Dir.glob(File.join(directory, 'assets', 'sha256', '*')).sort
        blobs.each do |path|
          digest = File.basename(path)
          relative = "assets/sha256/#{digest}"
          next unless relative.match?(ASSET_PATTERN)

          errors << "#{relative} is not referenced by the index" unless referenced.include?(digest)
          errors << "#{relative} does not match its SHA-256" unless Digest::SHA256.file(path).hexdigest == digest
          allowed << relative if referenced.include?(digest)
        end
        referenced.each do |digest|
          errors << "assets/sha256/#{digest} is missing" unless File.file?(File.join(directory, 'assets', 'sha256', digest))
        end
        sizes = blobs.select { |path| referenced.include?(File.basename(path)) }.map { |path| File.size(path) }
        errors << 'assets count does not match the blobs' unless assets.fetch('count') == sizes.length
        errors << 'assets bytes do not match the blobs' unless assets.fetch('bytes') == sizes.sum
        errors
      end
    end
  end
end
