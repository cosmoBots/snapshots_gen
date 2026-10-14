# frozen_string_literal: true

require 'json'
require 'tmpdir'
require 'zip'
require_relative '../../../../exporter/legacy_snapshot_format'

module SnapshotsGen
  module Converter
    class Error < StandardError; end

    # A verified legacy snapshot, unpacked into a temporary directory, with its
    # tables decoded back into Ruby values.
    class Source
      attr_reader :manifest, :directory

      def self.open(path)
        Dir.mktmpdir('snapshots_gen-convert') do |directory|
          source = new(path, directory)
          source.load!
          yield source
        end
      end

      def initialize(path, directory)
        @path = path.to_s
        @directory = directory
        @tables = {}
      end

      def load!
        result = LegacySnapshot::Verifier.new(@path).verify
        raise Error, "the legacy snapshot does not verify: #{result.errors.first(5).join('; ')}" unless result.ok?

        if File.directory?(@path)
          @directory = @path
        else
          Zip::File.open(@path) do |archive|
            archive.each do |entry|
              next if entry.directory?

              target = File.join(@directory, entry.name)
              FileUtils.mkdir_p(File.dirname(target))
              entry.get_input_stream { |input| File.open(target, 'wb') { |output| IO.copy_stream(input, output) } }
            end
          end
        end
        @manifest = result.manifest
        self
      end

      def content
        manifest.fetch('content')
      end

      def label
        content.dig('source', 'label').to_s
      end

      def table?(name)
        content.fetch('tables').any? { |table| table.fetch('name') == name }
      end

      # Rows of a table as Hashes. Binary values are decoded to binary strings;
      # text that was not valid UTF-8 stays as raw bytes.
      def table(name)
        @tables[name] ||= begin
          entry = content.fetch('tables').find { |table| table.fetch('name') == name }
          if entry
            path = File.join(directory, entry.fetch('path'))
            File.foreach(path, encoding: 'UTF-8').map { |line| decode(JSON.parse(line)) }
          else
            []
          end
        end
      end

      def report_rows(name)
        entry = content.fetch('reports').find { |report| report.fetch('name') == name }
        return [] unless entry

        File.foreach(File.join(directory, entry.fetch('path')), encoding: 'UTF-8').map { |line| JSON.parse(line) }
      end

      def inventory
        entry = content.fetch('reports').find { |report| report.fetch('name') == 'inventory' }
        entry ? JSON.parse(File.read(File.join(directory, entry.fetch('path')))) : {}
      end

      def asset_index
        @asset_index ||= File.foreach(File.join(directory, LegacySnapshot::ASSET_INDEX_PATH), encoding: 'UTF-8')
                             .map { |line| JSON.parse(line) }.to_h { |row| [row.fetch('attachment_id'), row] }
      end

      def asset_path(digest)
        File.join(directory, 'assets', 'sha256', digest)
      end

      private

      def decode(row)
        row.each do |key, value|
          row[key] = Base64.strict_decode64(value.fetch('$base64')) if value.is_a?(Hash) && value.key?('$base64')
        end
        row
      end
    end
  end
end
