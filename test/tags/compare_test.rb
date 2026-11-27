# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'stringio'
require 'open3'
require_relative 'compare'

class TagsComparisonTest < Minitest::Test
  FIXTURES = File.expand_path('fixtures', __dir__)

  def setup
    @directory = Dir.mktmpdir('tags-comparison-')
    File.chmod(0o700, @directory)
    @source = File.readlines(File.join(FIXTURES, 'source.jsonl')).map { |line| JSON.parse(line) }[0...-1]
    @target = File.readlines(File.join(FIXTURES, 'target.jsonl')).map { |line| JSON.parse(line) }[0...-1]
    @report = JSON.parse(File.read(File.join(FIXTURES, 'report.json')))
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def write(side, rows)
    path = File.join(@directory, "#{side}.jsonl")
    body = rows.map { |row| TagsEvidence.json(row) + "\n" }.join
    counts = rows.each_with_object(Hash.new(0)) { |row, hash| hash[row['kind']] += 1 }
    footer = { 'kind' => 'end', 'counts' => counts, 'sha256' => Digest::SHA256.hexdigest(body) }
    File.write(path, body + TagsEvidence.json(footer) + "\n")
    path
  end

  def compare
    source = TagsEvidence::Document.new(write('source', @source))
    target = TagsEvidence::Document.new(write('target', @target))
    TagsEvidence::Comparison.new(source, target, @report).run
  end

  def of(rows, kind)
    rows.select { |row| row['kind'] == kind }
  end

  def rejects(code)
    result = compare
    assert result.failures.any? { |failure| failure.include?(code) }, result.failures.inspect
    result
  end

  def test_identical_logical_data_passes_despite_ids_and_source_counter
    result = compare
    assert_empty result.failures
    assert result.information.any? { |line| line.include?('source_counter_mismatch') }
    assert result.information.any? { |line| line.include?('order: not-certified') }
  end

  def test_catalog_includes_unused_tags
    @target.delete(of(@target, 'tag').last)
    rejects('tag_catalog_or_dates')
  end

  def test_missing_assignment
    @target.delete(of(@target, 'assignment').first)
    rejects('assignment expected=')
  end

  def test_extra_assignment
    row = of(@target, 'assignment').first.dup
    row.merge!('id' => 999, 'tag_id' => of(@target, 'tag').last['id'])
    @target << row
    rejects('assignment expected=')
  end

  def test_changes_to_name_bytes_fail
    [['Private,A', 'private,A'], ['two  spaces', 'two spaces'], ['Private,A', 'Private'],
     ['café', 'cafe'], ["é", "e\u0301"], ['emoji 🚀', 'emoji ?']].each do |before, after|
      tag = of(@target, 'tag').find { |row| row['name'] == before }
      tag['name'] = after
      rejects('tag_catalog_or_dates')
      tag['name'] = before
    end
  end

  def test_trim_and_invalid_names_fail_even_if_both_sides_match
    [nil, '', ' outer ', '   ', "bad\u0000name", { '$base64' => '/w==' }].each do |name|
      of(@source, 'tag').first['name'] = name
      of(@target, 'tag').first['name'] = name
      rejects('invalid_tag_name')
    end
  end

  def test_long_names_are_checked_in_characters
    ['x' * 255, '🚀' * 255].each do |name|
      of(@source, 'tag').first['name'] = name
      of(@target, 'tag').first['name'] = name
      assert_empty compare.failures
    end
    of(@source, 'tag').first['name'] = 'x' * 256
    of(@target, 'tag').first['name'] = 'x' * 256
    rejects('tag_name_exceeds_target_limit')
  end

  def test_bad_destination_counter_and_false_count_evidence
    of(@target, 'tag').first['taggings_count'] = 99
    rejects('taggings_count_mismatch')
    of(@target, 'tag').first['actual_taggings_count'] = 99
    rejects('physical_count_evidence_mismatch')
  end

  def test_lost_and_extra_objects_including_unlabelled_objects
    row = of(@target, 'object').last
    @target.delete(row)
    rejects('object_coverage')
    @target << row.merge('id' => 999, 'csid' => 'DEMO-9999')
    rejects('object_coverage')
  end

  def test_collapsed_duplicate_is_not_a_set
    @source << of(@source, 'assignment').first.merge('id' => 999)
    rejects('duplicate_assignment_projection')
    rejects('assignment expected=2 actual=1')
  end

  def test_duplicates_on_both_sides_still_fail_profile
    @source << of(@source, 'assignment').first.merge('id' => 999)
    @target << of(@target, 'assignment').first.merge('id' => 999)
    rejects('duplicate_assignment_projection')
  end

  def test_every_incompatible_context_and_tagger_is_rejected
    [nil, '', 'other'].each do |context|
      of(@source, 'assignment').first['context'] = context
      rejects('unsupported_context')
    end
    of(@source, 'assignment').first['context'] = 'tags'
    [{ 'tagger_id' => 1 }, { 'tagger_type' => 'User' }, { 'tagger_type' => '' }].each do |extra|
      row = of(@source, 'assignment').first
      row['tagger_id'], row['tagger_type'] = nil, nil
      row.merge!(extra)
      rejects('non_null_tagger')
    end
  end

  def test_orphans_and_unknown_types_are_not_filtered
    row = of(@source, 'assignment').first
    row['tag_id'] = 999
    rejects('orphan_tag')
    row['taggable_id'] = 999
    rejects('orphan_object')
    row['taggable_type'] = 'issue'
    rejects('unsupported_type')
  end

  def test_duplicate_primary_keys_and_ambiguous_logical_objects
    @source << of(@source, 'object').first.dup
    rejects('duplicate_object_id')
    rejects('ambiguous_logical_object')
    @target << of(@target, 'tag').first.dup
    rejects('duplicate_tag_id')
    @target << of(@target, 'assignment').first.dup
    rejects('duplicate_assignment_id')
  end

  def test_dates_are_preserved_and_nil_is_not_an_empty_timestamp
    row = of(@target, 'assignment').first
    row['created_at'] = '2024-01-01T00:00:00.000001Z'
    rejects('assignment_timestamp')
    row['created_at'] = nil
    rejects('assignment_timestamp')
    row['created_at'] = ''
    rejects('invalid_timestamp')
    of(@target, 'tag').last['updated_at'] = '2024-01-01T00:00:00Z'
    rejects('tag_catalog_or_dates')
  end

  def test_renumbering_uses_source_id_project_and_verified_from
    issue = of(@source, 'object').first
    target = of(@target, 'object').first
    target['csid'] = 'NEW-0020'
    @report['entries'] << { 'code' => 'identity_renumbered', 'subject' => "item:#{issue['id']}",
                            'detail' => { 'from' => issue['csid'], 'to' => target['csid'] } }
    assert_empty compare.failures
    @report['entries'].last['detail']['from'] = 'WRONG'
    rejects('report_from_mismatch')
  end

  def test_same_csid_or_wiki_title_in_different_projects_does_not_alias
    of(@target, 'object').find { |row| row['type'] == 'WikiPage' }['project'] = 'other-project'
    rejects('object_coverage')
    rejects('assignment expected=')
  end

  def test_absorbed_unlabelled_issue_requires_report_and_tagged_issue_fails
    issue = of(@source, 'object').last
    @target.delete(of(@target, 'object').last)
    @report['entries'] << { 'code' => 'document_item_absorbed', 'subject' => "##{issue['id']} invented",
                            'detail' => { 'project' => issue['project'] } }
    assert_empty compare.failures
    assignment = of(@source, 'assignment').first.merge('id' => 999, 'taggable_id' => issue['id'])
    @source << assignment
    rejects('absorbed_issue_has_tags')
  end

  def test_disabled_visibility_is_not_success
    [@source, @target].each { |rows| rows.first['settings']['effective']['active_issue_tags'] = '0' }
    rejects('tag_visibility_disabled')
  end

  def test_defaults_color_mapping_and_effective_settings_are_checked
    @target.first['settings']['effective']['tags_color_theme'] = '0'
    rejects('effective_settings')
    @target.first['settings']['effective'].delete('active_wiki_tags')
    rejects('invalid_boolean_setting')
  end

  def test_schema_drift_and_missing_metadata_fail_closed
    @target.first['tables']['additional_taggings'] << { 'name' => 'context' }
    rejects('schema_columns_differ')
    @target.first.delete('tables')
    assert_raises(TagsEvidence::InvalidEvidence) { compare }
  end

  def test_no_names_in_default_output_but_explicit_show_names_works
    of(@target, 'tag').first['name'] = 'CHANGED'
    result = compare
    output = StringIO.new
    result.print(output)
    refute_includes output.string, 'Private,A'
    refute_includes output.string, 'CHANGED'
    assert_includes output.string, 'fingerprint='
    paths = [write('source', @source), write('target', @target)]
    report_path = File.join(@directory, 'report.json')
    File.write(report_path, JSON.generate(@report))
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, File.join(__dir__, 'compare.rb'), *paths, report_path, '--show-names')
    assert_equal 1, status.exitstatus, stderr
    assert_includes stdout, 'Private,A'
  end

  def test_cli_status_success_difference_and_invalid_evidence
    source, target = write('source', @source), write('target', @target)
    report = File.join(@directory, 'report.json')
    File.write(report, JSON.generate(@report))
    command = [RbConfig.ruby, File.join(__dir__, 'compare.rb'), source, target, report]
    stdout, stderr, status = Open3.capture3(*command)
    assert_equal 0, status.exitstatus, stderr
    assert_includes stdout, 'Failures (0)'
    @target.delete(of(@target, 'tag').last)
    write('target', @target)
    assert_equal 1, Open3.capture3(*command).last.exitstatus
    File.write(target, File.readlines(target)[0...-1].join)
    stdout, stderr, status = Open3.capture3(*command)
    assert_equal 2, status.exitstatus
    assert_includes stderr, 'missing metadata or footer'
    refute_includes stdout + stderr, 'Private,A'
  end

  def test_checksum_footer_counts_and_side_are_required
    path = write('source', @source)
    File.write(path, File.read(path).sub('Private,A', 'private,A'))
    assert_raises(TagsEvidence::InvalidEvidence) { TagsEvidence::Document.new(path) }
    File.write(path, File.read(path) + "{}\n")
    assert_raises(TagsEvidence::InvalidEvidence) { TagsEvidence::Document.new(path) }
    @source.first['side'] = 'target'
    assert_raises(TagsEvidence::InvalidEvidence) { compare }
  end

  def test_order_is_information_and_never_a_success_claim
    of(@source, 'object').first['source_order'] = [1, 2]
    of(@target, 'object').first['source_order'] = [2, 1]
    result = compare
    assert_empty result.failures
    assert result.information.any? { |line| line.include?('observation_equal=false') }
  end

  def test_two_empty_tables_are_valid_but_missing_tables_are_not
    [@source, @target].each { |rows| rows.reject! { |row| %w[tag assignment].include?(row['kind']) } }
    assert_empty compare.failures
    @source.first['tables'].delete('additional_tags')
    assert_raises(TagsEvidence::InvalidEvidence) { compare }
  end

  def test_entirely_empty_inventory_does_not_bypass_metadata
    @source = [@source.first]
    @target = [@target.first]
    assert_empty compare.failures
    @target.first['plugins'] = []
    rejects('missing_plugin_evidence')
  end

  def test_missing_context_is_different_from_null
    of(@source, 'assignment').first.delete('context')
    rejects('missing_field_context')
    rejects('unsupported_context')
  end

  def test_unknown_columns_are_not_discarded
    of(@source, 'tag').first['unknown'] = 'invented'
    rejects('unexpected_tag_field')
    of(@target, 'assignment').first['tagger_type'] = nil
    rejects('unexpected_assignment_field')
  end

  def generated(subject, kind, csid, from)
    { 'code' => 'item_generated', 'subject' => subject,
      'detail' => { 'kind' => kind, 'project' => 'demo', 'csid' => csid, 'from' => from } }
  end

  def generated_object(id, csid)
    { 'kind' => 'object', 'id' => id, 'type' => 'Issue', 'project' => 'demo', 'csid' => csid, 'source_order' => nil }
  end

  def test_generated_chapter_needs_its_announcement_and_final_identity_and_no_tags
    @report['entries'] += [
      { 'code' => 'synthetic_chapter', 'subject' => 'Invented chapter', 'detail' => { 'around' => 'item:1' } },
      generated('item:group-1', 'group', 'DEMO-0010', 'item:1')
    ]
    @target << generated_object(110, 'DEMO-0010')
    result = compare
    assert_empty result.failures
    assert_includes result.information, 'generated_unlabelled_item kind=group subject=item:group-1 (report)'
    @target << of(@target, 'assignment').first.merge('id' => 110, 'taggable_id' => 110)
    rejects('generated_item_has_tags')
    rejects('assignment expected=0 actual=1')
    @target.pop
    @target.pop
    rejects('object_coverage expected=1 actual=0')
  end

  def test_generated_chapter_without_its_identity_or_announcement_is_invalid
    chapter = { 'code' => 'synthetic_chapter', 'subject' => 'Invented chapter', 'detail' => { 'around' => 'item:1' } }
    @target << generated_object(110, 'DEMO-0010')
    @report['entries'] = [chapter]
    assert_raises(TagsEvidence::InvalidEvidence) { compare }
    # The old contract (a renumbering of item:group-N) is not an identity.
    @report['entries'] = [chapter, { 'code' => 'identity_renumbered', 'subject' => 'item:group-1',
                                     'detail' => { 'from' => nil, 'to' => 'DEMO-0010' } }]
    assert_raises(TagsEvidence::InvalidEvidence) { compare }
    @report['entries'] = [generated('item:group-1', 'group', 'DEMO-0010', 'item:1')]
    assert_raises(TagsEvidence::InvalidEvidence) { compare }
    [generated('item:group-1', 'datum', 'DEMO-0010', 'item:1'), generated('item:group-1', 'group', 'DEMO-0010', 'item:2'),
     generated('item:group-1', 'group', nil, 'item:1')].each do |wrong|
      @report['entries'] = [chapter, wrong]
      assert_raises(TagsEvidence::InvalidEvidence) { compare }
    end
  end

  def test_generated_data_chapter_and_datum_match_their_announcements
    issue = of(@source, 'object').first
    @report['entries'] += [
      { 'code' => 'data_section_created', 'subject' => 'item:data-1', 'detail' => { 'project' => 'demo', 'csid' => 'DEMO-0011', 'data' => 1 } },
      { 'code' => 'datum_created', 'subject' => "item:datum-#{issue['id']}",
        'detail' => { 'variable' => 'speed', 'value' => '3', 'requirement' => "item:#{issue['id']}" } },
      generated('item:data-1', 'data_section', 'DEMO-0011', nil),
      generated("item:datum-#{issue['id']}", 'datum', 'speed', "item:#{issue['id']}")
    ]
    @target << generated_object(111, 'DEMO-0011') << generated_object(112, 'speed')
    result = compare
    assert_empty result.failures
    assert_equal 2, result.information.count { |line| line.start_with?('generated_unlabelled_item') }

    @target << of(@target, 'assignment').first.merge('id' => 112, 'taggable_id' => 112)
    rejects('generated_item_has_tags')
    @target.pop

    # Each generated entry must agree with its announcement.
    [[2, 'csid', 'DEMO-0099'], [0, 'csid', 'DEMO-0099'], [3, 'csid', 'other'], [3, 'from', "item:#{issue['id'] + 1}"],
     [2, 'from', 'item:1'], [1, 'variable', 'other']].each do |index, key, wrong|
      saved = @report['entries'][index]['detail'][key]
      @report['entries'][index]['detail'][key] = wrong
      assert_raises(TagsEvidence::InvalidEvidence, "#{index} #{key}") { compare }
      @report['entries'][index]['detail'][key] = saved
    end
    assert_empty compare.failures

    # A generated item belongs to the project of its origin.
    @report['entries'][3]['detail']['project'] = 'other-project'
    rejects('report_generated_project_mismatch')
  end

  # Every new cosmoSys instance brings projects of its own (help wikis): they
  # are not part of the migration. Unlabelled, they are only counted; with any
  # tag they fail. An extra object in a project of the source still fails.
  def test_unlabelled_objects_of_projects_outside_the_source_are_information
    @target << { 'kind' => 'object', 'id' => 801, 'type' => 'WikiPage', 'project' => 'help-a', 'title' => 'Wiki', 'source_order' => nil }
    @target << { 'kind' => 'object', 'id' => 802, 'type' => 'WikiPage', 'project' => 'help-b', 'title' => 'Start', 'source_order' => nil }
    @target << { 'kind' => 'object', 'id' => 803, 'type' => 'Issue', 'project' => 'help-b', 'csid' => 'HELP-0001', 'source_order' => nil }
    result = compare
    assert_empty result.failures
    assert_includes result.information, 'foreign_unlabelled_objects count=3 Issue=1 WikiPage=2 projects=2 (target projects that are not in the source)'

    @target << of(@target, 'assignment').first.merge('id' => 900, 'taggable_type' => 'WikiPage', 'taggable_id' => 802)
    result = rejects('foreign_object_has_tags')
    assert result.failures.any? { |line| line.start_with?('assignment expected=0 actual=1') }
  end

  def test_an_extra_object_in_a_source_project_still_fails
    @target << { 'kind' => 'object', 'id' => 801, 'type' => 'WikiPage', 'project' => 'demo', 'title' => 'Extra', 'source_order' => nil }
    result = rejects('object_coverage')
    refute result.information.any? { |line| line.start_with?('foreign_unlabelled_objects') }
  end

  def test_same_csid_in_independent_projects_is_valid
    [@source, @target].each do |rows|
      objects = of(rows, 'object')
      objects[1]['project'] = 'other-project'
      objects[1]['csid'] = objects[0]['csid']
    end
    assert_empty compare.failures
  end

  def test_split_comma_label_adds_assignments_even_when_catalog_parts_already_exist
    original = of(@target, 'tag').first
    original['name'] = 'Private'
    part = of(@target, 'tag').find { |row| row['name'] == 'A' }
    of(@target, 'assignment').select { |row| row['tag_id'] == original['id'] }.each_with_index do |row, index|
      @target << row.merge('id' => 500 + index, 'tag_id' => part['id'])
    end
    result = rejects('assignment expected=0 actual=1')
    assert result.failures.any? { |line| line.include?("tag_sha256=#{Digest::SHA256.hexdigest('Private,A')[0, 16]}") }
  end

  def test_duplicate_json_keys_and_missing_footer_counts_are_invalid
    path = write('source', @source)
    content = File.read(path).sub('"name":"Private,A"', '"name":"lost","name":"Private,A"')
    File.write(path, content)
    assert_raises(TagsEvidence::InvalidEvidence) { TagsEvidence::Document.new(path) }
    path = write('source', @source)
    lines = File.readlines(path)
    footer = JSON.parse(lines.pop)
    footer['counts']['tag'] -= 1
    File.write(path, lines.join + TagsEvidence.json(footer) + "\n")
    assert_raises(TagsEvidence::InvalidEvidence) { TagsEvidence::Document.new(path) }
  end
end
