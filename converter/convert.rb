#!/usr/bin/env ruby
# frozen_string_literal: true

# snapshots_gen converter: turns a legacy snapshot into
#   - one .csys package per root project tree, for the cosmoSys import;
#   - one history package, for the history importer;
#   - a conversion report (JSON and Markdown).
#
#   ruby convert.rb LEGACY.cslegacy OUT_DIR

require 'fileutils'
require 'json'
require 'set'
require_relative 'lib/snapshots_gen/converter/source'
require_relative 'lib/snapshots_gen/converter/report'
require_relative 'lib/snapshots_gen/converter/plan'
require_relative 'lib/snapshots_gen/converter/csys_builder'
require_relative 'lib/snapshots_gen/converter/history_builder'
require_relative 'lib/snapshots_gen/converter/csys_check'

module SnapshotsGen
  module Converter
    module_function

    def run(input, out)
      File.umask(0o077)
      raise Error, "#{out} already exists" if File.exist?(out)

      FileUtils.mkdir_p(out)
      report = Report.new
      summary = nil
      Source.open(input) do |source|
        plan = Plan.new(source, report).build!
        label = source.label.empty? ? 'instance' : source.label
        builder = CsysBuilder.new(plan, captured_at: source.content.fetch('captured_at'))
        packages = plan.roots.map do |root_id|
          identifier = plan.project_identifier(root_id)
          path = File.join(out, "#{label}-#{identifier}.csys")
          manifest = builder.write(root_id, path)
          CsysCheck.new(manifest).errors.each { |error| raise Error, "#{File.basename(path)}: #{error}" }
          content = manifest.fetch('content')
          { 'file' => File.basename(path), 'root_identifier' => identifier, 'content_sha256' => manifest.fetch('content_sha256'),
            'projects' => content.fetch('projects').map { |project| project.dig('project', 'identifier') },
            'items' => content.fetch('projects').sum { |project| project.fetch('items').length } }
        end
        history_dir = File.join(out, ".#{label}.history")
        HistoryBuilder.new(plan, csys_packages: packages).write(history_dir)
        history_path = File.join(out, "#{label}.cshistory")
        LegacySnapshot::Writer.zip_directory(history_dir, history_path)
        FileUtils.rm_rf(history_dir)
        result = LegacySnapshot::Verifier.new(history_path).verify
        raise Error, "the history package does not verify: #{result.errors.first(5).join('; ')}" unless result.ok?

        summary = {
          'source' => File.basename(input), 'label' => label,
          'source_content_sha256' => source.manifest.fetch('content_sha256'),
          'text_formatting' => plan.text_formatting,
          'csys_packages' => packages.map { |package| "#{package['file']} (#{package['items']} items)" },
          'history_package' => File.basename(history_path),
          'journals' => result.manifest.dig('content', 'tables').find { |table| table['name'] == 'journals' }&.fetch('rows'),
          'blocking' => report.blocking?
        }
      end
      File.write(File.join(out, 'report.json'), JSON.pretty_generate(report.to_h(summary)) + "\n")
      File.write(File.join(out, 'report.md'), report.markdown(summary) + "\n")
      summary
    end
  end
end

if $PROGRAM_NAME == __FILE__
  if ARGV.length != 2
    warn 'usage: convert.rb LEGACY.cslegacy OUT_DIR'
    exit 2
  end
  summary = SnapshotsGen::Converter.run(ARGV[0], ARGV[1])
  summary.each { |key, value| puts "#{key}: #{value.is_a?(Array) ? value.join(', ') : value}" }
  puts "Report: #{File.join(ARGV[1], 'report.md')}"
  exit(summary['blocking'] ? 1 : 0)
end
