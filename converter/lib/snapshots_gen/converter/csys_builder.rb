# frozen_string_literal: true

require 'digest'
require 'zip'

module SnapshotsGen
  module Converter
    # Builds one cosmoSys project snapshot (.csys, schema 3) per root project
    # tree, in the shape Cosmosys::ProjectSnapshotCapture writes. The import
    # needs a common parent for several roots, so each tree is its own package.
    class CsysBuilder
      SCHEMA = 'cosmosys-project-snapshot'
      SCHEMA_VERSION = '3'
      REQUIREMENT_TRACKERS = [
        { 'key' => 'requirement', 'name' => 'csRq', 'item_profile' => 'requirement' },
        { 'key' => 'requirement_management', 'name' => 'csRqm', 'item_profile' => 'requirement' },
        { 'key' => 'requirement_release', 'name' => 'csRqr', 'item_profile' => 'requirement' },
        { 'key' => 'requirement_management_release', 'name' => 'csRqmr', 'item_profile' => 'requirement' }
      ].freeze
      BASE_TRACKERS = [
        { 'key' => 'cs_info', 'name' => 'csInfo', 'item_profile' => 'info' },
        { 'key' => 'cs_ref_doc', 'name' => 'csRefDoc', 'item_profile' => 'doc' },
        { 'key' => 'cs_data', 'name' => 'csData', 'item_profile' => 'data_section' },
        { 'key' => 'cs_datum', 'name' => 'csDatum', 'item_profile' => 'datum' },
        { 'key' => 'cs_negative', 'name' => 'csNegative', 'item_profile' => 'negative' }
      ].freeze

      def initialize(plan, captured_at:)
        @plan = plan
        @source = plan.source
        @captured_at = captured_at
      end

      def manifest(root_id)
        content = content(root_id)
        normalized = LegacySnapshot::CanonicalJson.normalize(content)
        {
          'schema' => SCHEMA,
          'schema_version' => SCHEMA_VERSION,
          'content_sha256' => Digest::SHA256.hexdigest(LegacySnapshot::CanonicalJson.generate(normalized)),
          'captured_at' => @captured_at,
          'captured_by' => 'snapshots_gen',
          'content' => normalized
        }
      end

      def write(root_id, path)
        manifest = manifest(root_id)
        digests = asset_digests(manifest.fetch('content'))
        Zip::OutputStream.open(path) do |archive|
          archive.put_next_entry('manifest.json')
          archive.write(LegacySnapshot::CanonicalJson.generate(manifest))
          digests.each do |digest|
            archive.put_next_entry("assets/sha256/#{digest}")
            File.open(@source.asset_path(digest), 'rb') { |file| IO.copy_stream(file, archive) }
          end
        end
        manifest
      end

      def projects_of(root_id)
        @source.table('projects').select { |row| @plan.root_of(row['id']) == root_id }
               .sort_by { |row| [row['lft'] || 0, row['id']] }
      end

      private

      def content(root_id)
        projects = projects_of(root_id)
        ids = projects.map { |row| row['id'] }.to_set
        root = @plan.project(root_id)
        {
          'root' => { 'source_id' => root_id, 'identifier' => root['identifier'] },
          'primary_project_source_id' => root_id,
          'platform' => { 'redmine_version' => @source.content.dig('source', 'redmine_version'), 'plugins' => [] },
          'projects' => projects.map { |row| project_entry(row, ids) },
          'relations' => @plan.relations.select { |relation| ids.include?(@plan.items.fetch(relation['from']).project_id) }
                              .map { |relation| relation.slice('from', 'to', 'type', 'delay').merge('restricted' => false) },
          'external_relations' => []
        }
      end

      def project_entry(row, ids)
        items = @plan.items.values.select { |item| item.project_id == row['id'] }
                     .sort_by { |item| [item.parent_key.to_s, item.position, item.key] }
        {
          'key' => "project:#{row['id']}",
          'source_id' => row['id'],
          'parent_key' => ids.include?(row['parent_id']) ? "project:#{row['parent_id']}" : nil,
          'project' => project_payload(row, items),
          'items' => items.map { |item| item_payload(item) },
          'documents' => @plan.documents.values.select { |document| document.project_id == row['id'] }
                              .sort_by(&:key).map { |document| document_payload(document) },
          'document_catalog' => catalog_payload(row['id']),
          'wiki' => wiki_payload(row['id'])
        }
      end

      def project_payload(row, items)
        profile = @plan.project_profile(row['id'])
        trackers = items.map(&:tracker).map { |tracker| tracker.slice('key', 'name', 'item_profile') }
        enabled = @source.table('projects_trackers').select { |link| link['project_id'] == row['id'] }
                         .filter_map { |link| @plan.tracker_name(link['tracker_id']) }
        enabled.each do |name|
          next if name == Rules::REQUIREMENT_TRACKER

          tracker = Rules::TRACKERS[name] || { 'key' => name, 'name' => name, 'item_profile' => nil }
          trackers << tracker
        end
        trackers.concat(BASE_TRACKERS)
        trackers.concat(REQUIREMENT_TRACKERS) if profile == 'requirements'
        modules = @source.table('enabled_modules').select { |entry| entry['project_id'] == row['id'] }.map { |entry| entry['name'] }
        modules = (modules & Rules::CORE_MODULES)
        modules |= %w[issue_tracking documents] if profile == 'requirements'
        {
          'identifier' => row['identifier'],
          'name' => Rules.clean(row['name']),
          'description' => Rules.clean(row['description']).to_s,
          'cscode' => @plan.project_code(row['id']),
          'profile' => profile,
          'language' => nil,
          'report_code' => Rules.clean(@plan.values('Project', row['id'])[Rules::PROJECT_REPORT_CODE_FIELD]).to_s.strip.then { |code| code.empty? ? nil : code },
          'wp' => nil,
          'wp_title' => nil,
          'report_export_format' => nil,
          'enabled_modules' => modules.sort,
          'trackers' => trackers.uniq { |tracker| tracker['key'] }.sort_by { |tracker| tracker['key'].to_s }
        }
      end

      def item_payload(item)
        issue = item.issue || {}
        fixed_version = issue['fixed_version_id'] && @plan.version(issue['fixed_version_id'])
        if fixed_version && fixed_version['project_id'] != item.project_id
          @plan.report.add('shared_version', item.key, version: fixed_version['name'])
          fixed_version = nil
        end
        {
          'key' => item.key,
          'source_id' => item.source_id,
          'csid' => item.csid,
          'csidnum' => item.csidnum,
          'position' => item.position,
          'parent_key' => item.parent_key,
          'tracker' => item.tracker.slice('key', 'name', 'item_profile'),
          'subject' => item.subject.to_s[0, 255],
          'description' => item.description.to_s,
          'status' => item.status,
          'priority' => @plan.enumeration_name(issue['priority_id']),
          'author' => @plan.principal_name(item.author_id),
          'assigned_to' => @plan.principal_name(issue['assigned_to_id']),
          'category' => issue['category_id'] && @plan.category(issue['category_id'])&.fetch('name'),
          'fixed_version' => fixed_version && fixed_version['name'],
          'start_date' => issue['start_date'],
          'due_date' => issue['due_date'],
          'estimated_hours' => issue['estimated_hours'],
          'done_ratio' => issue['done_ratio'] || 0,
          'is_private' => issue['is_private'] ? true : false,
          'closed_on' => issue['closed_on'],
          'preferred_report_diagram' => nil,
          'presentation_baselines' => [],
          'profile_fields' => item.profile_fields || {},
          'custom_fields' => (item.custom_fields || []).sort_by { |entry| entry['id'] },
          'attachments' => item.synthetic? ? [] : attachments(@plan.attachments_of('Issue', item.source_id))
        }
      end

      def document_payload(document)
        {
          'key' => document.key,
          'title' => document.title.to_s[0, 255],
          'description' => document.description.to_s,
          'category' => document.category,
          'external_code' => document.external_code,
          'date' => document.date,
          'version' => document.version,
          'attachments' => attachments(document.attachment_ids)
        }
      end

      def catalog_payload(project_id)
        counter = 0
        @plan.catalog.select { |entry| entry.project_id == project_id }
             .sort_by { |entry| [entry.family, entry.position, entry.document_key] }.map do |entry|
          {
            'document_key' => entry.document_key,
            'family' => entry.family,
            'position' => entry.position,
            'references' => entry.references.map do |reference|
              counter += 1
              { 'key' => "document:di-#{project_id}-#{counter}", 'item' => reference['item'],
                'sense' => reference['sense'], 'location' => reference['location'] }
            end
          }
        end
      end

      def wiki_payload(project_id)
        wiki = @source.table('wikis').find { |row| row['project_id'] == project_id }
        return { 'present' => false } unless wiki

        pages = @source.table('wiki_pages').select { |row| row['wiki_id'] == wiki['id'] }
        by_id = pages.to_h { |row| [row['id'], row] }
        contents = @source.table('wiki_contents').to_h { |row| [row['page_id'], row] }
        {
          'present' => true,
          'start_page' => wiki['start_page'],
          'pages' => pages.sort_by { |row| [row['title'].to_s.downcase, row['id']] }.map do |row|
            payload = {
              'title' => row['title'],
              'protected' => row['protected'] ? true : false,
              'parent_title' => row['parent_id'] && by_id[row['parent_id']]&.fetch('title'),
              'attachments' => attachments(@plan.attachments_of('WikiPage', row['id']))
            }
            if (content = contents[row['id']])
              payload['content'] = { 'text' => Rules.clean(content['text']).to_s,
                                     'author' => @plan.principal_name(content['author_id']),
                                     'comments' => Rules.clean(content['comments']) }
            end
            payload
          end
        }
      end

      def attachments(ids)
        rows = @source.table('attachments').to_h { |row| [row['id'], row] }
        ids.map do |id|
          row = rows.fetch(id)
          index = @source.asset_index.fetch(id)
          { 'filename' => Rules.clean(row['filename']), 'content_type' => row['content_type'],
            'byte_size' => index.fetch('bytes'), 'content_sha256' => index.fetch('sha256') }
        end
      end

      def asset_digests(content)
        content.fetch('projects').flat_map do |project|
          wiki = project['wiki']
          pages = wiki && wiki['present'] ? wiki.fetch('pages') : []
          project.fetch('items').flat_map { |row| row.fetch('attachments') } +
            project.fetch('documents').flat_map { |row| row.fetch('attachments') } +
            pages.flat_map { |row| row.fetch('attachments') }
        end.map { |row| row.fetch('content_sha256') }.uniq.sort
      end
    end
  end
end
