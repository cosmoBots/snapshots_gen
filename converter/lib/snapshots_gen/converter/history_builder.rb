# frozen_string_literal: true

require 'yaml'
require 'zlib'

module SnapshotsGen
  module Converter
    # Builds the history package: everything the .csys leaves out on purpose
    # (users, memberships, versions, categories, notes and changes, wiki
    # versions, time entries, watchers, authors and dates), already
    # interpreted for the current model. References to other records are kept
    # as source ids plus the entity they belong to, so the importer only has to
    # find each entity once in the new instance.
    class HistoryBuilder
      GENERATOR = { 'name' => 'snapshots_gen converter', 'version' => '0.1.0' }.freeze
      ATTR_REFS = {
        'status_id' => 'statuses', 'tracker_id' => 'trackers', 'priority_id' => 'priorities',
        'assigned_to_id' => 'users', 'author_id' => 'users', 'category_id' => 'categories',
        'fixed_version_id' => 'versions', 'project_id' => 'projects', 'parent_id' => 'items'
      }.freeze
      ATTR_LITERALS = %w[subject description start_date due_date done_ratio estimated_hours is_private].freeze

      def initialize(plan, csys_packages:)
        @plan = plan
        @source = plan.source
        @report = plan.report
        @csys_packages = csys_packages
      end

      def write(directory)
        writer = LegacySnapshot::Writer.new(directory, schema: LegacySnapshot::HISTORY_SCHEMA)
        entities.each do |name, rows|
          columns = rows.flat_map(&:keys).uniq.sort
          columns = ['id'] if columns.empty?
          descriptors = columns.map { |column| { 'name' => column, 'type' => 'json', 'sql_type' => 'json', 'null' => true } }
          rows = rows.map { |row| columns.to_h { |column| [column, row[column]] } }
          keyed = columns.include?('id')
          rows = rows.sort_by { |row| LegacySnapshot::Values.row_sort_key(row, keyed ? ['id'] : columns) }
          writer.write_table(name, columns: descriptors, primary_key: keyed ? ['id'] : [], order_by: keyed ? ['id'] : columns) do |emit|
            rows.each { |row| emit.call(row) }
          end
        end
        writer.finish!(
          captured_at: @source.content.fetch('captured_at'),
          generator: GENERATOR,
          source: @source.content.fetch('source').slice('label', 'redmine_version', 'settings', 'time'),
          consistency: { 'legacy_snapshot_sha256' => @source.manifest.fetch('content_sha256') },
          extra: { 'csys_packages' => @csys_packages }
        )
        writer
      end

      def entities
        # Journals first: translating their details can add custom fields
        # whose definitions the importer needs.
        return @entities if @entities

        journal_rows = journals
        @entities ||= {
          'projects' => projects, 'users' => users, 'group_users' => group_users, 'roles' => roles,
          'members' => members, 'statuses' => named('issue_statuses') { |row| @plan.mapped_status(row['name']) },
          'trackers' => named('trackers') { |row| @plan.mapped_tracker_name(row['name']) },
          'priorities' => named('enumerations') { |row| row['name'] if row['type'] == 'IssuePriority' },
          'activities' => named('enumerations') { |row| row['name'] if row['type'] == 'TimeEntryActivity' },
          'versions' => versions, 'categories' => categories, 'custom_fields' => custom_fields,
          'items' => items, 'documents' => documents, 'attachments' => attachments,
          'journals' => journal_rows, 'journal_details' => @details,
          'wiki_pages' => wiki_pages, 'wiki_versions' => wiki_versions, 'wiki_redirects' => wiki_redirects,
          'time_entries' => time_entries, 'watchers' => watchers, 'relations' => relations,
          'deferred_values' => deferred_values
        }
      end

      private

      def table(name)
        @source.table(name)
      end

      def named(table_name)
        table(table_name).filter_map do |row|
          name = yield(row)
          next unless name || table_name == 'issue_statuses'

          { 'id' => row['id'], 'name' => name, 'source_name' => row['name'] }
        end
      end

      def custom_values(type, id)
        @plan.values(type, id).filter_map do |name, value|
          next if value.nil? || value == '' || value == []

          { 'field' => name, 'value' => value }
        end
      end

      def projects
        table('projects').map do |row|
          {
            'id' => row['id'], 'identifier' => row['identifier'], 'name' => row['name'],
            'root_identifier' => @plan.project_identifier(@plan.root_of(row['id'])),
            'parent_id' => row['parent_id'], 'is_public' => row['is_public'], 'status' => row['status'],
            'inherit_members' => row['inherit_members'], 'homepage' => row['homepage'],
            'created_on' => row['created_on'], 'updated_on' => row['updated_on'],
            'custom_values' => custom_values('Project', row['id']).reject do |entry|
              [Rules::PROJECT_CODE_FIELD, Rules::PROJECT_REPORT_CODE_FIELD].include?(entry['field']) ||
                Rules::DROPPED_PROJECT_FIELDS.key?(entry['field'])
            end
          }
        end
      end

      def users
        emails = table('email_addresses').group_by { |row| row['user_id'] }
        auth_sources = table('auth_sources').to_h { |row| [row['id'], row['name']] }
        table('users').filter_map do |row|
          next unless %w[User Group].include?(row['type'])

          if row['type'] == 'User'
            @report.add('user_without_login', "user ##{row['id']}") if row['login'].to_s.empty?
            @report.add('user_external_auth', row['login'], source: auth_sources[row['auth_source_id']]) if row['auth_source_id']
            @report.add('user_2fa_reset', row['login']) unless row['twofa_scheme'].to_s.empty?
          end
          {
            'id' => row['id'], 'type' => row['type'], 'login' => row['login'], 'firstname' => row['firstname'],
            'lastname' => row['lastname'], 'admin' => row['admin'], 'status' => row['status'],
            'language' => row['language'], 'mail_notification' => row['mail_notification'],
            'hashed_password' => row['hashed_password'], 'salt' => row['salt'],
            'passwd_changed_on' => row['passwd_changed_on'], 'must_change_passwd' => row['must_change_passwd'],
            'created_on' => row['created_on'], 'updated_on' => row['updated_on'], 'last_login_on' => row['last_login_on'],
            'auth_source' => auth_sources[row['auth_source_id']], 'had_2fa' => !row['twofa_scheme'].to_s.empty?,
            'emails' => Array(emails[row['id']]).sort_by { |email| [email['is_default'] ? 0 : 1, email['id']] }.map do |email|
              { 'address' => email['address'], 'is_default' => email['is_default'], 'notify' => email['notify'] }
            end,
            'custom_values' => custom_values('Principal', row['id']) + custom_values('User', row['id'])
          }
        end
      end

      def group_users
        table('groups_users').map { |row| { 'group_id' => row['group_id'], 'user_id' => row['user_id'] } }
      end

      def roles
        table('roles').map do |row|
          { 'id' => row['id'], 'name' => row['name'], 'builtin' => row['builtin'], 'permissions' => row['permissions'] }
        end
      end

      def members
        role_names = table('roles').to_h { |row| [row['id'], row['name']] }
        member_roles = table('member_roles').reject { |row| row['inherited_from'] }.group_by { |row| row['member_id'] }
        counts = Hash.new(0)
        rows = table('members').filter_map do |row|
          names = Array(member_roles[row['id']]).map { |entry| role_names[entry['role_id']] }.compact.sort
          next if names.empty?

          names.each { |name| counts[name] += 1 }
          { 'id' => row['id'], 'project_id' => row['project_id'], 'user_id' => row['user_id'], 'roles' => names,
            'created_on' => row['created_on'], 'mail_notification' => row['mail_notification'] }
        end
        counts.each { |name, count| @report.add('role_mapped', name, memberships: count) }
        rows
      end

      def versions
        table('versions').map do |row|
          row.slice('id', 'project_id', 'name', 'description', 'effective_date', 'status', 'sharing',
                    'wiki_page_title', 'created_on', 'updated_on').merge('custom_values' => custom_values('Version', row['id']))
        end
      end

      def categories
        table('issue_categories').map { |row| row.slice('id', 'project_id', 'name', 'assigned_to_id') }
      end

      # Definitions of the custom fields the .csys or the history still use,
      # so the importer can create them before the .csys import.
      def custom_fields
        used = @plan.kept_fields.keys.to_set
        %w[Project Version Principal User TimeEntry].each do |type|
          table('custom_values').each do |row|
            next unless row['customized_type'] == type && !row['value'].to_s.empty?

            field = @plan.custom_field(row['custom_field_id'])
            next if field.nil? || [Rules::PROJECT_CODE_FIELD, Rules::PROJECT_REPORT_CODE_FIELD].include?(field['name']) ||
                    Rules::DROPPED_PROJECT_FIELDS.key?(field['name'])

            used << field['id']
          end
        end
        links = table('custom_fields_trackers').group_by { |row| row['custom_field_id'] }
        role_links = table('custom_fields_roles').group_by { |row| row['custom_field_id'] }
        project_links = table('custom_fields_projects').group_by { |row| row['custom_field_id'] }
        role_names = table('roles').to_h { |row| [row['id'], row['name']] }
        used.sort.map do |id|
          field = @plan.custom_field(id)
          {
            'id' => id, 'type' => field['type'], 'name' => field['name'], 'field_format' => field['field_format'],
            'possible_values' => Rules.yaml_list(field['possible_values']), 'multiple' => field['multiple'],
            'is_required' => field['is_required'], 'is_for_all' => field['is_for_all'], 'is_filter' => field['is_filter'],
            'searchable' => field['searchable'], 'default_value' => field['default_value'],
            'description' => field['description'], 'visible' => field['visible'], 'editable' => field['editable'],
            'regexp' => field['regexp'], 'min_length' => field['min_length'], 'max_length' => field['max_length'],
            'format_store' => field['format_store'], 'position' => field['position'],
            'computed' => field.key?('is_computed') ? field['is_computed'] : nil, 'formula' => field['formula'],
            'trackers' => Array(links[id]).filter_map { |link| @plan.mapped_tracker_name(@plan.tracker_name(link['tracker_id'])) }.uniq.sort,
            'roles' => Array(role_links[id]).filter_map { |link| role_names[link['role_id']] }.sort,
            'projects' => Array(project_links[id]).filter_map { |link| @plan.project(link['project_id'])&.fetch('identifier') }.sort
          }
        end
      end

      def items
        @plan.items.values.map do |item|
          issue = item.issue || {}
          wrapped = item.synthetic? && @plan.items[item.key.sub(/\Aitem:(group|datum)-/, 'item:')]
          origin = (issue.empty? && wrapped ? wrapped.issue : issue) || {}
          {
            'id' => item.source_id.is_a?(Integer) ? item.source_id : nil, 'key' => item.key,
            'project_id' => item.project_id, 'csid' => item.csid, 'synthetic' => item.synthetic,
            'tracker' => item.tracker.fetch('name'),
            'author_id' => item.author_id, 'assigned_to_id' => issue['assigned_to_id'],
            'fixed_version_id' => issue['fixed_version_id'], 'category_id' => issue['category_id'],
            'created_on' => origin['created_on'], 'updated_on' => origin['updated_on'], 'closed_on' => issue['closed_on'],
            'status_id' => issue['status_id']
          }
        end.sort_by { |row| row['key'] }.each_with_index.map { |row, index| row.merge('id' => row['id'] || -(index + 1)) }
      end

      def documents
        @plan.documents.values.map do |document|
          { 'id' => document.key, 'project_id' => document.project_id, 'title' => document.title,
            'created_on' => document.created_on, 'source_document_id' => document.source_document_id }
        end
      end

      # The .csys import creates each container's attachments in this order,
      # so (container, ordinal) finds them again in the new instance.
      def attachments
        containers = {}
        @plan.items.each_value do |item|
          next if item.synthetic?

          @plan.attachments_of('Issue', item.source_id).each_with_index { |id, index| containers[id] = ['item', item.key, index] }
        end
        @plan.documents.each_value do |document|
          document.attachment_ids.each_with_index { |id, index| containers[id] ||= ['document', document.key, index] }
        end
        table('wiki_pages').each do |page|
          @plan.attachments_of('WikiPage', page['id']).each_with_index { |id, index| containers[id] = ['wiki_page', page['id'], index] }
        end
        table('attachments').map do |row|
          container = containers[row['id']]
          index = @source.asset_index[row['id']] || {}
          {
            'id' => row['id'], 'container' => container&.first, 'container_key' => container && container[1],
            'ordinal' => container && container[2], 'filename' => row['filename'], 'sha256' => index['sha256'],
            'author_id' => row['author_id'], 'created_on' => row['created_on'], 'description' => row['description'],
            'downloads' => row['downloads'], 'migrated' => !container.nil?
          }
        end
      end

      def journals
        @details = []
        notes_dropped = 0
        document_journals = 0
        details_by_journal = table('journal_details').group_by { |row| row['journal_id'] }
        rows = table('journals').sort_by { |row| row['id'] }.filter_map do |journal|
          next unless journal['journalized_type'] == 'Issue'

          if @plan.absorbed.key?(journal['journalized_id'])
            document_journals += 1
            next
          end
          item = @plan.item_for_issue(journal['journalized_id'])
          unless item
            @report.add('history_journal_dropped', "journal ##{journal['id']}", reason: 'its item is not in the source')
            next
          end
          details = Array(details_by_journal[journal['id']]).sort_by { |row| row['id'] }.filter_map do |detail|
            translate_detail(item, journal, detail)
          end
          notes = Rules.clean(journal['notes']).to_s
          if notes.strip.empty? && details.empty?
            notes_dropped += 1
            @report.add('history_journal_dropped', "journal ##{journal['id']}", item: item.key,
                                                                              reason: 'no translatable change left')
            next
          end
          @details.concat(details)
          {
            'id' => journal['id'], 'item_key' => item.key, 'user_id' => journal['user_id'],
            'notes' => references(notes, "journal ##{journal['id']}"), 'private_notes' => journal['private_notes'],
            'created_on' => journal['created_on']
          }
        end
        @report.add('history_journal_document', nil, journals: document_journals) if document_journals.positive?
        rows
      end

      def translate_detail(item, journal, detail)
        property = detail['property']
        key = detail['prop_key'].to_s
        base = { 'id' => detail['id'], 'journal_id' => journal['id'], 'property' => property, 'prop_key' => key,
                 'prop_ref' => nil, 'value_ref' => nil, 'old_value' => detail['old_value'], 'value' => detail['value'] }
        case property
        when 'attr'
          if ATTR_REFS.key?(key)
            base.merge('value_ref' => ATTR_REFS.fetch(key))
          elsif key == 'description'
            base.merge('old_value' => references(detail['old_value'], "detail ##{detail['id']}"),
                       'value' => references(detail['value'], "detail ##{detail['id']}"))
          elsif ATTR_LITERALS.include?(key)
            base
          else
            drop(detail, item, "attribute #{key} has no current equivalent")
          end
        when 'cf'
          translate_custom_field_detail(item, detail, base)
        when 'attachment'
          base.merge('prop_ref' => 'attachments')
        when 'relation'
          other = (detail['value'] || detail['old_value']).to_i
          if @plan.absorbed.key?(other)
            drop(detail, item, 'relation with an AD/RD/CD item, now a catalog reference')
          elsif !@plan.item_for_issue(other)
            drop(detail, item, "relation with item ##{other}, not in the source")
          elsif %w[blocks blocked].include?(key) && @plan.poris_item?(item) && @plan.poris_item?(@plan.item_for_issue(other))
            # The relation itself is reversed for cosmosys_poris; its history follows.
            base.merge('value_ref' => 'items', 'prop_key' => key == 'blocks' ? 'blocked' : 'blocks')
          else
            base.merge('value_ref' => 'items')
          end
        else
          drop(detail, item, "unknown detail property #{property}")
        end
      end

      def translate_custom_field_detail(item, detail, base)
        field = @plan.custom_field(detail['prop_key'].to_i)
        return drop(detail, item, "custom field ##{detail['prop_key']} no longer exists in the source") unless field

        name = field['name']
        if (native = Rules::NATIVE_ISSUE_FIELDS[name])
          return drop(detail, item, "#{name} on an item that is not a requirement") if native['requirement'] && item.profile != 'requirement'

          mapped = lambda do |value|
            next nil if value.nil?

            native['map'] ? (native['map'][value.to_s] || value) : value
          end
          return base.merge('property' => 'attr', 'prop_key' => native['field'],
                            'old_value' => mapped.call(detail['old_value']), 'value' => mapped.call(detail['value']))
        end
        if Rules::DROPPED_ISSUE_FIELDS.key?(name) || Rules::DATUM_FIELDS.include?(name)
          return drop(detail, item, "#{name}: #{Rules::DROPPED_ISSUE_FIELDS[name] || 'turned into project data'}")
        end
        if Rules::DOCUMENT_REFERENCE_FIELDS.key?(name) && !@plan.kept_fields.key?(field['id'])
          return drop(detail, item, "#{name} became catalog references")
        end
        @plan.kept_fields[field['id']] ||= field
        reference = { 'user' => 'users', 'version' => 'versions' }[field['field_format']]
        base.merge('prop_ref' => 'custom_fields', 'prop_key' => field['id'].to_s, 'value_ref' => reference)
      end

      def drop(detail, item, reason)
        @report.add('history_detail_dropped', "detail ##{detail['id']}", item: item.key, reason: reason)
        nil
      end

      # Every "#id" of a migrated item becomes a placeholder the importer
      # replaces with the new id; unknown items are escaped.
      def references(text, subject)
        return text if text.nil?

        text.to_s.gsub(/(?<![A-Za-z0-9_!&-])#(\d+)(?![A-Za-z0-9_-])/) do
          id = Regexp.last_match(1).to_i
          if @plan.item_for_issue(id)
            "##{Plan::PLACEHOLDER}#{id}"
          else
            @report.add('reference_neutralized', subject, reference: id)
            "!##{id}"
          end
        end
      end

      def wiki_pages
        wikis = table('wikis').to_h { |row| [row['id'], row['project_id']] }
        contents = table('wiki_contents').to_h { |row| [row['page_id'], row] }
        titles = table('wiki_pages').to_h { |row| [row['id'], row['title']] }
        table('wiki_pages').map do |row|
          content = contents[row['id']] || {}
          {
            'id' => row['id'], 'project_id' => wikis[row['wiki_id']], 'title' => row['title'],
            'parent_title' => row['parent_id'] && titles[row['parent_id']], 'created_on' => row['created_on'],
            'protected' => row['protected'], 'current_version' => content['version'],
            'current_author_id' => content['author_id'], 'current_comments' => content['comments'],
            'current_updated_on' => content['updated_on'],
            'current_text' => references(Rules.clean(content['text']), "wiki page ##{row['id']}")
          }
        end
      end

      def wiki_versions
        versions = table('wiki_content_versions')
        versions.group_by { |row| row['page_id'] }.each do |page_id, rows|
          numbers = rows.map { |row| row['version'] }
          missing = (1..numbers.max).to_a - numbers
          @report.add('wiki_version_gap', "wiki page ##{page_id}", missing: missing) if missing.any?
        end
        versions.map do |row|
          {
            'id' => row['id'], 'page_id' => row['page_id'], 'version' => row['version'], 'author_id' => row['author_id'],
            'comments' => Rules.clean(row['comments']), 'updated_on' => row['updated_on'],
            'text' => references(Rules.clean(decompress(row)), "wiki version ##{row['id']}")
          }
        end
      end

      def decompress(row)
        data = row['data'].to_s
        row['compression'].to_s == 'gzip' ? Zlib::Inflate.inflate(data) : data
      end

      def wiki_redirects
        wikis = table('wikis').to_h { |row| [row['id'], row['project_id']] }
        table('wiki_redirects').map do |row|
          { 'id' => row['id'], 'project_id' => wikis[row['wiki_id']], 'title' => row['title'],
            'redirects_to' => row['redirects_to'], 'redirects_to_project_id' => wikis[row['redirects_to_wiki_id']],
            'created_on' => row['created_on'] }
        end
      end

      def time_entries
        table('time_entries').map do |row|
          item = row['issue_id'] && @plan.item_for_issue(row['issue_id'])
          row.slice('id', 'project_id', 'user_id', 'author_id', 'hours', 'comments', 'spent_on', 'created_on', 'updated_on')
             .merge('item_key' => item&.key, 'activity_id' => row['activity_id'],
                    'custom_values' => custom_values('TimeEntry', row['id']))
        end
      end

      def watchers
        pages = table('wiki_pages').map { |row| row['id'] }.to_set
        table('watchers').filter_map do |row|
          target = case row['watchable_type']
                   when 'Issue' then @plan.item_for_issue(row['watchable_id'])&.key
                   when 'WikiPage' then pages.include?(row['watchable_id']) ? "wiki_page:#{row['watchable_id']}" : nil
                   end
          unless target
            @report.add('unsupported_content', "watcher ##{row['id']}", type: row['watchable_type'])
            next
          end
          { 'id' => row['id'], 'target' => target, 'user_id' => row['user_id'] }
        end
      end

      def relations
        @plan.cross_relations.map do |row|
          { 'id' => row['source_id'], 'from' => row['from'], 'to' => row['to'], 'type' => row['type'], 'delay' => row['delay'] }
        end
      end

      def deferred_values
        @plan.deferred_values.each_with_index.map { |row, index| row.merge('id' => index + 1) }
      end
    end
  end
end
