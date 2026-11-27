# frozen_string_literal: true

# ONLY an invented, disposable database previously filled by synthesize.rb.
# rails runner synthesize_tags.rb valid
# rails runner synthesize_tags.rb reject context
# Each reject case needs a different fresh disposable database.
require 'json'

module SyntheticTags
  REJECTIONS = %w[context null-context empty-context tagger empty-tagger duplicate
                  orphan-issue orphan-wiki unknown-type empty-type null-type
                  null-name empty-name outer-spaces spaces nul absorbed].freeze
  module_function

  def insert(db, table, attributes)
    names = attributes.keys.map { |key| db.quote_column_name(key) }.join(', ')
    values = attributes.values.map { |value| db.quote(value) }.join(', ')
    db.execute("INSERT INTO #{db.quote_table_name(table)} (#{names}) VALUES (#{values})")
    db.select_value('SELECT LAST_INSERT_ID()').to_i
  end

  def tag(db, name, timestamp)
    insert(db, 'additional_tags', 'name' => name, 'taggings_count' => 0,
           'created_at' => timestamp, 'updated_at' => timestamp)
  end

  def assignment(db, tag_id, object, timestamp, extra = {})
    insert(db, 'additional_taggings', {
      'tag_id' => tag_id, 'taggable_type' => object.class.name, 'taggable_id' => object.id,
      'context' => 'tags', 'tagger_id' => nil, 'tagger_type' => nil, 'created_at' => timestamp
    }.merge(extra))
  end

  def main(argv)
    mode, rejection = argv
    unless (mode == 'valid' && argv.length == 1) || (mode == 'reject' && argv.length == 2 && REJECTIONS.include?(rejection))
      raise 'usage: synthesize_tags.rb valid | reject CASE (see README)'
    end
    raise 'this script only supports the old synthetic MySQL environment' unless ActiveRecord::Base.connection.adapter_name.downcase.include?('mysql')
    identifiers = Project.order(:identifier).pluck(:identifier)
    raise 'not the expected synthetic database' unless identifiers == %w[synth-poris synth-req synth-req-sub]
    raise 'tags fixture already present' if Setting.plugin_additional_tags['g3_synthetic_marker']

    db = ActiveRecord::Base.connection
    db.execute('SET NAMES utf8mb4')
    timestamp = Time.utc(2023, 4, 1, 12, 0, 0)
    project = Project.find_by!(identifier: 'synth-req')
    first = project.issues.find_by!(subject: 'Boot time')
    second = project.issues.find_by!(subject: 'Power budget')
    subproject = Project.find_by!(identifier: 'synth-req-sub')
    third = subproject.issues.find_by!(subject: 'Subsystem latency')
    wiki = project.wiki.pages.find_by!(title: 'Wiki')
    # Do not let after_commit cleanup erase the unused-tag fixture. This is
    # process-local and applies only to this job while building invented data.
    AdditionalTagsRemoveUnusedTagJob.queue_adapter = :test
    previous_journals = first.journals.pluck(:id)
    ActiveRecord::Base.transaction do
      # Exercise journaled edits through the real fork before the SQL fixtures.
      # Raw insertions below intentionally bypass the parser and normalization.
      User.current = User.find_by!(login: 'alice')
      [[['journal-only'], nil, false], [['A,B', 'quote"tag', '#snapshots-gen-item-7'], nil, true],
       [[], 'Invented tag removal', false]].each do |names, notes, private_notes|
        edited = Issue.find(first.id)
        edited.init_journal(User.current, notes)
        edited.private_notes = private_notes
        before = edited.tag_list.to_s
        edited.tag_list = names
        # The fork records this from its controller hook, not Issue#save!.
        # Reproduce that public hook explicitly in this rails-runner fixture.
        edited.tags_to_journal(before, edited.tag_list.to_s)
        edited.save!
      end
      new_journals = first.journals.reload.pluck(:id) - previous_journals
      details = JournalDetail.where(journal_id: new_journals, property: 'attr', prop_key: 'tag_list')
      raise 'expected three literal tag_list history details' unless details.count == 3
      values = details.pluck(:old_value, :value).flatten.compact
      raise 'expected comma-bearing literal tag_list history' unless values.any? { |value| value.include?(',') }
      # Delete only synthetic tag state, leaving its journal evidence intact.
      db.execute('DELETE FROM additional_taggings')
      db.execute('DELETE FROM additional_tags')
      # Store what Redmine's plugin settings page stores: a
      # HashWithIndifferentAccess with string keys. Without a stored row the
      # plugin returns its defaults with symbol keys, and merging string keys
      # into those would keep both forms of the same key.
      settings = ActiveSupport::HashWithIndifferentAccess.new(Setting.plugin_additional_tags)
      settings.merge!('active_issue_tags' => '1', 'active_wiki_tags' => '1',
                      'use_colors' => '0', 'g3_synthetic_marker' => mode)
      Setting.plugin_additional_tags = settings

      # A same-title wiki in another project checks that project is part of identity.
      other_wiki = subproject.wiki || Wiki.create!(project: subproject, start_page: 'Wiki')
      other_page = WikiPage.new(wiki: other_wiki, title: 'Wiki')
      other_page.content = WikiContent.new(text: 'Invented tag fixture.', author: User.current)
      other_page.save!

      names = ['A', 'a', 'cafe', 'café', 'ñ', "é", "e\u0301", 'two  spaces',
               'emoji 🛰️', 'quote"tag', 'A,B', 'x' * 191, '🚀' * 191,
               'grupo:valor', 'grupo::uno', 'grupo::dos', '#snapshots-gen-item-7']
      ids = names.map { |name| tag(db, name, timestamp) }
      # Reverse physical insertion is deliberately not an API-order assertion.
      ids.reverse_each { |id| assignment(db, id, first, timestamp) }
      shared = tag(db, 'shared', timestamp)
      [first, second, third, wiki].each { |object| assignment(db, shared, object, timestamp) }
      assignment(db, ids.first, other_page, timestamp)
      tag(db, 'unused', timestamp)
      # Closed objects must also remain visible when open_issues_only is false.
      closed = project.issues.find_by!(subject: 'Obsolete requirement')
      assignment(db, ids.last, closed, timestamp)

      unless mode == 'valid'
        extra = case rejection
                when 'context' then { 'context' => 'other' }
                when 'null-context' then { 'context' => nil }
                when 'empty-context' then { 'context' => '' }
                when 'tagger' then { 'tagger_id' => User.current.id, 'tagger_type' => 'User' }
                when 'empty-tagger' then { 'tagger_type' => '' }
                when 'orphan-issue' then { 'taggable_id' => Issue.maximum(:id).to_i + 1000 }
                when 'orphan-wiki' then { 'taggable_type' => 'WikiPage', 'taggable_id' => WikiPage.maximum(:id).to_i + 1000 }
                when 'unknown-type' then { 'taggable_type' => 'InventedObject' }
                when 'empty-type' then { 'taggable_type' => '' }
                when 'null-type' then { 'taggable_type' => nil }
                else {}
                end
        bad_names = { 'null-name' => nil, 'empty-name' => '', 'outer-spaces' => ' outer ', 'spaces' => '   ', 'nul' => "bad\u0000name" }
        if bad_names.key?(rejection)
          invalid_id = tag(db, bad_names[rejection], timestamp)
          assignment(db, invalid_id, second, timestamp)
        elsif rejection == 'absorbed'
          object = project.issues.find_by!(subject: 'AD 1')
          assignment(db, shared, object, timestamp)
        else
          # duplicate reproduces the NULL loophole in the legacy unique index.
          assignment(db, ids.first, first, timestamp, extra)
        end
      end
      db.execute('UPDATE additional_tags SET taggings_count = ' \
                 '(SELECT COUNT(*) FROM additional_taggings WHERE tag_id = additional_tags.id)')
      db.execute("UPDATE additional_tags SET taggings_count = 99 WHERE id = #{shared}")
    end
    puts "synthetic_tags mode=#{mode} case=#{rejection || 'none'} " \
         "tags=#{db.select_value('SELECT COUNT(*) FROM additional_tags')} " \
         "assignments=#{db.select_value('SELECT COUNT(*) FROM additional_taggings')} tag_list_details=3"
  end
end

SyntheticTags.main(ARGV) if $PROGRAM_NAME == __FILE__ || defined?(Rails)
