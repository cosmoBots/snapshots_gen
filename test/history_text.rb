# frozen_string_literal: true

# Read-only extraction on Redmine 4.2 / Ruby 2.7 and Redmine 7.0.
# rails runner history_text.rb OUT.jsonl [LANGUAGE]
# v2 keeps rendered strings AND raw details with resolved reference identities.
require 'json'
require 'time'

out = ARGV[0] || raise('usage: history_text.rb OUT.jsonl [LANGUAGE]')
language = ARGV[1] || 'en'
renderer = Object.new
renderer.extend(Redmine::I18n, ERB::Util, ActionView::Helpers::TagHelper, ApplicationHelper, CustomFieldsHelper, IssuesHelper)
User.current = User.where(admin: true).order(:id).first
legacy = ActiveRecord::Base.connection.table_exists?('cosmosys_issues')
rq_types = if legacy
             fields = CustomField.where(name: 'rqType', type: 'IssueCustomField').pluck(:id)
             CustomValue.where(customized_type: 'Issue', custom_field_id: fields).pluck(:customized_id, :value).to_h
           else
             {}
           end
csid_of = if legacy
            ActiveRecord::Base.connection.select_rows('SELECT issue_id, identifier FROM cosmosys_issues').to_h
          else
            Issue.pluck(:id, :csid).to_h
          end
name = ->(user) { user ? user.name : '(none)' }
login = ->(user) { user && user.login }
stamp = ->(time) { time && time.utc.iso8601(6) }
refs = {
  'status_id' => ['statuses', IssueStatus], 'tracker_id' => ['trackers', Tracker],
  'priority_id' => ['priorities', IssuePriority], 'assigned_to_id' => ['users', User],
  'author_id' => ['users', User], 'category_id' => ['categories', IssueCategory],
  'fixed_version_id' => ['versions', Version], 'project_id' => ['projects', Project],
  'parent_id' => ['items', Issue]
}
# Redmine also permits assignment to groups (Principal STI, not User STI).
principal_model = defined?(Principal) ? Principal : User
refs['assigned_to_id'] = ['users', principal_model]
cache = {}
resolve = lambda do |kind, model, value|
  next value if value.nil? || value.to_s.empty?

  cache[[kind, value.to_s]] ||= begin
    record = model.find_by(id: value)
    if record.nil?
      { 'kind' => kind, 'missing' => value.to_s }
    else
      identity = case kind
                 when 'items' then { 'id' => record.id, 'tracker' => record.tracker.name }
                 when 'projects' then { 'identifier' => record.identifier }
                 when 'users'
                   record.respond_to?(:type) && record.type == 'Group' ? { 'group' => record.lastname } : { 'login' => record.login }
                 when 'versions', 'categories' then { 'project' => record.project.identifier, 'name' => record.name }
                 else { 'name' => record.name }
                 end
      identity.merge('kind' => kind)
    end
  end
end
::I18n.with_locale(language) do
  templates = %w[changed changed_no_detail set_to deleted added].each_with_object({}) do |key, result|
    result[key] = ::I18n.t("text_journal_#{key}").to_s
  end
  # Let each installed renderer resolve its own enum translations. A probe
  # renders the SAME raw value as an addition, then extracts only the value
  # from the locale's exact set/add template. No guessed enum labels.
  display = lambda do |detail, label, value|
    next nil if value.nil? || value == ''

    probe = detail.dup
    probe.old_value, probe.value = nil, value
    lines = renderer.details_to_strings([probe], true)
    next nil unless lines.length == 1

    found = nil
    %w[set_to added].each do |key|
      marker = 'SNAPSHOTS_GEN_DISPLAY_VALUE'
      text = templates[key].gsub('%{label}') { label }.gsub('%{value}') { marker }
      prefix, suffix = text.split(marker, 2)
      next unless suffix

      match = lines.first.match(/\A#{Regexp.escape(prefix)}(.*)#{Regexp.escape(suffix)}\z/m)
      found = match[1] if match
    end
    found
  end
  # Both extracts contain personal data, just like the migration packages.
  File.open(out, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
    file.chmod(0o600)
    Issue.includes(:author, :project, :tracker, journals: %i[user details]).order(:id).each do |issue|
      journals = issue.journals.sort_by { |j| [j.created_on, j.id] }.map do |journal|
        raw = journal.details.sort_by(&:id).map do |detail|
          property, key = detail.property, detail.prop_key.to_s
          field = property == 'cf' ? CustomField.find_by(id: key) : nil
          field_name = field ? field.name : key
          field_name = "missing-custom-field:#{key}" if property == 'cf' && field.nil?
          if property == 'attachment'
            attachment = Attachment.find_by(id: key)
            field_name = if attachment
                           { 'filename' => attachment.filename, 'size' => attachment.filesize,
                             'created' => stamp.call(attachment.created_on) }
                         else
                           { 'missing_attachment' => key }
                         end
          end
          reference = if property == 'attr'
                        refs[key]
                      elsif property == 'relation'
                        ['items', Issue]
                      elsif field && field.field_format == 'user'
                        ['users', principal_model]
                      elsif field && field.field_format == 'version'
                        ['versions', Version]
                      end
          label_key = key == 'parent_id' ? 'field_parent_issue' : "field_#{key.sub(/_id\z/, '')}"
          label = field ? field.name : ::I18n.t(label_key, default: key).to_s
          {
            'id' => detail.id, 'property' => property, 'prop_key' => key,
            'field' => field_name, 'label' => label,
            'field_format' => field && field.field_format,
            'multiple' => !!(field && field.multiple?),
            'old_value' => detail.old_value, 'value' => detail.value,
            'display_old' => display.call(detail, label, detail.old_value),
            'display_value' => display.call(detail, label, detail.value),
            'ref' => reference && reference[0],
            'old_ref' => reference && resolve.call(reference[0], reference[1], detail.old_value),
            'value_ref' => reference && resolve.call(reference[0], reference[1], detail.value),
            'rendered' => renderer.details_to_strings([detail], true)
          }
        end
        {
          'id' => journal.id, 'at' => stamp.call(journal.created_on), 'by' => name.call(journal.user),
          'by_login' => login.call(journal.user),
          'edited' => !!(journal.respond_to?(:updated_on) && journal.updated_on && journal.updated_on != journal.created_on),
          'private' => !!journal.private_notes, 'notes' => journal.notes.to_s,
          'details' => renderer.details_to_strings(journal.details, true), 'raw_details' => raw
        }
      end
      watchers = issue.watcher_users
      file.puts JSON.generate(
        'format' => 'history-text-v2', 'language' => language, 'id' => issue.id,
        'render_templates' => templates, 'tracker' => issue.tracker.name, 'parent_id' => issue.parent_id,
        'legacy_rq_type' => rq_types[issue.id],
        'project' => issue.project.identifier, 'csid' => csid_of[issue.id].to_s,
        'subject' => issue.subject, 'author' => name.call(issue.author), 'author_login' => login.call(issue.author),
        'tracker_default_status' => issue.tracker.default_status&.name,
        'created' => stamp.call(issue.created_on), 'updated' => stamp.call(issue.updated_on),
        'closed' => stamp.call(issue.closed_on), 'watchers' => watchers.map(&:name).sort,
        'watcher_logins' => watchers.map(&:login).sort,
        'time' => TimeEntry.where(issue_id: issue.id).sum(:hours).to_f, 'journals' => journals
      )
    end
  end
end
puts "wrote #{out}"
