# frozen_string_literal: true

# Synthetic legacy snapshot for the end-to-end test of the tags importer
# (test/importer_tags_e2e.sh): the small instance of converter_fixture.rb with
# tags that only survive an exact import, and tag changes in the history.
#
#   ruby test/importer_tags_fixture.rb OUT_DIRECTORY
#
# Writes OUT_DIRECTORY/legacy (a legacy snapshot the converter reads) and
# OUT_DIRECTORY/expected.tsv, what the new instance must hold afterwards, with
# names in hexadecimal so that nothing between here and the comparison can
# normalize them. Every name and text is invented.

require 'fileutils'
require_relative 'converter_fixture'

module ImporterTagsFixture
  TIME = ConverterFixture::TIME
  NFC = "café"
  NFD = "café"
  LONG = "é#{'x' * 253}ñ" # 255 characters, 257 bytes
  MARKER = '#snapshots-gen-item-7' # a tag named like a reference placeholder of the history
  SETTINGS = "--- !ruby/hash:ActiveSupport::HashWithIndifferentAccess\nactive_issue_tags: '1'\nactive_wiki_tags: '1'\n" \
             "open_issues_only: '0'\nshow_with_count: '1'\ntags_sidebar: cloud\ntags_sort_by: count\ntags_sort_order: desc\n" \
             "tags_suggestion_order: last_created\nuse_colors: '0'\n"
  # id => [name, stored counter]. Tag 1 has a wrong counter; tag 13 is unused.
  TAGS = {
    1 => ['A,B', 9], 2 => ['a', 1], 3 => ['A', 2], 4 => [NFC, 1], 5 => [NFD, 1], 6 => ['with  two spaces', 1],
    7 => ['quote "x" and \'y\'', 1], 8 => ["emoji \u{1F600}", 2], 9 => [LONG, 1], 10 => ['grupo::uno', 1],
    11 => ['grupo::dos', 1], 12 => ['grupo:uno', 1], 13 => ['lonely tag', 0], 14 => [MARKER, 1]
  }.freeze
  # [tag id, type, source object id]. Issue 5 (absorbed into a document) and
  # wiki page 3 stay untagged; wiki pages 1 and 2 have the same title in two
  # projects; issue 2 has two tags of one "grupo::" scope.
  TAGGINGS = [
    [1, 'Issue', 1], [1, 'Issue', 4], [1, 'WikiPage', 1], [1, 'WikiPage', 2], [2, 'Issue', 1], [3, 'Issue', 1], [3, 'Issue', 3],
    [4, 'Issue', 6], [5, 'Issue', 6], [6, 'Issue', 7], [7, 'Issue', 3], [8, 'Issue', 3], [8, 'WikiPage', 2], [9, 'Issue', 2],
    [10, 'Issue', 2], [11, 'Issue', 2], [12, 'Issue', 4], [14, 'Issue', 7]
  ].freeze
  # [journal id, issue id, private, notes, [[prop_key, old, new], ...]]
  JOURNALS = [
    [1, 1, false, '', [['tag_list', nil, '"A,B", a, A']]],
    [2, 2, false, 'Renamed and tagged', [['subject', 'Old subject', 'Second'], ['tag_list', "x, 'y'", "grupo::dos, grupo::uno, #{LONG}"]]],
    [3, 7, false, '', [['tag_list', '', "#{MARKER}, with  two spaces"]]],
    [4, 4, false, '', [['tag_list', "a, A, #{NFC}, #{NFD}", '']]],
    [5, 3, true, 'A private note', [['tag_list', 'A', "A, emoji \u{1F600}, quote \"x\" and 'y'"]]]
  ].freeze

  module_function

  def at(seconds, micros = 0)
    format('2021-03-%<day>02dT05:06:%<second>02d.%<micros>06dZ', day: 4 + seconds / 60, second: seconds % 60, micros: micros)
  end

  def tables
    tables = ConverterFixture.base_tables
    # Tags only show in projects with the issue tracking module, to roles with
    # view_issue_tags. The import gives each destination role the tag
    # permissions of its source roles: rqMngr (Manager, which already has
    # more and keeps them) and rqWriter (Developer, which gets them) had
    # view_issue_tags, rqReader (Reporter) did not; the built-in Non member
    # role had it; Ghost had it and has no destination role.
    tables['enabled_modules'] = tables['projects'].flat_map { |project| %w[issue_tracking wiki].map { |name| [project['id'], name] } }
                                                  .each_with_index.map { |(project, name), index| { 'id' => index + 1, 'project_id' => project, 'name' => name } }
    tables['users'] << tables['users'].first.merge('id' => 2, 'login' => 'reader', 'firstname' => 'C', 'lastname' => 'D')
    tables['users'] << tables['users'].first.merge('id' => 3, 'login' => 'writer', 'firstname' => 'E', 'lastname' => 'F')
    tables['roles'] = [
      ConverterFixture.role(1, 'Non member', 1, %w[view_issues view_issue_tags]), ConverterFixture.role(2, 'Anonymous', 2, %w[view_issues]),
      ConverterFixture.role(3, 'rqMngr', 0, %w[view_issues add_issues view_issue_tags]),
      ConverterFixture.role(4, 'rqReader', 0, %w[view_issues]),
      ConverterFixture.role(5, 'rqWriter', 0, %w[view_issues edit_issues view_issue_tags edit_issue_tags]),
      ConverterFixture.role(6, 'Ghost', 0, %w[view_issues view_issue_tags])
    ]
    tables['members'] = (1..3).map { |id| { 'id' => id, 'user_id' => id, 'project_id' => 1, 'created_on' => TIME } }
    tables['member_roles'] = [{ 'id' => 1, 'member_id' => 1, 'role_id' => 3, 'inherited_from' => nil },
                              { 'id' => 2, 'member_id' => 2, 'role_id' => 4, 'inherited_from' => nil },
                              { 'id' => 3, 'member_id' => 3, 'role_id' => 5, 'inherited_from' => nil }]
    tables['wiki_contents'] = tables['wiki_pages'].map do |page|
      { 'id' => page['id'], 'page_id' => page['id'], 'author_id' => 1, 'text' => "Page #{page['id']}", 'comments' => '',
        'updated_on' => TIME, 'version' => 1 }
    end
    tables['additional_tags'] = { columns: ConverterFixture::TAG_COLUMNS, rows: TAGS.map do |id, (name, count)|
      { 'id' => id, 'name' => name, 'taggings_count' => count, 'created_at' => at(id), 'updated_at' => at(id + 30, id * 1001) }
    end }
    tables['additional_taggings'] = { columns: ConverterFixture::TAGGING_COLUMNS, rows: TAGGINGS.each_with_index.map do |(tag, type, object), index|
      { 'id' => index + 1, 'tag_id' => tag, 'taggable_type' => type, 'taggable_id' => object, 'tagger_type' => nil, 'tagger_id' => nil,
        'context' => 'tags', 'created_at' => tagging_time(index) }
    end }
    tables['settings'] = [{ 'id' => 9, 'name' => 'plugin_additional_tags', 'value' => SETTINGS, 'updated_on' => TIME }]
    tables['journals'] = JOURNALS.map do |id, issue, private_notes, notes, _details|
      { 'id' => id, 'journalized_id' => issue, 'journalized_type' => 'Issue', 'user_id' => 1, 'notes' => notes,
        'private_notes' => private_notes, 'created_on' => at(100 + id) }
    end
    tables['journal_details'] = details.map do |id, journal, prop_key, old, new|
      { 'id' => id, 'journal_id' => journal, 'property' => 'attr', 'prop_key' => prop_key, 'old_value' => old, 'value' => new }
    end
    tables
  end

  # The last tagging has no date: the source column allows NULL.
  def tagging_time(index)
    index == TAGGINGS.length - 1 ? nil : at(200 + index, index * 37)
  end

  def details
    id = 0
    JOURNALS.flat_map { |journal, _issue, _private, _notes, list| list.map { |prop_key, old, new| [id += 1, journal, prop_key, old, new] } }
  end

  def hex(text)
    text.nil? ? 'NULL' : text.unpack1('H*')
  end

  # What the destination must hold, in the order and shape of the query of
  # importer_tags_e2e.sh. Items are named by their subject and wiki pages by
  # their title, which the conversion keeps, not by any id.
  def expected
    base = ConverterFixture.base_tables
    projects = base['projects'].to_h { |row| [row['id'], row['identifier']] }
    issues = base['issues'].to_h { |row| [row['id'], [projects[row['project_id']], row['subject']]] }
    wikis = base['wikis'].to_h { |row| [row['id'], projects[row['project_id']]] }
    pages = base['wiki_pages'].to_h { |row| [row['id'], [wikis[row['wiki_id']], row['title']]] }
    counts = TAGGINGS.map(&:first).tally
    lines = TAGS.map do |id, (name, _stored)|
      ['tag', hex(name), counts.fetch(id, 0), at(id), at(id + 30, id * 1001)]
    end
    lines += TAGGINGS.each_with_index.map do |(tag, type, object), index|
      project, label = type == 'Issue' ? issues.fetch(object) : pages.fetch(object)
      ['tagging', type, project, hex(label), hex(TAGS.fetch(tag).first), tagging_time(index) || 'NULL']
    end
    lines += details.select { |_id, _journal, prop_key, *_rest| prop_key == 'tag_list' }.map do |_id, journal, _key, old, new|
      project, subject = issues.fetch(JOURNALS.find { |row| row.first == journal }[1])
      ['tag_list', project, hex(subject), hex(old), hex(new)]
    end
    lines += [['count', 'tags', TAGS.length], ['count', 'taggings', TAGGINGS.length]]
    lines.map { |line| line.join("\t") }.sort.join("\n") + "\n"
  end

  def write(directory)
    FileUtils.mkdir_p(directory)
    ConverterFixture.legacy(File.join(directory, 'legacy'), tables)
    File.write(File.join(directory, 'expected.tsv'), expected)
  end
end

if $PROGRAM_NAME == __FILE__
  abort 'usage: importer_tags_fixture.rb OUT_DIRECTORY' unless ARGV.length == 1
  ImporterTagsFixture.write(ARGV.first)
  puts "Written #{ARGV.first}/legacy and #{ARGV.first}/expected.tsv (#{ImporterTagsFixture::TAGS.length} tags, " \
       "#{ImporterTagsFixture::TAGGINGS.length} taggings)"
end
