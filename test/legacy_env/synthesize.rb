# frozen_string_literal: true

# Fills an empty old cosmoSys instance (Redmine 4.2 with the cosmosys_*
# plugins) with invented data that covers what the migration must carry:
# users, groups, memberships, requirements with their custom fields, and a
# history made through Redmine's own models (notes, property and custom field
# changes, attachments added and removed in notes, private notes, relations,
# wiki versions with a gap, time entries, watchers, an erased requirement and
# a deleted user).
#
#   bundle exec rails runner -e production synthesize.rb
#
# Nothing here is real data. Run it once, on a fresh database.

require 'tempfile'
require 'active_support/testing/time_helpers'
include ActiveSupport::Testing::TimeHelpers

abort 'the database already has projects' if Project.exists?

T0 = Time.utc(2023, 3, 1, 9, 0, 0)

def at(day, hour = 0)
  T0 + day * 86_400 + hour * 3600
end

def user!(login, first, last, admin: false, status: User::STATUS_ACTIVE)
  user = User.new(firstname: first, lastname: last, mail: "#{login}@example.invalid", language: 'en')
  user.login = login
  user.password = user.password_confirmation = "Synthetic-#{login}-2023"
  user.admin = admin
  user.status = status
  user.save!
  user
end

def cf(name)
  CustomField.find_by!(name: name)
end

def status(name)
  IssueStatus.find_by!(name: name)
end

def tracker(name)
  Tracker.find_by!(name: name)
end

def temp_file(name, content)
  temporary = Tempfile.new(['synthetic', File.extname(name)])
  temporary.binmode
  temporary.write(content)
  temporary.rewind
  temporary
end

def attachment!(author, name, content, description = nil)
  attachment = Attachment.new(author: author, description: description)
  attachment.file = temp_file(name, content)
  attachment.filename = name
  attachment.content_type = 'text/plain'
  attachment.save!
  attachment
end

def project!(name, identifier, code, parent: nil, trackers:)
  project = Project.new(name: name, identifier: identifier, description: "Invented project #{name}.", is_public: false)
  project.parent = parent if parent
  project.custom_field_values = {
    cf('csCode').id.to_s => code, cf('csDocCode').id.to_s => "#{code}-DOC",
    cf('csReportMetadata').id.to_s => "---\ncolumns: []\n"
  }
  project.enabled_module_names = %w[issue_tracking wiki documents time_tracking files]
  project.trackers = trackers.map { |name| tracker(name) }
  project.save!
  project
end

def requirement_values(type, level, extra = {})
  {
    cf('rqType').id.to_s => type, cf('rqLevel').id.to_s => level,
    cf('rqComplanceState').id.to_s => 'To Be Confirmed',
    cf('depGrahInReports').id.to_s => 'Include if has relations'
  }.merge(extra.transform_keys { |name| cf(name).id.to_s })
end

def item!(project, tracker_name, author, subject, values = {}, parent: nil, description: '', status_name: nil)
  issue = Issue.new(project: project, tracker: tracker(tracker_name), author: author, subject: subject,
                    description: description, priority: IssuePriority.default || IssuePriority.first)
  issue.status = status(status_name) if status_name
  issue.parent_issue_id = parent.id if parent
  issue.custom_field_values = values unless values.empty?
  issue.save!
  issue.reload
end

def edit!(issue, user, notes = nil, private_notes: false)
  User.current = user
  issue = Issue.find(issue.id)
  issue.init_journal(user, notes)
  issue.private_notes = private_notes
  yield issue if block_given?
  issue.save!
  issue
end

Setting.text_formatting = 'markdown'
Setting.notified_events = []

ActiveRecord::Base.transaction do

