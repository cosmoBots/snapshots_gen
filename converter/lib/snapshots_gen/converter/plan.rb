# frozen_string_literal: true

require 'set'
require_relative 'rules'
require_relative '../text_links'
require_relative 'text_checks'

module SnapshotsGen
  module Converter
    # Every decision of a conversion, taken once from the legacy snapshot and
    # shared by the .csys builder and the history builder.
    class Plan
      Item = Struct.new(:key, :source_id, :issue, :project_id, :tracker, :profile, :parent_key, :csid, :csidnum,
                        :position, :status, :synthetic, :subject, :description, :profile_fields, :author_id,
                        :sort_order, :custom_fields, keyword_init: true) do
        def synthetic?
          !synthetic.nil?
        end
      end
      Document = Struct.new(:key, :project_id, :title, :description, :category, :external_code, :version, :date,
                            :source_document_id, :source_item_ids, :attachment_ids, :created_on, keyword_init: true)
      CatalogEntry = Struct.new(:document_key, :project_id, :family, :position, :source_item_id, :references, keyword_init: true)

      attr_reader :source, :report, :projects, :items, :items_by_source_id, :documents, :catalog,
                  :relations, :cross_relations, :absorbed, :kept_fields, :deferred_values, :roots

      def initialize(source, report)
        @source = source
        @report = report
        @text_counts = Hash.new(0)
      end

      def build!
        index!
        check_text_formatting!
        plan_projects!
        plan_items!
        plan_documents!
        plan_hierarchy!
        plan_data!
        plan_identities!
        report_data_sections!
        report_generated_items!
        plan_positions!
        plan_catalog_and_relations!
        plan_fields!
        plan_references!
        report_source_gaps!
        self
      end

      # --- lookups -----------------------------------------------------------

      def by_id(name)
        source.table(name).to_h { |row| [row.fetch('id'), row] }
      end

      def tracker_name(id)
        @trackers[id]&.fetch('name')
      end

      def status_name(id)
        @statuses[id]&.fetch('name')
      end

      def enumeration_name(id)
        @enumerations[id]&.fetch('name')
      end

      def custom_field(id)
        @custom_fields[id]
      end

      def user(id)
        @users[id]
      end

      # Login of a user, name of a group, nil for the anonymous user.
      def principal_name(id)
        principal = @users[id]
        return nil unless principal

        case principal['type']
        when 'User' then principal['login'].to_s.empty? ? nil : principal['login']
        when 'Group' then principal['lastname']
        end
      end

      def project(id)
        @projects[id]
      end

      def issue(id)
        @issues[id]
      end

      def values(type, id)
        @values[[type, id]] || {}
      end

      def version(id)
        @versions[id]
      end

      def category(id)
        @categories[id]
      end

      def mapped_status(name)
        return nil if name.nil?

        Rules::STATUSES.key?(name) ? Rules::STATUSES[name] : name
      end

      def mapped_tracker_name(old_name)
        return Rules::REQUIREMENT.fetch('name') if old_name == Rules::REQUIREMENT_TRACKER

        (Rules::TRACKERS[old_name] || { 'name' => old_name }).fetch('name')
      end

      def item_for_issue(issue_id)
        @items_by_source_id[issue_id]
      end

      def root_of(project_id)
        @root_of.fetch(project_id)
      end

      def project_identifier(project_id)
        @projects.fetch(project_id).fetch('identifier')
      end

      def text_formatting
        source.content.dig('source', 'settings', 'text_formatting').to_s
      end

      private

      def index!
        @trackers = by_id('trackers')
        @statuses = by_id('issue_statuses')
        @enumerations = by_id('enumerations')
        @custom_fields = by_id('custom_fields')
        @users = by_id('users')
        @projects = by_id('projects')
        @issues = by_id('issues')
        @versions = by_id('versions')
        @categories = by_id('issue_categories')
        @cosmosys_issues = source.table('cosmosys_issues').to_h { |row| [row['issue_id'], row] }
        @cosmosys_projects = source.table('cosmosys_projects').to_h { |row| [row['project_id'], row] }
        @values = {}
        source.table('custom_values').sort_by { |row| row.fetch('id') }.each do |row|
          field = @custom_fields[row['custom_field_id']]
          next unless field

          slot = (@values[[row['customized_type'], row['customized_id']]] ||= {})
          if field['multiple']
            (slot[field['name']] ||= []) << row['value'] unless row['value'].to_s.empty?
          else
            slot[field['name']] = row['value']
          end
        end
      end

      def check_text_formatting!
        formatting = text_formatting
        report.add('text_formatting', nil, value: formatting)
        report.add('textile_source', nil, value: formatting) if formatting == 'textile'
      end

      def plan_projects!
        @root_of = {}
        @projects.each_key do |id|
          root = id
          seen = Set.new
          while (parent = @projects[root]['parent_id']) && @projects.key?(parent) && seen.add?(root)
            root = parent
          end
          @root_of[id] = root
        end
        @roots = @projects.keys.select { |id| @root_of[id] == id }.sort
        used = {}
        @project_codes = {}
        @projects.values.sort_by { |row| row['id'] }.each do |row|
          raw = [values('Project', row['id'])[Rules::PROJECT_CODE_FIELD], @cosmosys_projects[row['id']]&.fetch('prefix', nil),
                 row['identifier']].find { |candidate| !candidate.to_s.strip.empty? }
          code = Rules.normalize_code(raw)
          code = Rules.normalize_code(row['identifier']).upcase if code.empty?
          report.add('project_code_normalized', row['identifier'], from: raw, to: code) if code != raw.to_s
          if used[code.downcase]
            renamed = "#{code}#{row['id']}"
            report.add('project_code_collision', row['identifier'], from: code, to: renamed,
                                                                    other: used[code.downcase])
            code = renamed
          end
          used[code.downcase] = row['identifier']
          @project_codes[row['id']] = code
        end
        @projects_with_requirements = source.table('issues').select { |issue| tracker_name(issue['tracker_id']) == Rules::REQUIREMENT_TRACKER }
                                            .map { |issue| issue['project_id'] }.to_set
      end

      public

      def project_code(project_id)
        @project_codes.fetch(project_id)
      end

      def project_profile(project_id)
        @projects_with_requirements.include?(project_id) ? 'requirements' : 'items'
      end

      private

      def target_tracker(issue)
        name = tracker_name(issue['tracker_id'])
        if name == Rules::REQUIREMENT_TRACKER
          values('Issue', issue['id'])['rqType'] == 'Info' ? Rules::INFO_TRACKER : Rules::REQUIREMENT
        else
          Rules::TRACKERS[name] || { 'key' => name, 'name' => name, 'item_profile' => nil }
        end
      end

      def plan_items!
        @items = {}
        @items_by_source_id = {}
        @absorbed = {}
        renamed = Hash.new(0)
        @issues.values.sort_by { |row| row['id'] }.each do |issue|
          tracker = target_tracker(issue)
          old_tracker = tracker_name(issue['tracker_id'])
          if [Rules::REQUIREMENT_TRACKER, 'csInfo'].include?(old_tracker) && Rules.document_reference(issue['subject'])
            @absorbed[issue['id']] = Rules.document_reference(issue['subject']).merge('project_id' => issue['project_id'])
            next
          end
          renamed[[old_tracker, tracker['name']]] += 1 if old_tracker != tracker['name']
          cosmosys = @cosmosys_issues[issue['id']] || {}
          item = Item.new(
            key: "item:#{issue['id']}", source_id: issue['id'], issue: issue, project_id: issue['project_id'],
            tracker: tracker, profile: tracker['item_profile'] || 'normal',
            status: mapped_status(status_name(issue['status_id'])),
            subject: Rules.clean(issue['subject']), description: Rules.clean(issue['description']).to_s,
            author_id: issue['author_id'], sort_order: [cosmosys['chapter_order'] || Float::INFINITY, issue['id']]
          )
          @items[item.key] = item
          @items_by_source_id[issue['id']] = item
        end
        renamed.each { |(from, to), count| report.add('tracker_mapped', "#{from} -> #{to}", items: count) }
        statuses = Hash.new(0)
        @issues.each_value do |issue|
          next if @absorbed.key?(issue['id'])

          name = status_name(issue['status_id'])
          statuses[name] += 1 if mapped_status(name) != name
        end
        statuses.each { |name, count| report.add('status_mapped', "#{name} -> #{mapped_status(name) || '(tracker default)'}", items: count) }
      end

      def plan_documents!
        @documents = {}
        @catalog = []
        source.table('documents').sort_by { |row| row['id'] }.each do |row|
          @documents["document:#{row['id']}"] = Document.new(
            key: "document:#{row['id']}", project_id: row['project_id'], title: Rules.clean(row['title']),
            description: Rules.clean(row['description']).to_s, category: enumeration_name(row['category_id']),
            source_document_id: row['id'], source_item_ids: [], attachment_ids: attachments_of('Document', row['id']),
            created_on: row['created_on']
          )
        end
        # The pipeline's rule: a project's AD/RD/CD items become documents;
        # equal titles in different families share one document.
        @absorbed.keys.group_by { |id| @absorbed[id]['project_id'] }.each do |project_id, ids|
          by_title = {}
          families_by_key = Hash.new { |hash, key| hash[key] = [] }
          ids.sort_by { |id| [@absorbed[id]['family'], @absorbed[id]['position'], id] }.each do |id|
            issue = @issues.fetch(id)
            entry = @absorbed.fetch(id)
            title = Rules.clean(issue['description']).to_s.strip.gsub(/\s+/, ' ')
            title = Rules.clean(issue['subject']).to_s.strip if title.empty?
            key = by_title[title.downcase]
            key = nil if key && families_by_key[key].include?(entry['family'])
            unless key
              key = "document:legacy-#{id}"
              metadata = Rules.document_metadata(title)
              rationale = Rules.clean(values('Issue', id)['rqRationale']).to_s.strip
              @documents[key] = Document.new(
                key: key, project_id: project_id, title: metadata['title'][0, 255], description: rationale,
                category: nil, external_code: metadata['external_code'], version: metadata['version'],
                date: metadata['date'], source_item_ids: [], attachment_ids: [], created_on: issue['created_on']
              )
              extracted = metadata.slice('external_code', 'version', 'date').compact
              report.add('document_metadata_extracted', title, **extracted.transform_keys(&:to_sym)) if extracted.any?
              by_title[title.downcase] = key
            end
            families_by_key[key] << entry['family']
            document = @documents.fetch(key)
            document.source_item_ids << id
            document.attachment_ids.concat(attachments_of('Issue', id))
            entry['document_key'] = key
            @catalog << CatalogEntry.new(document_key: key, project_id: project_id, family: entry['family'],
                                         position: entry['position'], source_item_id: id, references: [])
            report.add('document_item_absorbed', "##{id} #{issue['subject']}", document: document.title,
                                                                             project: project_identifier(project_id))
          end
        end
      end

      public

      # Present attachments of a container, in id order (the order in which
      # the .csys import creates them).
      def attachments_of(type, id)
        @attachments_by_container ||= source.table('attachments').group_by { |row| [row['container_type'], row['container_id']] }
        @present_attachments ||= {}
        @present_attachments[[type, id]] ||= Array(@attachments_by_container[[type, id]]).sort_by { |row| row['id'] }.filter_map do |row|
          index = source.asset_index[row['id']]
          if index && index['status'] == 'present'
            row['id']
          else
            report.add('attachment_missing', "#{type} ##{id}", attachment: row['id'], filename: row['filename'])
            nil
          end
        end
      end

      private

      # Parents, after absorbing document items and wrapping items whose
      # current profile cannot hold their children.
      def plan_hierarchy!
        parent_of = {}
        @items.each_value do |item|
          parent = item.issue['parent_id']
          parent = @issues[parent]&.fetch('parent_id') while parent && @absorbed.key?(parent)
          parent_item = parent && @items_by_source_id[parent]
          parent_item = nil if parent_item && root_of(parent_item.project_id) != root_of(item.project_id)
          if parent && parent_item.nil?
            report.add('unsupported_content', item.key, reason: 'parent outside the project tree', parent: parent)
          end
          parent_of[item.key] = parent_item&.key
        end
        children = parent_of.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(child, parent), result|
          result[parent] << child if parent
        end
        wrapped = children.keys.select do |parent_key|
          parent = @items.fetch(parent_key)
          Rules::CHILDLESS.include?(parent.profile) ||
            (parent.profile != 'info' && children[parent_key].any? { |child| Rules::INFO_PARENT_ONLY.include?(@items.fetch(child).profile) })
        end.to_set
        wrapper_key = ->(key) { "item:group-#{@items.fetch(key).source_id}" }
        @items.each_value do |item|
          parent = parent_of[item.key]
          item.parent_key = if wrapped.include?(item.key)
                              wrapper_key.call(item.key)
                            elsif parent && wrapped.include?(parent)
                              wrapper_key.call(parent)
                            else
                              parent
                            end
        end
        wrapped.each do |key|
          wrapped_item = @items.fetch(key)
          parent = parent_of[key]
          wrapper = Item.new(
            key: wrapper_key.call(key), source_id: "group-#{wrapped_item.source_id}", project_id: wrapped_item.project_id,
            tracker: Rules::INFO_TRACKER, profile: 'info', status: nil, synthetic: 'group',
            parent_key: parent && (wrapped.include?(parent) ? wrapper_key.call(parent) : parent),
            subject: "Group: #{wrapped_item.subject}",
            description: "Chapter generated by the migration around ##{wrapped_item.source_id}, " \
                         'because the current item profile cannot have children.',
            author_id: wrapped_item.author_id, sort_order: wrapped_item.sort_order
          )
          wrapped_item.sort_order = [-Float::INFINITY, 0]
          @items[wrapper.key] = wrapper
          report.add('synthetic_chapter', wrapper.subject, around: wrapped_item.key, profile: wrapped_item.profile,
                                                           children: children[key].length)
        end
      end

      # rqVar and rqValue of requirements become datum items, under one data
      # section per project, as cosmosys_req's own schema migration does. A
      # variable key cosmoSys would refuse (invalid, or repeated in the tree)
      # cannot be a datum: that requirement keeps rqVar and rqValue as custom
      # fields (plan_fields!), like any field without a current equivalent,
      # and so does an rqValue without rqVar. A project left without data gets
      # no data section.
      def plan_data!
        @datum_keys = {}
        @datum_numbers = Hash.new(0)
        @datum_sources = Set.new
        by_project = Hash.new { |hash, key| hash[key] = [] }
        @items.each_value do |item|
          next if item.synthetic? || item.profile != 'requirement'

          fields = values('Issue', item.source_id)
          name = Rules.clean(fields['rqVar']).to_s.strip
          value = Rules.clean(fields['rqValue']).to_s
          if name.empty?
            unless value.strip.empty?
              report.add('datum_field_kept', item.key, variable: nil, value: value, reason: 'rqValue without rqVar')
            end
            next
          end

          tree_key = [root_of(item.project_id), name.downcase]
          reason = if !name.match?(/\A[A-Za-z][A-Za-z0-9_]*\z/) then 'invalid variable key'
                   elsif @datum_keys.key?(tree_key) then 'variable key repeated in the project tree'
                   end
          if reason
            report.add('datum_field_kept', item.key, variable: name, value: value, reason: reason)
            next
          end
          @datum_keys[tree_key] = true
          by_project[item.project_id] << [item, name, value]
        end
        by_project.each do |project_id, entries|
          section = Item.new(
            key: "item:data-#{project_id}", source_id: "data-#{project_id}", project_id: project_id,
            tracker: Rules::DATA_SECTION, profile: 'data_section', status: nil, synthetic: 'data_section',
            parent_key: nil, subject: 'Project data', description: '', author_id: entries.first.first.author_id,
            sort_order: [Float::INFINITY, Float::INFINITY], profile_fields: { 'report_placeholder_kind' => 'project_data' }
          )
          @items[section.key] = section
          entries.each do |requirement, name, value|
            # cosmoSys numbers user-defined identities downwards from -1 per tree.
            @datum_numbers[root_of(project_id)] -= 1
            datum = Item.new(
              key: "item:datum-#{requirement.source_id}", source_id: "datum-#{requirement.source_id}",
              project_id: project_id, tracker: Rules::DATUM, profile: 'datum', status: nil, synthetic: 'datum',
              parent_key: section.key, subject: name, csid: name, csidnum: @datum_numbers[root_of(project_id)],
              description: "Variable migrated from requirement ##{requirement.source_id}.",
              author_id: requirement.author_id, sort_order: requirement.sort_order,
              profile_fields: { 'csys_value' => value }
            )
            @items[datum.key] = datum
            @datum_sources << requirement.key
            report.add('datum_created', datum.key, variable: name, value: value, requirement: requirement.key)
          end
        end
      end

      # The "Project data" chapters exist only in the new instance; once
      # their CSID is known, the report names them.
      def report_data_sections!
        @items.each_value.select { |item| item.synthetic == 'data_section' }.each do |section|
          report.add('data_section_created', section.key, project: project_identifier(section.project_id), csid: section.csid,
                                                          data: @items.each_value.count { |item| item.parent_key == section.key })
        end
      end

      # Every item that exists only in the new instance, with its final CSID,
      # so a checker can tell it from a migrated item without reading this
      # code: "Group: ..." chapters (from = the item they wrap), "Project
      # data" chapters and their data (from = the requirement). Source items
      # keep their identity_* entries.
      def report_generated_items!
        @items.each_value.select(&:synthetic?).sort_by(&:key).each do |item|
          from = case item.synthetic
                 when 'group', 'datum' then item.key.sub(/\Aitem:(group|datum)-/, 'item:')
                 end
          report.add('item_generated', item.key, kind: item.synthetic, project: project_identifier(item.project_id),
                                                 csid: item.csid, from: from)
        end
      end

      # Identities: an old CSID is kept whenever it is unique within its
      # project tree, even when its prefix belongs to another project (the item
      # was moved): cosmoSys only requires uniqueness per tree, and people cite
      # these identifiers. A prefix cosmoSys does not accept (only letters and
      # digits) is rewritten: with the normalized code when it was the
      # project's own code, and with the same rule (its other characters
      # removed) when it is the prefix of another project, so ABC-X-0007 becomes
      # ABCX-0007 wherever the item lives. A rewritten CSID that collides with
      # another one of its tree is blocking. Items without a usable CSID take
      # the next number of their project.
      def plan_identities!
        used = Hash.new { |hash, key| hash[key] = Set.new }
        owners = Hash.new { |hash, key| hash[key] = {} }
        candidates = {}
        @items.values.reject { |item| item.profile == 'datum' || item.synthetic? }.sort_by(&:source_id).each do |item|
          identifier = @cosmosys_issues.dig(item.source_id, 'identifier').to_s
          match = identifier.match(/\A(.+)-(\d+)\z/)
          next unless match

          raw_code = values('Project', item.project_id)[Rules::PROJECT_CODE_FIELD].to_s
          prefix = match[1]
          if !raw_code.empty? && prefix.casecmp?(raw_code)
            prefix = project_code(item.project_id)
          elsif !prefix.match?(Rules::CODE_PATTERN)
            prefix = Rules.normalize_code(prefix)
          end
          csid = "#{prefix}-#{match[2]}"
          tree = root_of(item.project_id)
          normalized = csid != identifier
          other = owners[tree][csid.downcase]
          if other && (normalized || other['normalized'])
            report.add('identity_normalized_collision', item.key, from: identifier, to: csid, other: other['item'],
                                                                  other_from: other['original'])
          end
          next unless used[tree].add?(csid.downcase)

          owners[tree][csid.downcase] = { 'item' => item.key, 'original' => identifier, 'normalized' => normalized }
          candidates[item.key] = { 'original' => identifier, 'csid' => csid, 'number' => match[2].to_i,
                                   'own' => prefix.casecmp?(project_code(item.project_id)) }
        end
        @items.values.reject { |item| item.profile == 'datum' }.group_by(&:project_id).each do |project_id, project_items|
          code = project_code(project_id)
          tree = root_of(project_id)
          maximum = candidates.values_at(*project_items.map(&:key)).compact.select { |entry| entry['own'] }
                              .map { |entry| entry['number'] }.max.to_i
          project_items.sort_by { |item| [item.synthetic? ? 1 : 0, item.source_id.is_a?(Integer) ? item.source_id : 0, item.key] }.each do |item|
            entry = candidates[item.key]
            if entry
              item.csid = entry['csid']
              item.csidnum = entry['number']
              if entry['original'] != entry['csid']
                report.add('identity_prefix_normalized', item.key, from: entry['original'], to: item.csid)
              elsif !entry['own']
                report.add('identity_foreign_prefix_kept', item.key, csid: item.csid, project: project_identifier(project_id))
              end
              next
            end
            loop do
              maximum += 1
              break if used[tree].add?(format('%s-%04d', code, maximum).downcase)
            end
            item.csid = format('%s-%04d', code, maximum)
            item.csidnum = maximum
            next if item.synthetic?

            original = @cosmosys_issues.dig(item.source_id, 'identifier')
            report.add('identity_renumbered', item.key, from: original, to: item.csid)
          end
        end
        check_future_numbers!
      end

      # cosmoSys gives a new item of a project the next number after the
      # highest one among the project's items with its own code
      # (ProjectMaterializationIdentity#local_maximum, then cslast_id + 1),
      # and a CSID must be unique in the whole tree. An item of another
      # project of the tree with that code and a higher number (a moved item,
      # or one whose prefix lost its dashes) would make the creation of new
      # items fail there once the numbering reaches it.
      def check_future_numbers!
        items = @items.values.reject { |item| item.profile == 'datum' || item.csid.to_s.empty? }
        items.group_by { |item| root_of(item.project_id) }.each_value do |tree_items|
          tree_items.map(&:project_id).uniq.each do |project_id|
            code = project_code(project_id)
            own = ->(item) { item.csid.to_s.match(/\A(.+)-(\d+)\z/)&.then { |m| m[1].casecmp?(code) ? m[2].to_i : nil } }
            last = tree_items.select { |item| item.project_id == project_id }.filter_map(&own).max.to_i
            tree_items.each do |item|
              number = own.call(item)
              next unless item.project_id != project_id && number && number > last

              report.add('identity_future_collision', item.key, csid: item.csid, project: project_identifier(project_id),
                                                               next_number: last + 1)
            end
          end
        end
      end

      def plan_positions!
        @items.values.group_by { |item| [item.project_id, item.parent_key] }.each_value do |siblings|
          siblings.sort_by { |item| [item.sort_order.first, item.sort_order.last.is_a?(Numeric) ? item.sort_order.last : 0, item.key] }
                  .each_with_index { |item, index| item.position = index + 1 }
        end
      end

      def plan_catalog_and_relations!
        @relations = []
        @cross_relations = []
        @reversed_poris_relations = 0
        entries_by_item = @catalog.to_h { |entry| [entry.source_item_id, entry] }
        text_authority = Set.new
        reference_count = 0
        @items.each_value do |item|
          next if item.synthetic?

          fields = values('Issue', item.source_id)
          Rules::DOCUMENT_REFERENCE_FIELDS.each do |field, family|
            Rules.document_reference_lines(fields[field]).each do |line|
              entry = catalog_entry_for(item.project_id, family, line['position']) ||
                      foreign_catalog_entry(item, family, line['position'])
              next unless entry

              entry.references << { 'item' => item.key, 'sense' => line['sense'][0, 255], 'location' => line['location'][0, 255] }
              text_authority << [item.source_id, family]
              reference_count += 1
            end
          end
        end
        source.table('issue_relations').sort_by { |row| row['id'] }.each do |relation|
          from_doc = @absorbed[relation['issue_from_id']]
          to_doc = @absorbed[relation['issue_to_id']]
          from = @items_by_source_id[relation['issue_from_id']]
          to = @items_by_source_id[relation['issue_to_id']]
          if from_doc || to_doc
            if from_doc && to_doc
              report.add('relation_to_document', "relation ##{relation['id']}", reason: 'document to document, dropped')
              next
            end
            item = from || to
            doc_id = from_doc ? relation['issue_from_id'] : relation['issue_to_id']
            entry = entries_by_item.fetch(doc_id)
            if text_authority.include?([item.source_id, entry.family])
              report.add('relation_to_document', "relation ##{relation['id']}", reason: 'the item text already lists the reference')
              next
            end
            target = entry.project_id == item.project_id ? entry : foreign_catalog_entry(item, entry.family, entry.position, entry)
            target.references << { 'item' => item.key, 'sense' => '', 'location' => '' }
            reference_count += 1
            report.add('relation_to_document', "relation ##{relation['id']}", item: item.key, document: entry.document_key)
            next
          end
          unless from && to
            report.add('relation_dropped', "relation ##{relation['id']}", from: relation['issue_from_id'], to: relation['issue_to_id'])
            next
          end
          row = { 'from' => from.key, 'to' => to.key, 'type' => relation['relation_type'], 'delay' => relation['delay'],
                  'source_id' => relation['id'] }
          if poris_reversed?(relation['relation_type'], from, to)
            row['from'], row['to'] = row['to'], row['from']
            @reversed_poris_relations += 1
          end
          if root_of(from.project_id) == root_of(to.project_id)
            @relations << row
          else
            @cross_relations << row
            report.add('relation_cross_package', "relation ##{relation['id']}", from: from.csid, to: to.csid)
          end
        end
        report.add('catalog_reference', nil, count: reference_count) if reference_count.positive?
        if @reversed_poris_relations.positive?
          report.add('poris_relation_reversed', nil, relations: @reversed_poris_relations)
        end
        @cosmosys_issues.each_value do |row|
          text = row['relations_on_close'].to_s
          next if text.strip.empty? || text.strip == '[]'

          begin
            parsed = Rules.parse_ruby_literal(text)
            report.add('relations_on_close', "##{row['issue_id']}", stored: parsed.length)
          rescue ArgumentError => error
            report.add('relations_on_close_unparsed', "##{row['issue_id']}", error: error.message)
          end
        end
      end

      public

      # Whether the rqVar and rqValue of this item became a datum. When not,
      # the item keeps them, with their history, as custom fields.
      def datum_source?(item)
        @datum_sources.include?(item.key)
      end

      def poris_item?(item)
        item && !item.synthetic? && Rules::PORIS_TRACKERS.include?(tracker_name(item.issue['tracker_id']))
      end

      # A "blocks" relation between two old PORIS items is written the other
      # way round in the current model.
      def poris_reversed?(type, from, to)
        type == 'blocks' && poris_item?(from) && poris_item?(to)
      end

      private

      def catalog_entry_for(project_id, family, position)
        @catalog.find { |entry| entry.project_id == project_id && entry.family == family && entry.position == position }
      end

      # A catalog reference is project local: an item that refers to another
      # project's document gets a copy of that document in its own project.
      def foreign_catalog_entry(item, family, position, entry = nil)
        entry ||= @catalog.find do |candidate|
          candidate.family == family && candidate.position == position &&
            root_of(candidate.project_id) == root_of(item.project_id)
        end
        return nil unless entry
        return entry if entry.project_id == item.project_id

        copy_key = "#{entry.document_key}-p#{item.project_id}"
        unless @documents.key?(copy_key)
          original = @documents.fetch(entry.document_key)
          @documents[copy_key] = original.dup.tap do |copy|
            copy.key = copy_key
            copy.project_id = item.project_id
            copy.source_item_ids = []
            copy.attachment_ids = []
          end
        end
        existing = @catalog.find { |candidate| candidate.document_key == copy_key && candidate.family == family }
        return existing if existing

        next_position = @catalog.select { |candidate| candidate.project_id == item.project_id && candidate.family == family }
                                .map(&:position).max.to_i + 1
        copy = CatalogEntry.new(document_key: copy_key, project_id: item.project_id, family: family,
                                position: next_position, source_item_id: nil, references: [])
        @catalog << copy
        copy
      end

      # Splits each item's old custom fields into native profile fields,
      # kept custom fields and dropped ones.
      def plan_fields!
        @kept_fields = {}
        @deferred_values = []
        native_counts = Hash.new(0)
        dropped_counts = Hash.new(0)
        @items.each_value do |item|
          next if item.synthetic?

          fields = values('Issue', item.source_id)
          profile_fields = {}
          custom = []
          fields.each do |name, value|
            next if value.nil? || value == '' || value == []

            field = issue_field(name)
            next unless field

            if (native = Rules::NATIVE_ISSUE_FIELDS[name])
              if native['requirement'] && item.profile != 'requirement'
                # Redmine fills defaults in every item of the tracker; only real values are a loss.
                if name != 'rqType' && !value.to_s.strip.empty? && Array(value).map(&:to_s) != [field['default_value'].to_s]
                  report.add('field_dropped', item.key, field: name, reason: 'requirement field on an item that is not a requirement')
                end
                next
              end
              profile_fields[native['field']] = native_value(item, name, native, value)
              native_counts[name] += 1
            elsif Rules::DROPPED_ISSUE_FIELDS.key?(name) || (Rules::DATUM_FIELDS.include?(name) && datum_source?(item))
              dropped_counts[name] += 1
            elsif Rules::DOCUMENT_REFERENCE_FIELDS.key?(name)
              rest = Rules.unparsed_reference_text(value)
              next if rest.strip.empty?

              report.add('reference_text_kept', item.key, field: name)
              custom << keep_field(field, value)
            elsif %w[user version enumeration attachment].include?(field['field_format'])
              @deferred_values << { 'item' => item.key, 'field' => field['name'], 'format' => field['field_format'],
                                    'value' => value }
              @kept_fields[field['id']] = field
            else
              custom << keep_field(field, value)
            end
          end
          if item.profile == 'requirement'
            Rules::NATIVE_ISSUE_FIELDS.each_value do |native|
              next unless native['requirement'] && native['default']

              profile_fields[native['field']] ||= native['default']
            end
            profile_fields['rq_verif_methods'] ||= 'to_be_defined'
          end
          item.profile_fields = profile_fields
          item.custom_fields = custom
        end
        native_counts.each { |name, count| report.add('field_native', name, field: Rules::NATIVE_ISSUE_FIELDS.dig(name, 'field'), items: count) }
        dropped_counts.each do |name, count|
          reason = Rules::DROPPED_ISSUE_FIELDS[name] || 'turned into project data'
          report.add('field_dropped', name, items: count, reason: reason)
        end
        @kept_fields.each_value { |field| report.add('field_kept', field['name'], format: field['field_format']) }
        source.table('custom_values').select { |row| row['customized_type'] == 'Project' }.map { |row| row['custom_field_id'] }.uniq.each do |id|
          field = @custom_fields[id]
          next unless field && Rules::DROPPED_PROJECT_FIELDS.key?(field['name'])

          report.add('project_field_dropped', field['name'], reason: Rules::DROPPED_PROJECT_FIELDS[field['name']])
        end
      end

      def issue_field(name)
        @issue_fields ||= @custom_fields.values.select { |field| field['type'] == 'IssueCustomField' }.to_h { |field| [field['name'], field] }
        @issue_fields[name]
      end

      def keep_field(field, value)
        @kept_fields[field['id']] = field
        { 'id' => field['id'], 'name' => field['name'], 'format' => field['field_format'],
          'value' => field['multiple'] ? Array(value).map { |entry| Rules.clean(entry) } : Rules.clean(value) }
      end

      public

      def native_value(item, name, native, value)
        if native['multiple']
          raw = Array(value).flat_map { |entry| entry.to_s.split(/[\r\n,]+/) }.map(&:strip).reject(&:empty?)
          mapped = raw.filter_map do |entry|
            native['map'][entry] || (report.add('field_value_unmapped', item&.key, field: name, value: entry) && nil)
          end.uniq
          return mapped.empty? ? (native['field'] == 'rq_verif_methods' ? 'to_be_defined' : nil) : mapped.join(',')
        end
        return Rules.clean(value) unless native['map']

        mapped = native['map'][value.to_s]
        if mapped.nil? && item
          report.add('field_value_unmapped', item.key, field: name, value: value, used: native['default'])
        end
        mapped || native['default']
      end

      private

      # Links in every text the .csys carries: descriptions (also of the
      # generated items, which name their source item), the native text
      # fields, the kept custom fields, documents and projects. The history
      # builder does the same with the history (notes, wiki versions and the
      # values of description and field changes) through rewrite_text, so the
      # last value of a change is still the current text.
      def plan_references!
        source_host
        @items.each_value do |item|
          next if item.synthetic?

          check_text(item.description, item.key, item)
          check_text(item.subject, "#{item.key} subject", item, dialect: false)
          (item.profile_fields || {}).each do |field, value|
            check_text(value, "#{item.key} #{field}", item) if Rules::TEXT_NATIVE_FIELDS.include?(field) && value.is_a?(String)
          end
          Array(item.custom_fields).each do |entry|
            check_text(entry['value'], "#{item.key} #{entry['name']}", item) if entry['format'] == 'text' && entry['value'].is_a?(String)
          end
        end
        @documents.each_value { |document| check_text(document.description, document.key, nil) }
        @projects.each_value { |row| check_text(Rules.clean(row['description']).to_s, "project:#{row['id']}", nil) }
        @items.each_value do |item|
          root = root_of(item.project_id)
          item.description = rewrite_text(item.description, item.key, item: item, protect_root: root)
          item.profile_fields = (item.profile_fields || {}).to_h do |field, value|
            next [field, value] unless Rules::TEXT_NATIVE_FIELDS.include?(field) && value.is_a?(String)

            [field, rewrite_text(value, "#{item.key} #{field}", item: item)]
          end
          item.custom_fields = Array(item.custom_fields).map do |entry|
            entry.merge('value' => rewrite_field_value(entry['format'], entry['value'], "#{item.key} #{entry['name']}", item, root))
          end
        end
        @documents.each_value do |document|
          document.description = rewrite_text(document.description, document.key)
        end
        @project_descriptions = @projects.transform_values do |row|
          rewrite_text(Rules.clean(row['description']).to_s, "project:#{row['id']}")
        end
        other = Hash.new(0)
        @items.each_value do |item|
          item.description.scan(/(?<![A-Za-z0-9_])(r\d+\b|commit:)/) { other[Regexp.last_match(1)[/\A[a-z]+/]] += 1 }
          Rules.ambiguous_markdown_tables(item.description).each do |line|
            report.add('ambiguous_markdown_table', item.key, line: line)
          end
        end
        other.each { |kind, count| @text_counts["other:#{kind}"] += count }
      end

      public

      # Where each migrated attachment goes: { id => [container, key, ordinal] }.
      # The .csys import creates each container's attachments in this order,
      # so (container, ordinal) finds them again in the new instance.
      def attachment_containers
        return @attachment_containers if @attachment_containers

        containers = {}
        items.each_value do |item|
          next if item.synthetic?

          attachments_of('Issue', item.source_id).each_with_index { |id, index| containers[id] = ['item', item.key, index] }
        end
        documents.each_value do |document|
          document.attachment_ids.each_with_index { |id, index| containers[id] ||= ['document', document.key, index] }
        end
        source.table('wiki_pages').each do |page|
          attachments_of('WikiPage', page['id']).each_with_index { |id, index| containers[id] = ['wiki_page', page['id'], index] }
        end
        project_files.each { |id, (type, key, index)| containers[id] = [type, key, index] }
        @attachment_containers = containers
      end

      # Files of the Files module: attachments of a project, or of one of its
      # versions. The .csys has no place for them; the history importer
      # creates them. { id => ['project' | 'version', source id, ordinal] }
      def project_files
        @project_files ||= begin
          files = {}
          @projects.each_key do |project_id|
            attachments_of('Project', project_id).each_with_index { |id, index| files[id] = ['project', project_id, index] }
          end
          @versions.each_key do |version_id|
            next unless @projects.key?(@versions[version_id]['project_id'])

            attachments_of('Version', version_id).each_with_index { |id, index| files[id] = ['version', version_id, index] }
          end
          files
        end
      end

      def project_description(project_id)
        @project_descriptions.fetch(project_id)
      end

      # The old instance's host and protocol, from its settings (Redmine's
      # defaults when they were never saved). Links to it are links into the
      # old instance.
      def source_host
        @source_host ||= begin
          settings = source.table('settings').to_h { |row| [row['name'], row['value'].to_s.sub(/\A--- /, '').strip] }
          host = settings['host_name'].to_s.empty? ? 'localhost:3000' : settings['host_name']
          protocol = settings['protocol'].to_s.empty? ? 'http' : settings['protocol']
          report.add('source_host', host, protocol: protocol, stored: !settings['host_name'].to_s.empty?)
          TextLinks::Host.new(host, protocol)
        end
      end

      # The angle rule is for Redcarpet ("markdown"); code is recognized in
      # both Markdown dialects.
      def markdown_source?
        %w[markdown common_mark].include?(text_formatting)
      end

      def redcarpet_source?
        text_formatting == 'markdown'
      end

      # A text of the old instance with its links rewritten
      # (SnapshotsGen::TextLinks) and every change reported under subject.
      # protect_root: the root project of the .csys the text goes into, whose
      # item ids cosmoSys's own rewriter would take.
      def rewrite_text(text, subject, item: nil, markdown: markdown_source?, protect_root: nil)
        return text if text.nil?

        protect = protect_root && lambda do |id|
          target = @items_by_source_id[id]
          target && root_of(target.project_id) == protect_root
        end
        rewriter = TextLinks::Rewriter.new(
          item: ->(id) { @items_by_source_id.key?(id) }, user: ->(id) { @users.key?(id) },
          attachment: ->(id) { attachment_containers.key?(id) }, host: source_host, markdown: markdown,
          angle: markdown && redcarpet_source?, protect: protect
        )
        result, events = rewriter.rewrite(text)
        record_text_events(subject, item, events)
        result
      end

      # Kept custom fields: Redmine formats only text fields; cosmoSys's
      # rewriter takes string, text and link values. A link value is a URL:
      # only what that rewriter would take is protected.
      def rewrite_field_value(format, value, subject, item, root)
        return value.map { |entry| rewrite_field_value(format, entry, subject, item, root) } if value.is_a?(Array)
        return value unless value.is_a?(String)

        case format
        when 'text' then rewrite_text(value, subject, item: item, protect_root: root)
        when 'string' then rewrite_text(value, subject, item: item, markdown: false, protect_root: root)
        when 'link'
          protect = ->(id) { (target = @items_by_source_id[id]) && root_of(target.project_id) == root }
          result, count = TextLinks.protect_literals(value, protect)
          @text_counts['literal'] += count
          result
        else value
        end
      end

      def text_counts
        @text_counts
      end

      # Reports what a rendered text of the source will show differently
      # (TextChecks): Markdown dialect, only when the source used Redcarpet,
      # and formulas, only when it had a MathJax plugin. Run on the source
      # text, before any rewriting.
      def check_text(text, subject, item, dialect: true)
        return if text.to_s.strip.empty?

        where = item ? { item: item.key, csid: item.csid, project: project_identifier(item.project_id) } : {}
        if dialect && redcarpet_source?
          kinds = TextChecks.dialect_differences(text)
          report.add('markdown_dialect', subject, kinds: kinds, **where) if kinds.any?
        end
        return unless mathjax_plugin

        formulas = TextChecks.latex_formulas(text)
        report.add('latex_formula', subject, **formulas.transform_keys(&:to_sym), plugin: mathjax_plugin, **where) if formulas.any?
      end

      # The MathJax plugin of the source, if it had one: its formulas
      # ($...$, $$...$$...) are plain text in the new instance.
      def mathjax_plugin
        return @mathjax_plugin if defined?(@mathjax_plugin)

        plugin = Array(source.inventory['plugins']).find { |entry| "#{entry['id']} #{entry['name']}".match?(/mathjax|latex/i) }
        @mathjax_plugin = plugin && plugin['id']
      end

      # One entry per kind of placeholder written, after the history builder
      # has added its own.
      def report_text_counts!
        @text_counts.sort.each do |kind, count|
          if kind.start_with?('other:')
            report.add('other_references', kind.delete_prefix('other:'), count: count)
          else
            report.add('text_placeholders', kind, count: count)
          end
        end
      end

      private

      def record_text_events(subject, item, events)
        where = item ? { item: item.key, csid: item.csid } : {}
        events.each do |event|
          id = event['id']
          case event['kind']
          when 'item', 'user', 'literal' then @text_counts[event['kind']] += 1
          when 'other_reference' then @text_counts["other:#{event['prefix']}"] += 1
          when 'item_neutralized' then report.add('reference_neutralized', subject, reference: id, **where)
          when 'user_neutralized' then report.add('user_reference_neutralized', subject, reference: id, **where)
          when 'attachment', 'issue_url'
            @text_counts[event['kind'] == 'attachment' ? 'attachment' : 'item'] += 1
            report.add('instance_link_rewritten', subject, kind: event['kind'] == 'attachment' ? 'attachment' : 'item',
                                                           source_id: id, absolute: event['absolute'], form: event['form'] || 'path', **where)
          when 'attachment_broken' then report.add('attachment_link_broken', subject, attachment: id, absolute: event['absolute'], **where)
          when 'issue_url_broken' then report.add('item_link_broken', subject, reference: id, absolute: event['absolute'], **where)
          when 'old_host_kept' then report.add('old_host_link_kept', subject, url: event['url'], **where)
          when 'angle' then report.add('link_destination_bracketed', subject, destination: event['destination'], **where)
          end
        end
      end

      def report_source_gaps!
        source.report_rows('gaps').each do |gap|
          report.add('source_gap', "#{gap['table']} ##{gap['id']}", code: gap['code'])
        end
        never = []
        never << 'erase and zombie buttons (status changes are recorded; the move to "Deleted requirements" and removed relations are not)'
        never << 'moves and reordering in the tree (chapter order)'
        never << 'ODS and git imports, and CSID and chapter writes'
        never.each { |text| report.add('history_never_recorded', text) }
        source.content.fetch('tables').each do |table|
          name = table.fetch('name')
          next if Rules::REDMINE_TABLES.include?(name) || Rules::COSMOSYS_TABLES.include?(name) ||
                  Rules::TAG_TABLES.include?(name) || table.fetch('rows').zero?

          report.add('plugin_data_not_migrated', name, rows: table.fetch('rows'))
        end
        %w[news comments boards messages changesets repositories].each do |table|
          rows = source.table(table).length
          report.add('unsupported_content', table, rows: rows) if rows.positive?
        end
        attachments = source.table('attachments').group_by { |row| row['container_type'] }
        %w[News Message].each do |type|
          next unless attachments[type]

          report.add('unsupported_content', "attachments of #{type}", rows: attachments[type].length)
        end
        project_files.each do |id, (type, key, _index)|
          project_id = type == 'project' ? key : @versions.fetch(key)['project_id']
          report.add('project_file_migrated', "attachment ##{id}", project: project_identifier(project_id),
                                                                   version: type == 'version' ? @versions.fetch(key)['name'] : nil)
        end
        report_attachments_without_container!
      end

      # Attachments that belong to nothing (uploads never attached: Redmine
      # deletes them only when someone runs its cleanup) or to a record that
      # is no longer in the source. Nothing shows them; they are not migrated.
      def report_attachments_without_container!
        known = { 'Issue' => @issues, 'Document' => by_id('documents'), 'WikiPage' => by_id('wiki_pages'),
                  'Project' => @projects, 'Version' => @versions, 'News' => by_id('news'), 'Message' => by_id('messages') }
        source.table('attachments').sort_by { |row| row['id'] }.each do |row|
          type = row['container_type'].to_s
          reason = if type.empty? || row['container_id'].nil? then 'no container'
                   elsif known.key?(type) && !known[type].key?(row['container_id']) then "#{type} ##{row['container_id']} is not in the source"
                   end
          next unless reason

          report.add('attachment_without_container', "attachment ##{row['id']}", reason: reason, filename: row['filename'])
        end
      end
    end
  end
end

