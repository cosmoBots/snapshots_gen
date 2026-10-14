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

      User.current = admin
      case command
      when 'prepare' then Package.open(path) { |package| Run.new(package, options).prepare! }
      when 'csys' then import_csys(path, options)
      when 'history'
        summary = nil
        Package.open(path) { |package| summary = Run.new(package, options).history! }
        report = File.join(File.dirname(File.expand_path(path)), "history-import-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}.json")
        File.write(report, JSON.pretty_generate(summary) + "\n")
        puts "Statistics: #{summary['stats'].map { |key, value| "#{key}=#{value}" }.join(', ')}"
        puts "Dropped: #{summary['dropped'].length} (see #{report})"
      else
        warn 'usage: import.rb prepare|history HISTORY.cshistory [options] | csys PACKAGE.csys [parent=IDENTIFIER] [confirm=yes]'
        exit 2
      end
    rescue Error => error
      warn "error: #{error.message}"
      exit 1
    end

    def admin
      User.active.where(admin: true).order(:id).first || raise(Error, 'the instance has no active administrator')
    end

    # The same attributes the interface sends (ProjectSnapshotsController),
    # keeping every source identifier.
    def import_csys(path, options)
      # The materialization saves items through their models; nobody must be
      # notified of a migration.
      ActionMailer::Base.perform_deliveries = false
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
        if plan.blocking_messages.any?
          plan.blocking_messages.each { |message| puts "  BLOCKING: #{message}" }
          raise Error, 'the preflight blocks this package'
        end
        unless options['confirm'] == 'yes'
          puts 'Preflight passed. Run again with confirm=yes to import.'
          return
        end
        project = Cosmosys::ProjectSnapshotMaterializer.new(source, user: admin, attributes: attributes).call
        puts "Imported #{project.identifier} with #{Issue.where(project_id: project.self_and_descendants.select(:id)).count} items."
      end
    end
  end
end

SnapshotsGen::Importer.main(ARGV)