travel_to(at(0)) do
  @admin = User.find_by!(login: 'admin')
  @alice = user!('alice', 'Alice', 'Writer')
  @bob = user!('bob', 'Bob', 'Reviewer')
  @carol = user!('carol', 'Carol', 'Reader')
  @dave = user!('dave', 'Dave', 'Locked', status: User::STATUS_LOCKED)
  @erin = user!('erin', 'Erin', 'Registered', status: User::STATUS_REGISTERED)
  @frank = user!('frank', 'Frank', 'Leaver')
  @carol.update_columns(twofa_scheme: 'totp', twofa_totp_key: 'invented-and-encrypted-elsewhere')
  @writers = Group.new(lastname: 'Writers')
  @writers.users = [@alice, @bob]
  @writers.save!

  @req = project!('Synthetic Requirements', 'synth-req', 'SYR', trackers: %w[rq csInfo csRefDoc Bug])
  @sub = project!('Synthetic Subsystem', 'synth-req-sub', 'SYRS', parent: @req, trackers: %w[rq csInfo])
  @poris = project!('Synthetic PORIS', 'synth-poris', 'SYP', trackers: %w[prSys prParam prMode prValue])

  roles = Role.where(name: %w[rqWriter rqReviewer rqReader]).index_by(&:name)
  [[@alice, 'rqWriter'], [@bob, 'rqReviewer'], [@carol, 'rqReader'], [@dave, 'rqReader'], [@frank, 'rqWriter']].each do |user, role|
    Member.create!(principal: user, project: @req, role_ids: [roles.fetch(role).id])
  end
  Member.create!(principal: @writers, project: @sub, role_ids: [roles.fetch('rqWriter').id])
  Member.create!(principal: @alice, project: @poris, role_ids: [roles.fetch('rqWriter').id])

  @v1 = Version.create!(project: @req, name: 'v1.0', status: 'open', effective_date: Date.new(2023, 3, 20), description: 'First baseline')
  @v2 = Version.create!(project: @req, name: 'v2.0', status: 'open', sharing: 'tree')
  @unused = Version.create!(project: @req, name: 'v3.0 (unused)', status: 'locked')
  # Custom fields outside cosmoSys, kept as custom fields by the migration.
  trackers = Tracker.where(name: %w[rq Bug]).to_a
  @supplier = IssueCustomField.create!(name: 'Supplier', field_format: 'string', is_for_all: true, trackers: trackers,
                                       searchable: true, description: 'Invented supplier field')
  @risk = IssueCustomField.create!(name: 'Risk', field_format: 'list', possible_values: %w[Low Medium High],
                                   multiple: true, is_for_all: true, trackers: trackers, is_filter: true)
  @reviewer = IssueCustomField.create!(name: 'Reviewer', field_format: 'user', is_for_all: true, trackers: trackers)
  @mech = IssueCategory.create!(project: @req, name: 'Mechanics', assigned_to: @alice)
  @soft = IssueCategory.create!(project: @req, name: 'Software')
end

travel_to(at(1)) do
  User.current = @alice
  @intro = item!(@req, 'rq', @alice, 'Introduction', requirement_values('Info', 'None'),
                 description: "Purpose of this specification.\n\nSee the design notes in the wiki.")
  @boot = item!(@req, 'rq', @alice, 'Boot time', requirement_values('Sw', 'System', 'rqRationale' => 'Operators need a quick restart.',
                                                                      'rqVerif' => 'Test', 'rqVerifDescr' => 'Measure ten cold boots.'),
                parent: @intro, description: 'The system shall boot in less than 10 s.')
  @power = item!(@req, 'rq', @alice, 'Power budget', requirement_values('Hw', 'System', 'rqVar' => 'PowerMax', 'rqValue' => '45 W'),
                 parent: @intro, description: 'The system shall consume less than 45 W.')
  @battery = item!(@req, 'rq', @alice, 'Battery capacity', requirement_values('Hw', 'Derived', 'csOldCode' => 'OLD-17', 'csWload' => '30'),
                   parent: @power, description: 'The battery shall last 8 h at the power budget.')
  @docs = item!(@req, 'rq', @alice, 'Applicable documents', requirement_values('Info', 'None'))
  @ad1 = item!(@req, 'rq', @alice, 'AD 1', requirement_values('Info', 'None'), parent: @docs,
               description: 'Interface control document ABC-ICD-0042 v2, 03/2022')
  @interface = item!(@req, 'rq', @alice, 'External interface', requirement_values('Sw', 'External', 'rqAplDocs' => "AD 1 | applies | section 3"),
                     parent: @docs, description: "Comply with the interface in AD 1.\n\n    | Signal | Level |\n|---|---|\n| A | 5 V |")
  @obsolete = item!(@req, 'rq', @alice, 'Obsolete requirement', requirement_values('Mech', 'System'), parent: @intro,
                    description: 'This one will be erased.')
  @info = item!(@req, 'csInfo', @alice, 'Glossary', {}, description: '*Boot*: from power on to ready.')
  @refdoc = item!(@req, 'csRefDoc', @alice, 'Reference: style guide', {})
  @bug = item!(@req, 'Bug', @bob, 'Typo in the boot requirement', {}, description: 'A plain Redmine issue.')
  @sub_req = item!(@sub, 'rq', @bob, 'Subsystem latency', requirement_values('Sw', 'Derived'), description: 'Latency below 5 ms.')
  @sys = item!(@poris, 'prSys', @alice, 'Instrument', {})
  @param = item!(@poris, 'prParam', @alice, 'Exposure', { cf('prMin').id.to_s => '0.1', cf('prMax').id.to_s => '30',
                                                          cf('prDefault').id.to_s => '1' }, parent: @sys)
