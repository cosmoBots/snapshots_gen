# frozen_string_literal: true

# snapshots_gen importer: runs in the new cosmoSys instance with rails runner.
#
#   rails runner import.rb prepare HISTORY.cshistory
#       Before the .csys import: creates the missing users (with their
#       password hashes), groups, custom field definitions and time
#       activities, and checks trackers, statuses and roles.
#   rails runner import.rb csys PACKAGE.csys [parent=IDENTIFIER] [confirm=yes]
#       Imports one .csys with the same preflight and materialization as the
#       cosmoSys interface. Without confirm=yes it only prints the preflight.
#   rails runner import.rb history HISTORY.cshistory [dry_run=yes] [roles=old:new,...]
#       After every .csys import and before anyone works in the instance:
#       writes the history and restores authors, dates and memberships, then
#       verifies it, all in one transaction.

require_relative 'history_importer'
require_relative 'silence'

module SnapshotsGen
  module Importer
    module_function

    def main(argv)
      command, path, *rest = argv
      options = rest.each_with_object({}) do |argument, result|
        key, value = argument.split('=', 2)
        raise ArgumentError, "expected key=value, got #{argument.inspect}" if value.nil?

        result[key] = value
      end
      options['dry_run'] = options['dry_run'] == 'yes'
      options['roles'] = options.fetch('roles', '').split(',').to_h { |pair| pair.split(':', 2) }
      raise ArgumentError, 'missing package path' if path.to_s.empty?

      unless %w[prepare csys history].include?(command)
        warn 'usage: import.rb prepare|history HISTORY.cshistory [options] | csys PACKAGE.csys [parent=IDENTIFIER] [confirm=yes]'
        exit 2
      end

      $stdout.sync = true
      User.current = admin
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      summary, report = quiet_log { Silence.run { run(command, path, options) } }
      puts "Time: #{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round} s"
      print_dropped(summary, report) if summary
    rescue Error => error
      warn "error: #{error.message}"
      exit 1
    end

    # Returns the summary of a history import and the path of its report.
    def run(command, path, options)
      case command
      when 'prepare' then Package.open(path) { |package| Run.new(package, options).prepare! }
      when 'csys' then import_csys(path, options)
      when 'history'
        summary = nil
        Package.open(path) { |package| summary = Run.new(package, options).history! }
        report = File.join(File.dirname(File.expand_path(path)), "history-import-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}.json")
        File.write(report, JSON.pretty_generate(summary) + "\n")
        puts "Statistics: #{summary['stats'].map { |key, value| "#{key}=#{value}" }.join(', ')}"
        return [summary, report]
      end
      nil
    end

    # Whatever the importer drops was in the history package: the conversion
    # report did not announce it, so it is said apart, at the very end.
    def print_dropped(summary, report)
      if summary['dropped'].empty?
        puts "Dropped by the importer: none (report: #{report})."
        return
      end
      counts = summary['dropped_counts'].map { |kind, count| "#{kind} #{count}" }.join(', ')
      puts "WARNING: the importer dropped #{summary['dropped'].length} records that the conversion report " \
           "does not announce (#{counts}). They are listed under \"dropped\" in #{report}."
    end

    # cosmoSys logs a progress line every second and Rails logs every job and
    # attachment, burying the importer's own lines: while it runs, only
    # warnings and errors reach the log.
    def quiet_log
      loggers = [Rails.logger, ActiveRecord::Base.logger, ActiveJob::Base.logger, ActionMailer::Base.logger].compact.uniq
      levels = loggers.map(&:level)
      loggers.each { |logger| logger.level = Logger::WARN }
      yield
    ensure
      loggers&.zip(levels)&.each { |logger, level| logger.level = level }
    end

    # One line when a phase of the materialization starts and one every
    # 30 seconds within a long phase; some phases report nothing for minutes,
    # so a line also comes after a minute without any. A large package must
    # not look hung.
    def with_progress
      clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      started = clock.call
      state = { phase: nil, percent: 0, at: -Float::INFINITY }
      line = ->(text) { puts format('  [%3d%%] %s (%d s)', state[:percent], text, (clock.call - started).round) }
      printer = lambda do |percent, phase, details|
        next if phase == state[:phase] && clock.call - state[:at] < 30

        state.update(phase: phase, percent: percent.to_i, at: clock.call)
        line.call(details[:total] ? "#{phase} #{details[:processed].to_i}/#{details[:total]}" : phase.to_s)
      end
      heartbeat = Thread.new do
        loop do
          sleep 5
          next if state[:phase].nil? || clock.call - state[:at] < 60

          state[:at] = clock.call
          line.call("#{state[:phase]}, still working")
        end
      end
      yield printer
    ensure
      heartbeat&.kill
    end

    def admin
      User.active.where(admin: true).order(:id).first || raise(Error, 'the instance has no active administrator')
    end

    # The same attributes the interface sends (ProjectSnapshotsController),
    # keeping every source identifier.
    def import_csys(path, options)
      # The materialization saves items through their models: Silence keeps
      # their notifications from being queued.
      Cosmosys::ProjectSnapshotPackageReader.open(path) do |source|
        content = source.manifest.fetch('content')
        primary = content.fetch('projects').find { |entry| entry.fetch('source_id') == content.fetch('primary_project_source_id') }
        parent = options['parent'] && Project.find_by!(identifier: options['parent'])
        attributes = {
          'name' => primary.dig('project', 'name'), 'identifier' => primary.dig('project', 'identifier'),
          'cscode' => primary.dig('project', 'cscode'), 'parent_id' => parent&.id&.to_s,
          'identity_mode' => 'preserve', 'project_data_conflict_policy' => 'cancel',
          'primary_source_id' => primary.fetch('source_id').to_s, 'allow_multiple_roots' => '1',
          'project_identifiers' => content.fetch('projects').to_h { |entry| [entry.fetch('source_id').to_s, entry.dig('project', 'identifier')] }
        }
        plan = Cosmosys::ProjectSnapshotMaterializationPlan.new(source: source, attributes: attributes, user: admin)
        puts "Package: #{File.basename(path)} (#{content.fetch('projects').length} projects)"
        plan.counts.each { |key, value| puts "  #{key}: #{value}" }
        { 'missing trackers' => plan.missing_trackers, 'missing custom fields' => plan.missing_custom_fields,
          'missing assets' => plan.missing_assets }.each do |label, values|
          puts "  #{label}: #{values.join(', ')}" if values.any?
        end
        plan.plugin_warnings.each { |warning| puts "  plugin #{warning[:id]}: #{warning[:status]}" }
        # Shown by cosmoSys versions whose preflight reports them.
        if plan.respond_to?(:custom_field_creations)
          plan.custom_field_creations.each { |entry| puts "  custom field to create: #{entry['name']} (#{entry['format']})" }
        end
        if plan.respond_to?(:fallback_warnings)
          plan.fallback_warnings.each { |entry| puts "  WARNING #{entry[:kind]}: #{entry[:value]} (#{entry[:items]} items)" }
        end
        if plan.blocking_messages.any?
          plan.blocking_messages.each { |message| puts "  BLOCKING: #{message}" }
          raise Error, 'the preflight blocks this package'
        end
        unless options['confirm'] == 'yes'
          puts 'Preflight passed. Run again with confirm=yes to import.'
          return
        end
        options = {}
        parameters = Cosmosys::ProjectSnapshotMaterializer.instance_method(:initialize).parameters.map(&:last)
        # Not :snapshot, as the interface: with :snapshot cosmoSys Requirements
        # captures the approved presentation baselines here, before the
        # history import completes cross-package references and relations.
        # The history import captures them at its end.
        options[:purpose] = :materialization if parameters.include?(:purpose)
        project = with_progress do |printer|
          # cosmoSys versions that report progress take a callback.
          options[:progress] = printer if parameters.include?(:progress)
          Cosmosys::ProjectSnapshotMaterializer.new(source, user: admin, attributes: attributes, **options).call
        end
        tree = Project.find(project.id).self_and_descendants.pluck(:id)
        puts "Imported #{project.identifier}: #{tree.length} projects, #{Issue.where(project_id: tree).count} items."
      end
    end
  end
end

SnapshotsGen::Importer.main(ARGV)
