# frozen_string_literal: true

require 'digest'
require 'set'

module SnapshotsGen
  module Converter
    # Checks a .csys manifest for what the cosmoSys import would reject
    # regardless of the destination: digest, keys, hierarchy, identities and
    # references inside the package.
    class CsysCheck
      PROFILES = %w[items requirements poris].freeze

      def initialize(manifest)
        @manifest = manifest
      end

      def errors
        errors = []
        content = @manifest.fetch('content')
        digest = Digest::SHA256.hexdigest(LegacySnapshot::CanonicalJson.generate(content))
        errors << 'content_sha256 does not match' unless digest == @manifest['content_sha256']
        projects = content.fetch('projects')
        project_keys = projects.map { |entry| entry.fetch('key') }
        errors << 'repeated project keys' unless project_keys.uniq.length == project_keys.length
        roots = projects.select { |entry| entry['parent_key'].nil? || !project_keys.include?(entry['parent_key']) }
        errors << "#{roots.length} top-level projects; the import needs exactly one per package" unless roots.one?
        codes = projects.map { |entry| entry.dig('project', 'cscode').to_s.downcase }
        errors << 'repeated project codes' unless codes.uniq.length == codes.length
        identifiers = projects.map { |entry| entry.dig('project', 'identifier') }
        errors << 'repeated project identifiers' unless identifiers.uniq.length == identifiers.length
        projects.each do |entry|
          profile = entry.dig('project', 'profile')
          errors << "#{entry['key']}: unknown profile #{profile}" unless PROFILES.include?(profile)
        end
        items = projects.flat_map { |entry| entry.fetch('items') }
        keys = items.map { |row| row.fetch('key') }.to_set
        errors << 'repeated item keys' unless keys.length == items.length
        csids = items.map { |row| row['csid'].to_s.downcase }
        repeated = csids.group_by(&:itself).select { |_csid, rows| rows.length > 1 }.keys
        errors << "repeated CSIDs: #{repeated.first(10).join(', ')}" if repeated.any?
        by_key = items.to_h { |row| [row.fetch('key'), row] }
        items.each do |row|
          parent = row['parent_key']
          next unless parent

          unless keys.include?(parent)
            errors << "#{row['key']}: parent #{parent} is not in the package"
            next
          end
          profile = by_key.fetch(parent).dig('tracker', 'item_profile')
          if %w[requirement doc negative datum].include?(profile)
            errors << "#{row['key']}: parent #{parent} (#{profile}) cannot have children"
          end
          child_profile = row.dig('tracker', 'item_profile')
          if %w[requirement doc negative].include?(child_profile) && profile != 'info'
            errors << "#{row['key']}: a #{child_profile} needs an info chapter as parent, not #{profile || 'normal'}"
          end
        end
        content.fetch('relations').each do |relation|
          %w[from to].each do |side|
            errors << "relation #{side} #{relation[side]} is not in the package" unless keys.include?(relation[side])
          end
        end
        documents = projects.flat_map { |entry| entry.fetch('documents').map { |row| row.fetch('key') } }.to_set
        projects.each do |entry|
          entry.fetch('document_catalog').each do |catalog|
            errors << "catalog document #{catalog['document_key']} is not in the package" unless documents.include?(catalog['document_key'])
            catalog.fetch('references').each do |reference|
              errors << "catalog reference to #{reference['item']}, not in the package" unless keys.include?(reference['item'])
            end
          end
        end
        errors
      end
    end
  end
end