end

travel_to(at(2, 3)) do
  edit!(@boot, @bob, 'Reviewed. Moving to stable; the level is really derived.') do |issue|
    issue.status = status('rqStable')
    issue.custom_field_values = { cf('rqLevel').id.to_s => 'Derived' }
  end
end

travel_to(at(2, 5)) do
  edit!(@boot, @alice, 'Supplier, risk and reviewer set.') do |issue|
    issue.custom_field_values = { @supplier.id.to_s => 'ACME Boot Ltd', @risk.id.to_s => %w[Low Medium],
                                  @reviewer.id.to_s => @bob.id.to_s }
  end
  edit!(@bug, @bob) { |issue| issue.custom_field_values = { @supplier.id.to_s => 'Typo Fixers' } }
end

travel_to(at(3, 1)) do
  edit!(@boot, @alice, 'Attached the timing diagram.') do |issue|
    issue.attachments << attachment!(@alice, 'timing.txt', "boot: 0 s\nready: 8.7 s\n", 'Timing')
  end
end

travel_to(at(3, 5)) do
  edit!(@boot, @carol, 'Private remark: check with the supplier first.', private_notes: true) do |issue|
    issue.assigned_to = @bob
  end
end

travel_to(at(4)) do
  User.current = @alice
  # As IssueRelationsController does, so both ends journal the relation.
  [[@boot, @battery, 'blocks'], [@power, @boot, 'relates'], [@interface, @ad1, 'relates'],
   [@obsolete, @boot, 'relates']].each do |from, to, type|
    relation = IssueRelation.new(issue_from: Issue.find(from.id), issue_to: Issue.find(to.id), relation_type: type)
    relation.init_journals(@alice)
    relation.save!
  end
end

travel_to(at(5, 2)) do
  edit!(@boot, @alice, 'Removed the draft attachment; a new one follows.') do |issue|
    issue.attachments << attachment!(@alice, 'draft.txt', "draft\n")
  end
  edit!(@boot, @alice) do |issue|
    issue.attachments.delete(issue.attachments.find_by(filename: 'draft.txt'))
  end
end

travel_to(at(6)) do
  edit!(@battery, @bob, "Clarified the wording. Related to ##{@boot.id}, see note-1 there.") do |issue|
    issue.subject = 'Battery autonomy'
    issue.description = 'The battery shall last at least 8 h at the power budget.'
    issue.custom_field_values = { cf('rqRationale').id.to_s => 'Field work shifts last 8 h.' }
  end
end

travel_to(at(6, 4)) do
  edit!(@battery, @alice, 'New external code.') do |issue|
    issue.custom_field_values = { cf('csOldCode').id.to_s => 'OLD-17B' }
  end
end

