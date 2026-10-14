# frozen_string_literal: true

require 'json'
require 'set'
require 'tmpdir'
require 'zip'
require_relative '../exporter/legacy_snapshot_format'

module SnapshotsGen
  module Importer
    class Error < StandardError; end

    PLACEHOLDER = /#snapshots-gen-item-(\d+)/.freeze
    DEFAULT_ROLE_MAP = {
      'rqMngr' => 'Manager', 'rqWriter' => 'Developer', 'rqReviewer' => 'Developer', 'rqReader' => 'Reporter'
    }.freeze
    CUSTOM_FIELD_CLASSES = %w[IssueCustomField ProjectCustomField VersionCustomField UserCustomField
                              GroupCustomField TimeEntryCustomField DocumentCustomField].freeze

    # A verified history package written by the converter.
    class Package
      attr_reader :manifest

      def self.open(path)
        Dir.mktmpdir('snapshots_gen-import') do |directory|
          yield new(path, directory).load!
        end
      end

      def initialize(path, directory)
        @path = path.to_s
        @directory = directory
        @rows = {}
      end

      def load!
        result = LegacySnapshot::Verifier.new(@path).verify
        raise Error, "the history package does not verify: #{result.errors.first(5).join('; ')}" unless result.ok?
        unless result.manifest['schema'] == LegacySnapshot::HISTORY_SCHEMA
          raise Error, "#{@path} is not a history package (#{result.manifest['schema']})"
        end

        @manifest = result.manifest
        Zip::File.open(@path) do |archive|
          archive.each do |entry|
            next if entry.directory?

            target = File.join(@directory, entry.name)
            FileUtils.mkdir_p(File.dirname(target))
            entry.get_input_stream { |input| File.open(target, 'wb') { |output| IO.copy_stream(input, output) } }
          end
        end
        self
      end

      def rows(name)
        @rows[name] ||= begin
          table = manifest.dig('content', 'tables').find { |entry| entry['name'] == name }
          table ? File.foreach(File.join(@directory, table.fetch('path')), encoding: 'UTF-8').map { |line| JSON.parse(line) } : []
        end
      end

      def by_id(name)
        rows(name).to_h { |row| [row.fetch('id'), row] }
      end

      def csys_packages
        manifest.dig('content', 'csys_packages') || []
      end
    end

    # The three steps of the import in the new instance.
    class Run
      attr_reader :log

      def initialize(package, options = {})
        @package = package
        @options = options
        @log = []
        @stats = Hash.new(0)
        @dropped = []
      end

      def say(message)
        puts message
        @log << message
      end

      # --- prepare: before the .csys import --------------------------------

      def prepare!
        guard!
        ActiveRecord::Base.transaction do
          ensure_users!
          ensure_custom_fields!
          ensure_activities!
        end
        check_names!
        say "Prepared: #{@stats.select { |key, _value| key.to_s.start_with?('created_') }.map { |key, value| "#{key}=#{value}" }.join(', ')}"
      end

      # --- history: after every .csys import, before opening the instance ---

      def history!
        guard!
        resolve_projects!
        resolve_items!
        check_unopened!
        ActiveRecord::Base.transaction do
          remove_import_journals!
          ensure_users!
          ensure_custom_fields!
          ensure_activities!
          import_versions_and_categories!
          import_memberships!
          resolve_documents!
          resolve_wiki_pages!
          resolve_attachments!
          import_journals!
          import_wiki_versions!
          import_time_entries!
          import_watchers!
          import_relations!
          restore_items!
          restore_containers!
          restore_projects!
          import_deferred_values!
          replace_description_placeholders!
          problems = verify!
          raise Error, "verification failed, nothing was written:\n#{problems.join("\n")}" if problems.any?
          raise ActiveRecord::Rollback if @options['dry_run']
        end
        say(@options['dry_run'] ? 'Dry run: everything was rolled back.' : 'History imported.')
        summary
      end

      def summary
        { 'stats' => @stats.sort.to_h, 'dropped' => @dropped, 'log' => @log }
      end

      private

      def guard!
        ActionMailer::Base.perform_deliveries = false
        if defined?(Webhook) && Webhook.table_exists? && Webhook.where(active: true).exists?
          raise Error, 'active webhooks exist; disable them before importing the history'
        end
      end

      def time(value)
        value && Time.iso8601(value)
      end

      def flag(value)
        value == true || value.to_s == '1' || value.to_s == 'true'
      end

      # --- users -------------------------------------------------------------

      def ensure_users!
        @user_map = {}
        anonymous = User.anonymous
        principals = @package.rows('users')
        principals.select { |row| row['type'] == 'User' }.each do |row|
          login = row['login'].to_s
          next if login.empty?

          existing = User.where('LOWER(login) = ?', login.downcase).first
          if existing
            @user_map[row['id']] = existing.id
            @stats['users_matched'] += 1
            next
          end
          now = Time.now.utc
          attributes = {
            'login' => login, 'firstname' => row['firstname'].to_s, 'lastname' => row['lastname'].to_s,
            'admin' => flag(row['admin']), 'status' => row['status'] || User::STATUS_LOCKED,
            'language' => row['language'].to_s, 'mail_notification' => row['mail_notification'].presence || 'only_my_events',
            'hashed_password' => row['hashed_password'].to_s, 'salt' => row['salt'],
            'passwd_changed_on' => time(row['passwd_changed_on']), 'must_change_passwd' => flag(row['must_change_passwd']),
            'created_on' => time(row['created_on']) || now, 'updated_on' => time(row['updated_on']) || now,
            'last_login_on' => time(row['last_login_on']), 'type' => 'User'
          }.select { |column, _value| User.column_names.include?(column) }
          id = User.insert_all([attributes], returning: %w[id], record_timestamps: false).rows.first.first
          emails = Array(row['emails'])
          if emails.any?
            EmailAddress.insert_all(emails.map do |email|
              { 'user_id' => id, 'address' => email['address'], 'is_default' => flag(email['is_default']),
                'notify' => email['notify'].nil? ? true : flag(email['notify']), 'created_on' => now, 'updated_on' => now }
            end, record_timestamps: false)
          end
          @user_map[row['id']] = id
          @stats['created_users'] += 1
        end
        principals.select { |row| row['type'] == 'Group' }.each do |row|
          existing = Group.where(lastname: row['lastname']).first
          id = existing&.id || Group.insert_all([{ 'lastname' => row['lastname'], 'type' => 'Group',
                                                   'status' => User::STATUS_ACTIVE, 'firstname' => '',
                                                   'login' => '', 'admin' => false, 'mail_notification' => '',
                                                   'created_on' => time(row['created_on']) || Time.now.utc,
                                                   'updated_on' => time(row['updated_on']) || Time.now.utc }
                                                   .select { |column, _value| User.column_names.include?(column) }],
                                                 returning: %w[id], record_timestamps: false).rows.first.first
          @stats[existing ? 'groups_matched' : 'created_groups'] += 1
          @user_map[row['id']] = id
        end
        existing_links = ActiveRecord::Base.connection.select_rows('SELECT group_id, user_id FROM groups_users').to_set
        @package.rows('group_users').each do |row|
          group = @user_map[row['group_id']]
          user = @user_map[row['user_id']]
          next unless group && user && !existing_links.include?([group, user])

          ActiveRecord::Base.connection.execute("INSERT INTO groups_users (group_id, user_id) VALUES (#{Integer(group)}, #{Integer(user)})")
          existing_links << [group, user]
          @stats['created_group_users'] += 1
        end
        @anonymous_id = anonymous.id
      end

      # Source principal id => destination id; deleted users and the anonymous
      # user become the destination's anonymous user.
      def user_id(source_id)
        return nil if source_id.nil?

        @user_map.fetch(source_id.to_i) { @anonymous_id }
      end

      # --- custom fields, activities and names ------------------------------

      def ensure_custom_fields!
        @field_map = {}
        @package.rows('custom_fields').each do |row|
          klass = row['type'].to_s
          raise Error, "unsupported custom field type #{klass}" unless CUSTOM_FIELD_CLASSES.include?(klass)

          model = klass.constantize
          field = model.where(name: row['name'], field_format: row['field_format']).first
          unless field
            field = model.new(
              name: row['name'], field_format: row['field_format'], possible_values: row['possible_values'].presence,
              multiple: flag(row['multiple']), is_required: false, is_for_all: flag(row['is_for_all']),
              is_filter: flag(row['is_filter']), searchable: flag(row['searchable']), default_value: row['default_value'],
              description: row['description'], visible: row['visible'].nil? ? true : flag(row['visible']),
              editable: row['editable'].nil? ? true : flag(row['editable']), regexp: row['regexp'],
              min_length: row['min_length'], max_length: row['max_length']
            )
            if field.respond_to?(:tracker_ids=)
              field.tracker_ids = Tracker.where(name: row['trackers']).pluck(:id)
            end
            field.role_ids = Role.where(name: row['roles']).pluck(:id) if field.respond_to?(:role_ids=) && row['roles'].present?
            field.project_ids = Project.where(identifier: row['projects']).pluck(:id) if field.respond_to?(:project_ids=) && row['projects'].present?
            field.save!
            @stats['created_custom_fields'] += 1
            say "Created custom field #{row['name']} (#{klass}, #{row['field_format']})#{row['computed'] ? ', its formula is not kept' : ''}"
          else
            if field.respond_to?(:tracker_ids=)
              missing = Tracker.where(name: row['trackers']).pluck(:id) - field.tracker_ids
              field.update!(tracker_ids: field.tracker_ids + missing) if missing.any?
            end
            @stats['custom_fields_matched'] += 1
          end
          @field_map[row['id']] = field.id
        end
      end

      def ensure_activities!
        @activity_map = {}
        @package.rows('activities').each do |row|
          activity = TimeEntryActivity.where(name: row['name'], project_id: nil).first
          unless activity
            activity = TimeEntryActivity.create!(name: row['name'], active: true)
            @stats['created_activities'] += 1
          end
          @activity_map[row['id']] = activity.id
        end
      end

      def check_names!
        trackers = @package.rows('items').map { |row| row['tracker'] }.uniq
        missing = trackers.reject { |name| Tracker.exists?(name: name) }
        say "Missing trackers (the .csys import will refuse their items): #{missing.join(', ')}" if missing.any?
        statuses = @package.rows('statuses').filter_map { |row| row['name'] }.uniq
        missing = statuses.reject { |name| IssueStatus.exists?(name: name) }
        say "Missing statuses (history details naming them will be dropped): #{missing.join(', ')}" if missing.any?
        role_names = @package.rows('members').flat_map { |row| row['roles'] }.uniq
        role_names.each do |name|
          target = role_target(name)
          say(target ? "Role #{name} -> #{target.name}" : "Role #{name} has no destination role; its memberships will be skipped")
        end
      end

      def role_target(name)
        mapping = DEFAULT_ROLE_MAP.merge(@options.fetch('roles', {}))
        Role.where(builtin: 0, name: name).first || (mapping[name] && Role.where(builtin: 0, name: mapping[name]).first)
      end

      # --- projects and items --------------------------------------------------

      def resolve_projects!
        @project_map = {}
        missing = []
        @package.rows('projects').each do |row|
          project = Project.find_by(identifier: row['identifier'])
          project ? @project_map[row['id']] = project.id : missing << row['identifier']
        end
        raise Error, "projects not imported yet (import every .csys first): #{missing.join(', ')}" if missing.any?
      end

      def resolve_items!
        @item_map = {}
        @issue_key = {}
        missing = []
        rows = @package.rows('items')
        by_project = Issue.where(project_id: @project_map.values).pluck(:project_id, :csid, :id)
                          .group_by(&:first).transform_values { |list| list.to_h { |_project, csid, id| [csid.to_s.downcase, id] } }
        rows.each do |row|
          id = by_project.fetch(@project_map.fetch(row['project_id']), {})[row['csid'].to_s.downcase]
          id ? @item_map[row['key']] = id : missing << "#{row['key']} (#{row['csid']})"
          @issue_key[row['id']] = row['key'] if row['id'].to_i.positive?
        end
        raise Error, "items not found in the new instance: #{missing.first(20).join(', ')}" if missing.any?
      end

      def item_id_for_source(source_issue_id)
        key = @issue_key[source_issue_id.to_i]
        key && @item_map[key]
      end

      # The history must be written before anyone works in the new instance:
      # Redmine relies on journal order in several places.
      # The .csys import itself journals each subtask it attaches ("child_id"),
      # which Redmine 4.2 never recorded: those journals are removed. Any other
      # journal means someone already worked here.
      def check_unopened!
        journals = Journal.where(journalized_type: 'Issue', journalized_id: @item_map.values).includes(:details).to_a
        @import_journals = journals.select do |journal|
          journal.notes.to_s.strip.empty? && journal.details.any? &&
            journal.details.all? { |detail| detail.property == 'attr' && detail.prop_key == 'child_id' }
        end.map(&:id)
        others = journals.length - @import_journals.length
        return if others.zero? || @options['allow_existing_journals']

        raise Error, "#{others} journals already exist on the imported items; the history must be imported " \
                     'before anyone works in the instance'
      end

      def remove_import_journals!
        JournalDetail.where(journal_id: @import_journals).delete_all
        Journal.where(id: @import_journals).delete_all
        @stats['import_journals_removed'] = @import_journals.length
      end

      # --- versions, categories and memberships --------------------------------

      def import_versions_and_categories!
        @version_map = {}
        @package.rows('versions').each do |row|
          project_id = @project_map[row['project_id']]
          next unless project_id

          version = Version.where(project_id: project_id, name: row['name']).first
          attributes = {
            'description' => row['description'].to_s, 'effective_date' => row['effective_date'], 'status' => row['status'],
            'sharing' => row['sharing'], 'wiki_page_title' => row['wiki_page_title'],
            'created_on' => time(row['created_on']), 'updated_on' => time(row['updated_on'])
          }
          if version
            version.update_columns(attributes)
          else
            id = Version.insert_all([attributes.merge('project_id' => project_id, 'name' => row['name'])],
                                    returning: %w[id], record_timestamps: false).rows.first.first
            version = Version.find(id)
            @stats['created_versions'] += 1
          end
          @version_map[row['id']] = version.id
        end
        @category_map = {}
        @package.rows('categories').each do |row|
          project_id = @project_map[row['project_id']]
          next unless project_id

          category = IssueCategory.where(project_id: project_id, name: row['name']).first
          if category
            category.update_columns(assigned_to_id: user_id(row['assigned_to_id']))
          else
            category = IssueCategory.create!(project_id: project_id, name: row['name'])
            category.update_columns(assigned_to_id: user_id(row['assigned_to_id']))
            @stats['created_categories'] += 1
          end
          @category_map[row['id']] = category.id
        end
      end

      def import_memberships!
        @package.rows('members').each do |row|
          project_id = @project_map[row['project_id']]
          principal_id = row['user_id'] && @user_map[row['user_id']]
          unless project_id && principal_id
            @dropped << { 'kind' => 'membership', 'id' => row['id'], 'reason' => 'principal or project not migrated' }
            next
          end
          roles = row['roles'].filter_map { |name| role_target(name) }.uniq
          if roles.empty?
            @dropped << { 'kind' => 'membership', 'id' => row['id'], 'reason' => "no destination role for #{row['roles'].join(', ')}" }
            next
          end
          member = Member.where(project_id: project_id, user_id: principal_id).first
          if member
            member.role_ids = (member.role_ids + roles.map(&:id)).uniq
            member.save!
          else
            member = Member.new(project_id: project_id, user_id: principal_id)
            member.role_ids = roles.map(&:id)
            member.save!
            @stats['created_memberships'] += 1
          end
          member.update_columns(created_on: time(row['created_on'])) if row['created_on']
        end
      end

      # --- attachments, documents and wiki pages -------------------------------

      def resolve_documents!
        @document_map = {}
        @package.rows('documents').group_by { |row| row['project_id'] }.each do |source_project, rows|
          project_id = @project_map.fetch(source_project)
          documents = Document.where(project_id: project_id).order(:id).to_a
          ordered = rows.sort_by { |row| row['id'] }
          raise Error, "project #{project_id} has #{documents.length} documents, expected #{ordered.length}" unless documents.length == ordered.length

          ordered.zip(documents).each do |row, document|
            raise Error, "document #{row['id']} does not match #{document.title.inspect}" unless document.title == row['title'].to_s[0, 255]

            @document_map[row['id']] = document.id
          end
        end
      end

      def resolve_wiki_pages!
        @page_map = {}
        @package.rows('wiki_pages').each do |row|
          project = Project.find(@project_map.fetch(row['project_id']))
          page = project.wiki&.find_page(row['title'], with_redirect: false)
          raise Error, "wiki page #{row['title']} of #{project.identifier} is missing" unless page

          @page_map[row['id']] = page.id
        end
      end

      def resolve_attachments!
        @attachment_map = {}
        by_container = Hash.new { |hash, key| hash[key] = [] }
        @package.rows('attachments').each do |row|
          next unless row['migrated']

          by_container[[row['container'], row['container_key']]] << row
        end
        by_container.each do |(type, key), rows|
          container_type, container_id = case type
                                         when 'item' then ['Issue', @item_map.fetch(key)]
                                         when 'document' then ['Document', @document_map.fetch(key)]
                                         when 'wiki_page' then ['WikiPage', @page_map.fetch(key.to_i)]
                                         end
          attachments = Attachment.where(container_type: container_type, container_id: container_id).order(:id).to_a
          rows.sort_by { |row| row['ordinal'] }.each do |row|
            attachment = attachments[row['ordinal']]
            unless attachment && attachment.filename == row['filename'] && attachment.digest == row['sha256']
              raise Error, "attachment #{row['id']} (#{row['filename']}) is not where the .csys import should have put it"
            end

            @attachment_map[row['id']] = attachment.id
          end
        end
      end

      # --- journals --------------------------------------------------------------

      def import_journals!
        details = @package.rows('journal_details').group_by { |row| row['journal_id'] }
        @journal_count = 0
        @detail_count = 0
        @package.rows('journals').sort_by { |row| [row['created_on'].to_s, row['id']] }.each do |row|
          issue_id = @item_map.fetch(row['item_key'])
          translated = Array(details[row['id']]).sort_by { |detail| detail['id'] }.filter_map { |detail| translate(detail, issue_id) }
          notes = placeholders(row['notes'].to_s)
          if notes.strip.empty? && translated.empty?
            @dropped << { 'kind' => 'journal', 'id' => row['id'], 'reason' => 'no detail could be translated' }
            next
          end
          created = time(row['created_on'])
          id = Journal.insert_all([{ 'journalized_id' => issue_id, 'journalized_type' => 'Issue',
                                     'user_id' => user_id(row['user_id']), 'notes' => notes,
                                     'private_notes' => flag(row['private_notes']), 'created_on' => created,
                                     'updated_on' => created, 'updated_by_id' => nil }],
                                  returning: %w[id], record_timestamps: false).rows.first.first
          JournalDetail.insert_all(translated.map { |detail| detail.merge('journal_id' => id) }) if translated.any?
          @journal_count += 1
          @detail_count += translated.length
        end
        @stats['journals'] = @journal_count
        @stats['journal_details'] = @detail_count
      end

      def translate(detail, issue_id)
        prop_key = detail['prop_key'].to_s
        case detail['prop_ref']
        when 'attachments'
          prop_key = @attachment_map[prop_key.to_i]&.to_s || '0'
        when 'custom_fields'
          prop_key = @field_map[prop_key.to_i]&.to_s
          return drop_detail(detail, 'custom field not created') unless prop_key
        end
        old_value = reference(detail['value_ref'], detail['old_value'], issue_id)
        value = reference(detail['value_ref'], detail['value'], issue_id)
        return drop_detail(detail, "#{detail['value_ref']} #{detail['old_value'] || detail['value']} not found") if old_value == :missing || value == :missing

        { 'property' => detail['property'], 'prop_key' => prop_key,
          'old_value' => detail['value_ref'] ? old_value : placeholders(old_value),
          'value' => detail['value_ref'] ? value : placeholders(value) }
      end

      def drop_detail(detail, reason)
        @dropped << { 'kind' => 'journal_detail', 'id' => detail['id'], 'reason' => reason }
        nil
      end

      # Translates one referenced value; :missing when it cannot be found.
      def reference(ref, value, issue_id)
        return value if ref.nil? || value.nil? || value.to_s.empty?

        source = value.to_s
        found = case ref
                when 'statuses' then status_id(source.to_i, issue_id)
                when 'trackers' then named_id(Tracker, 'trackers', source.to_i)
                when 'priorities' then named_id(IssuePriority, 'priorities', source.to_i)
                when 'users' then user_id(source.to_i)
                when 'categories' then @category_map[source.to_i]
                when 'versions' then @version_map[source.to_i]
                when 'projects' then @project_map[source.to_i]
                when 'items' then item_id_for_source(source.to_i)
                end
        found ? found.to_s : :missing
      end

      def status_id(source_id, issue_id)
        row = @package.by_id('statuses')[source_id]
        return nil unless row
        return Issue.find(issue_id).tracker.default_status_id if row['name'].nil?

        IssueStatus.where(name: row['name']).pick(:id)
      end

      def named_id(model, entity, source_id)
        row = @package.by_id(entity)[source_id]
        row && model.where(name: row['name']).pick(:id)
      end

      def placeholders(text)
        return text if text.nil?

        text.to_s.gsub(PLACEHOLDER) do
          id = item_id_for_source(Regexp.last_match(1))
          id ? "##{id}" : "!##{Regexp.last_match(1)}"
        end
      end

      # --- wiki, time entries, watchers and relations -------------------------

      def import_wiki_versions!
        versions = @package.rows('wiki_versions').group_by { |row| row['page_id'] }
        @package.rows('wiki_pages').each do |page|
          page_id = @page_map.fetch(page['id'])
          content = WikiContent.find_by!(page_id: page_id)
          WikiContentVersion.where(wiki_content_id: content.id).delete_all
          rows = Array(versions[page['id']]).sort_by { |row| row['version'] }
          if rows.any?
            WikiContentVersion.insert_all(rows.map do |row|
              { 'wiki_content_id' => content.id, 'page_id' => page_id, 'author_id' => user_id(row['author_id']),
                'data' => placeholders(row['text'].to_s), 'compression' => '', 'comments' => row['comments'].to_s,
                'updated_on' => time(row['updated_on']), 'version' => row['version'] }
            end, record_timestamps: false)
          end
          content.update_columns(
            text: placeholders(page['current_text'].to_s), author_id: user_id(page['current_author_id']),
            comments: page['current_comments'].to_s, version: page['current_version'] || 1,
            updated_on: time(page['current_updated_on']) || content.updated_on
          )
          WikiPage.where(id: page_id).update_all(created_on: time(page['created_on']), protected: flag(page['protected']))
          @stats['wiki_versions'] += rows.length
        end
        @package.rows('wiki_redirects').each do |row|
          project = Project.find_by(id: @project_map[row['project_id']])
          target = Project.find_by(id: @project_map[row['redirects_to_project_id']])
          next unless project&.wiki && target&.wiki
          next if WikiRedirect.where(wiki_id: project.wiki.id, title: row['title']).exists?

          WikiRedirect.insert_all([{ 'wiki_id' => project.wiki.id, 'title' => row['title'], 'redirects_to' => row['redirects_to'],
                                     'redirects_to_wiki_id' => target.wiki.id, 'created_on' => time(row['created_on']) }],
                                  record_timestamps: false)
          @stats['wiki_redirects'] += 1
        end
      end

      def import_time_entries!
        rows = @package.rows('time_entries').filter_map do |row|
          project_id = @project_map[row['project_id']]
          activity_id = @activity_map[row['activity_id']]
          unless project_id && activity_id
            @dropped << { 'kind' => 'time_entry', 'id' => row['id'], 'reason' => 'project or activity not migrated' }
            next
          end
          spent = Date.iso8601(row['spent_on'])
          { 'project_id' => project_id, 'issue_id' => row['item_key'] && @item_map[row['item_key']],
            'user_id' => user_id(row['user_id']), 'author_id' => user_id(row['author_id'] || row['user_id']),
            'activity_id' => activity_id, 'hours' => row['hours'], 'comments' => row['comments'].to_s, 'spent_on' => spent,
            'tyear' => spent.year, 'tmonth' => spent.month, 'tweek' => spent.cweek,
            'created_on' => time(row['created_on']), 'updated_on' => time(row['updated_on']) }
        end
        TimeEntry.insert_all(rows, record_timestamps: false) if rows.any?
        @stats['time_entries'] = rows.length
      end

      def import_watchers!
        Watcher.where(watchable_type: 'Issue', watchable_id: @item_map.values).delete_all
        Watcher.where(watchable_type: 'WikiPage', watchable_id: @page_map.values).delete_all
        rows = @package.rows('watchers').filter_map do |row|
          type, id = if row['target'].start_with?('wiki_page:')
                       ['WikiPage', @page_map[row['target'].delete_prefix('wiki_page:').to_i]]
                     else
                       ['Issue', @item_map[row['target']]]
                     end
          user = @user_map[row['user_id']]
          next unless id && user

          { 'watchable_type' => type, 'watchable_id' => id, 'user_id' => user }
        end.uniq
        Watcher.insert_all(rows) if rows.any?
        @stats['watchers'] = rows.length
      end

      def import_relations!
        rows = @package.rows('relations').filter_map do |row|
          from = @item_map[row['from']]
          to = @item_map[row['to']]
          next unless from && to
          next if IssueRelation.where(issue_from_id: from, issue_to_id: to, relation_type: row['type']).exists?

          { 'issue_from_id' => from, 'issue_to_id' => to, 'relation_type' => row['type'], 'delay' => row['delay'] }
        end
        IssueRelation.insert_all(rows) if rows.any?
        @stats['cross_package_relations'] = rows.length
      end

      # --- authors, dates and attributes -------------------------------------

      def restore_items!
        @package.rows('items').each do |row|
          issue_id = @item_map.fetch(row['key'])
          attributes = { 'author_id' => user_id(row['author_id']) }
          attributes['created_on'] = time(row['created_on']) if row['created_on']
          attributes['updated_on'] = time(row['updated_on']) if row['updated_on']
          attributes['closed_on'] = time(row['closed_on'])
          if row['synthetic'].nil?
            attributes['assigned_to_id'] = user_id(row['assigned_to_id']) if row['assigned_to_id']
            attributes['fixed_version_id'] = @version_map[row['fixed_version_id']] if row['fixed_version_id']
            attributes['category_id'] = @category_map[row['category_id']] if row['category_id']
          end
          Issue.where(id: issue_id).update_all(attributes)
        end
        @stats['items_restored'] = @package.rows('items').length
      end

      def restore_containers!
        @package.rows('attachments').each do |row|
          id = @attachment_map[row['id']]
          next unless id

          Attachment.where(id: id).update_all(author_id: user_id(row['author_id']), created_on: time(row['created_on']),
                                              description: row['description'], downloads: row['downloads'].to_i)
        end
        @package.rows('documents').each do |row|
          id = @document_map[row['id']]
          Document.where(id: id).update_all(created_on: time(row['created_on'])) if id && row['created_on']
        end
      end

      def restore_projects!
        @package.rows('projects').each do |row|
          project_id = @project_map.fetch(row['id'])
          attributes = { 'is_public' => flag(row['is_public']), 'status' => row['status'] || Project::STATUS_ACTIVE,
                         'inherit_members' => flag(row['inherit_members']), 'homepage' => row['homepage'].to_s }
          attributes['created_on'] = time(row['created_on']) if row['created_on']
          attributes['updated_on'] = time(row['updated_on']) if row['updated_on']
          Project.where(id: project_id).update_all(attributes)
          set_custom_values('Project', project_id, row['custom_values'], 'ProjectCustomField')
        end
        @package.rows('versions').each do |row|
          set_custom_values('Version', @version_map[row['id']], row['custom_values'], 'VersionCustomField') if @version_map[row['id']]
        end
      end

      def set_custom_values(type, id, values, field_class)
        Array(values).each do |entry|
          field = field_class.constantize.find_by(name: entry['field'])
          unless field
            @dropped << { 'kind' => 'custom_value', 'id' => "#{type} #{id}", 'reason' => "field #{entry['field']} missing" }
            next
          end
          CustomValue.where(customized_type: type, customized_id: id, custom_field_id: field.id).delete_all
          CustomValue.insert_all(Array(entry['value']).map do |value|
            { 'customized_type' => type, 'customized_id' => id, 'custom_field_id' => field.id, 'value' => value }
          end)
        end
      end

      def import_deferred_values!
        @package.rows('deferred_values').each do |row|
          issue_id = @item_map[row['item']]
          field = IssueCustomField.find_by(name: row['field'])
          next unless issue_id && field

          values = Array(row['value']).filter_map do |value|
            case row['format']
            when 'user' then @user_map[value.to_i]
            when 'version' then @version_map[value.to_i]
            end
          end
          if values.empty?
            @dropped << { 'kind' => 'custom_value', 'id' => row['item'], 'reason' => "#{row['field']} values not migrated" }
            next
          end
          CustomValue.where(customized_type: 'Issue', customized_id: issue_id, custom_field_id: field.id).delete_all
          CustomValue.insert_all(values.map { |value| { 'customized_type' => 'Issue', 'customized_id' => issue_id, 'custom_field_id' => field.id, 'value' => value.to_s } })
        end
      end

      def replace_description_placeholders!
        Issue.where(id: @item_map.values).where('description LIKE ?', '%#snapshots-gen-item-%').find_each do |issue|
          Issue.where(id: issue.id).update_all(description: placeholders(issue.description))
        end
      end

      # --- verification ------------------------------------------------------

      def verify!
        problems = []
        journals = Journal.where(journalized_type: 'Issue', journalized_id: @item_map.values)
        problems << "#{journals.count} journals, expected #{@journal_count}" unless journals.count == @journal_count
        edited = journals.where('updated_on <> created_on OR updated_by_id IS NOT NULL').count
        problems << "#{edited} journals would show as edited" if edited.positive?
        order = journals.order(:id).pluck(:created_on)
        problems << 'journal ids do not follow their dates' unless order.each_cons(2).all? { |a, b| a <= b }
        details = JournalDetail.where(journal_id: journals.select(:id))
        problems << "#{details.count} details, expected #{@detail_count}" unless details.count == @detail_count
        details.where(property: 'attachment').where.not(value: [nil, '']).find_each do |detail|
          next if detail.prop_key == '0'

          attachment = Attachment.find_by(id: detail.prop_key.to_i)
          issue_id = detail.journal.journalized_id
          problems << "detail #{detail.id} points to an attachment of another container" unless attachment&.container_id == issue_id
        end
        { 'status_id' => IssueStatus, 'tracker_id' => Tracker, 'priority_id' => IssuePriority, 'assigned_to_id' => Principal,
          'category_id' => IssueCategory, 'fixed_version_id' => Version, 'project_id' => Project, 'parent_id' => Issue }.each do |key, model|
          ids = details.where(property: 'attr', prop_key: key).pluck(:old_value, :value).flatten.compact.reject(&:empty?).map(&:to_i).uniq
          unknown = ids - model.where(id: ids).pluck(:id)
          problems << "#{key} details name #{unknown.length} missing records" if unknown.any?
        end
        relation_ids = details.where(property: 'relation').pluck(:old_value, :value).flatten.compact.map(&:to_i).uniq
        problems << 'relation details name missing items' unless (relation_ids - Issue.where(id: relation_ids).pluck(:id)).empty?
        leftovers = journals.where('notes LIKE ?', '%#snapshots-gen-item-%').count +
                    Issue.where(id: @item_map.values).where('description LIKE ?', '%#snapshots-gen-item-%').count +
                    WikiContent.where(page_id: @page_map.values).where('text LIKE ?', '%#snapshots-gen-item-%').count
        problems << "#{leftovers} texts still hold reference placeholders" if leftovers.positive?
        labels = untranslated_history_labels(journals)
        problems << "history labels without translation: #{labels.join(', ')}" if labels.any?
        say "Verified #{journals.count} journals and #{details.count} details; #{@dropped.length} records dropped (listed in the report)."
        problems
      end

      # Renders every imported detail as Redmine does and looks for labels
      # that would show "Translation missing".
      def untranslated_history_labels(journals)
        renderer = Object.new
        renderer.extend(Redmine::I18n, ERB::Util, ActionView::Helpers::TagHelper, ActionView::Helpers::OutputSafetyHelper,
                        ApplicationHelper, CustomFieldsHelper, IssuesHelper)
        problems = Set.new
        %w[en es].each do |language|
          ::I18n.with_locale(language) do
            journals.includes(:details).find_each do |journal|
              renderer.details_to_strings(journal.visible_details(User.find_by(admin: true)), true).each do |line|
                problems << "#{language}:#{line[0, 60]}" if line.to_s.match?(/translation missing/i)
              end
            end
          end
        end
        problems.to_a.sort
      rescue StandardError => error
        ["could not render the history: #{error.class}: #{error.message}"]
      end
    end
  end
end
