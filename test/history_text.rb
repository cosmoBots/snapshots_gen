# frozen_string_literal: true

# Prints the history of every item as Redmine renders it, one JSON line per
# item, so an old instance and a migrated one can be compared:
#
#   rails runner history_text.rb OUT.jsonl [LANGUAGE]
#
# Runs on Redmine 4.2 (Ruby 2.7) and 7.0 alike. Items are named by their CSID
# (cosmosys_issues.identifier in the old model, issues.csid in the new one).

require 'json'

out = ARGV[0] || raise('usage: history_text.rb OUT.jsonl [LANGUAGE]')
language = ARGV[1] || 'en'
renderer = Object.new
renderer.extend(Redmine::I18n, ERB::Util, ActionView::Helpers::TagHelper, ApplicationHelper, CustomFieldsHelper, IssuesHelper)
admin = User.where(admin: true).order(:id).first
User.current = admin
csid_of = if ActiveRecord::Base.connection.table_exists?('cosmosys_issues')
            ActiveRecord::Base.connection.select_rows('SELECT issue_id, identifier FROM cosmosys_issues').to_h
          else
            Issue.pluck(:id, :csid).to_h
          end
name = ->(user) { user ? user.name : '(none)' }
stamp = ->(time) { time && time.utc.strftime('%Y-%m-%d %H:%M') }
::I18n.with_locale(language) do
  File.open(out, 'w') do |file|
    Issue.includes(:author, journals: %i[user details]).order(:id).each do |issue|
      journals = issue.journals.sort_by(&:id).map do |journal|
        {
          'id' => journal.id, 'at' => stamp.call(journal.created_on), 'by' => name.call(journal.user),
          'edited' => journal.respond_to?(:updated_on) && journal.updated_on && journal.updated_on != journal.created_on,
          'private' => journal.private_notes ? true : false, 'notes' => journal.notes.to_s,
          'details' => renderer.details_to_strings(journal.details, true)
        }
      end
      file.puts JSON.generate(
        'csid' => csid_of[issue.id].to_s, 'subject' => issue.subject, 'author' => name.call(issue.author),
        'created' => stamp.call(issue.created_on), 'updated' => stamp.call(issue.updated_on),
        'closed' => stamp.call(issue.closed_on), 'watchers' => issue.watcher_users.map(&:name).sort,
        'time' => TimeEntry.where(issue_id: issue.id).sum(:hours).to_f, 'journals' => journals
      )
    end
  end
end
puts "wrote #{out}"