travel_to(at(7)) do
  edit!(@boot, @alice) do |issue|
    issue.fixed_version = @v1
    issue.category = @soft
    issue.start_date = Date.new(2023, 3, 8)
    issue.due_date = Date.new(2023, 3, 30)
    issue.estimated_hours = 6
    issue.done_ratio = 40
  end
  edit!(@boot, @bob, 'Approved.') { |issue| issue.status = status('rqApproved') }
end

travel_to(at(8)) do
  edit!(@interface, @frank, 'Note from someone who will leave the company.')
  edit!(@obsolete, @alice, 'Superseded by the boot requirement.') { |issue| issue.status = status('rqErased') }
end

travel_to(at(9)) do
  @v1.reload.update!(status: 'closed')
  edit!(@info, @alice, nil) { |issue| issue.parent_issue_id = @intro.id }
  edit!(@sub_req, @alice, 'Edited by a group member.') { |issue| issue.status = status('rqStable') }
  edit!(@param, @alice, 'Raised the maximum.') do |issue|
    issue.custom_field_values = { cf('prMax').id.to_s => '60' }
  end
end

travel_to(at(10)) do
  User.current = @alice
  TimeEntry.create!(project: @req, issue: @boot, user: @alice, hours: 2.5, spent_on: Date.new(2023, 3, 11),
                    activity: TimeEntryActivity.find_by(name: 'Design') || TimeEntryActivity.first, comments: 'Timing analysis')
  User.current = @bob
  TimeEntry.create!(project: @req, user: @bob, hours: 1, spent_on: Date.new(2023, 3, 11),
                    activity: TimeEntryActivity.first, comments: 'Project review')
  @boot.add_watcher(@bob)
  @battery.add_watcher(@carol)
end

travel_to(at(11)) do
  wiki = @req.wiki || Wiki.create!(project: @req, start_page: 'Wiki')
  @home = WikiPage.new(wiki: wiki, title: 'Wiki')
  @home.content = WikiContent.new(text: "# Synthetic wiki\n\nVersion 1.", author: @alice, comments: 'Created')
  @home.save!
end

[[@bob, 'Version 2.', 'Second'], [@alice, 'Version 3.', 'Third'], [@bob, 'Version 4.', 'Fourth']].each_with_index do |(user, text, comment), index|
  travel_to(at(11, index + 1)) do
    content = WikiPage.find(@home.id).content
    content.text = "# Synthetic wiki\n\n#{text}"
    content.author = user
    content.comments = comment
    content.save!
  end
end

travel_to(at(11, 6)) do
  wiki = @req.reload.wiki
  WikiPage.find(@home.id).content.versions.find_by(version: 2).destroy
  @notes = WikiPage.new(wiki: wiki, title: 'Design_notes', parent: @home)
  @notes.content = WikiContent.new(text: "Design notes.\n\n    | Indented | header |\n|---|---|\n| a | b |", author: @alice)
  @notes.save!
  @notes.attachments << attachment!(@alice, 'sketch.txt', "+--+\n|  |\n+--+\n")
  @old = WikiPage.new(wiki: wiki, title: 'Old_name')
  @old.content = WikiContent.new(text: 'Page to be renamed.', author: @bob)
  @old.save!
  Watcher.create!(watchable: @notes, user: @carol)
end

travel_to(at(12)) do
  page = WikiPage.find(@old.id)
  page.title = 'New_name'
  page.save!
  document = Document.create!(project: @req, category: DocumentCategory.first, title: 'Interface control document',
                              description: 'Invented document.')
  document.attachments << attachment!(@alice, 'icd.txt', "ICD v2\n")
  begin
    edit!(@boot, @alice) { |issue| issue.tag_list = %w[safety timing] }
  rescue StandardError => error
    warn "tags skipped: #{error.class}: #{error.message}"
  end
end

end

# Outside the transaction: deleting a user whose creation is not yet
# committed breaks Redmine's security notification after commit.
travel_to(at(13)) do
  User.current = @admin
  @frank.reload.destroy
end

puts "projects=#{Project.count} issues=#{Issue.count} journals=#{Journal.count} details=#{JournalDetail.count} " \
     "wiki_versions=#{WikiContent::Version.count} attachments=#{Attachment.count} users=#{User.where(type: 'User').count}"
