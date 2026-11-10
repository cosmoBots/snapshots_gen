# frozen_string_literal: true

require 'minitest/autorun'
require 'stringio'
require 'tmpdir'
require 'open3'
require_relative 'compare_history'

class CompareHistoryTest < Minitest::Test
  def item(id = 1, csid = 'DEMO-0001', project = 'demo')
    {
      'format' => 'history-text-v2', 'language' => 'es', 'id' => id, 'project' => project,
      'csid' => csid, 'author' => 'Example', 'author_login' => 'example',
      'created' => '2020-01-01T00:00:00.000000Z', 'updated' => '2020-01-01T00:00:00.000000Z',
      'closed' => nil, 'watchers' => [], 'watcher_logins' => [], 'time' => 0,
      'tracker_default_status' => 'New', 'journals' => []
    }
  end

  def detail(field = 'subject', old = 'before', value = 'after', **options)
    { 'id' => options.fetch(:id, 1), 'property' => options.fetch(:property, 'attr'),
      'prop_key' => options.fetch(:key, field), 'field' => field, 'label' => options.fetch(:label, field),
      'old_value' => old, 'value' => value, 'ref' => options[:ref],
      'old_ref' => options[:old_ref], 'value_ref' => options[:value_ref],
      'rendered' => options.fetch(:rendered, ["#{field} changed from #{old} to #{value}"]) }
  end

  def journal(details = [], notes = '', id = 1)
    { 'id' => id, 'at' => '2020-01-01T00:00:00.000000Z', 'by' => 'Example', 'by_login' => 'example',
      'private' => false, 'edited' => false, 'notes' => notes, 'details' => details.flat_map { |d| d['rendered'] },
      'raw_details' => details }
  end

  def report(code, subject, **details)
    { 'entries' => [{ 'code' => code, 'subject' => subject, 'detail' => details.transform_keys(&:to_s) }] }
  end

  def copy(value)
    Marshal.load(Marshal.dump(value))
  end

  def compare(source, target, evidence = {}, **options)
    source = [source] if source.is_a?(Hash)
    target = [target] if target.is_a?(Hash)
    HistoryComparison::Comparison.new(source, target, evidence, **options).run
  end

  def compare_detail(before, after, evidence = {})
    source, target = item, item(101)
    source['journals'] = [journal([before])]
    target['journals'] = [journal([after], '', 101)]
    compare(source, target, evidence)
  end

  def test_equal_histories_and_same_csids_in_different_projects
    a, b = item, item(2, 'DEMO-0001', 'other')
    a['journals'] = [journal([detail])]
    assert compare([a, b], [copy(b), copy(a)]).ok?
  end

  def test_requires_v2_instead_of_silently_accepting_old_extracts
    assert_raises(ArgumentError) { compare({ 'csid' => 'DEMO-0001' }, item) }
    bad = item
    bad['journals'] = [{ 'id' => 1 }]
    assert_raises(KeyError) { compare(bad, item) }
    bad = item
    bad['language'] = 'en'
    assert_raises(ArgumentError) { compare(item, bad) }
  end

  def test_duplicate_item_and_destination_identity_are_rejected
    assert_raises(ArgumentError) { compare([item, item], []) }
    assert_raises(ArgumentError) { compare(item, [item, item(2)]) }
    a, b = item, item(2, 'DEMO-0002')
    a['journals'] = [journal]
    b['journals'] = [journal]
    assert_raises(ArgumentError) { compare([a, b], []) }
  end

  def test_author_logins_dates_watchers_time_and_journal_metadata_are_hard_failures
    %w[author author_login created updated closed watchers watcher_logins time].each do |key|
      target = item(101)
      target[key] = 'changed'
      refute compare(item, target).ok?, key
    end
    %w[at by by_login private].each do |key|
      source, target = item, item(101)
      source['journals'] = [journal]
      target['journals'] = [journal([], '', 101)]
      target['journals'][0][key] = 'changed'
      refute compare(source, target).ok?, key
    end
  end

  def test_missing_or_extra_item_needs_exact_evidence
    result = compare(item, [])
    assert_equal 1, result.failures.length
    result = compare([], item)
    assert_equal 1, result.unexplained.length
    result = compare(item, [], report('document_item_absorbed', '#2 AD1', document: 'Example'))
    refute result.ok?
    result = compare(item, [], report('document_item_absorbed', '#1 AD1', document: 'Example'))
    assert result.ok?
    assert result.explained.keys.first.include?('document_item_absorbed')
  end

  def test_renumbering_is_per_source_id_project_and_exact_old_new_value
    source, target = item, item(101, 'DEMO-0020')
    proof = report('identity_renumbered', 'item:1', from: 'DEMO-0001', to: 'DEMO-0020')
    assert compare(source, target, proof).ok?
    assert compare(source, target, report('identity_prefix_normalized', 'item:1', from: 'DEMO-0001', to: 'DEMO-0020')).ok?
    refute compare(source, target).ok?
    proof['entries'][0]['detail']['from'] = 'DEMO-0002'
    refute compare(source, target, proof).ok?
    target['project'] = 'other'
    refute compare(source, target).ok?
  end

  def test_prefix_normalized_items_are_compared_and_reveal_lost_parent_changes
    source, target = item, item(101, 'NORMAL-0001')
    before = detail('parent_id', '99', '1', ref: 'items', old_ref: { 'kind' => 'items', 'missing' => '99' },
                    value_ref: { 'kind' => 'items', 'id' => 1 })
    source['journals'] = [journal([before])]
    evidence = report('identity_prefix_normalized', 'item:1', from: 'DEMO-0001', to: 'NORMAL-0001')
    result = compare(source, target, evidence)
    assert result.failures.any? { |message| message.include?('1 journals -> 0') }
    target['journals'] = [journal([], '', 101)]
    result = compare(source, target, evidence)
    assert result.failures.any? { |message| message.include?('missing or changed attr/parent_id') }
  end

  def test_duplicate_source_csid_can_be_resolved_by_report_but_cannot_reuse_target
    a, b = item, item(2)
    proof = report('identity_renumbered', 'item:2', from: 'DEMO-0001', to: 'DEMO-0002')
    assert compare([a, b], [item(101), item(102, 'DEMO-0002')], proof).ok?
    refute compare([a, b], [item(101)]).ok?
  end

  def test_generated_groups_and_data_need_package_identity_and_report
    row = item(101, 'DEMO-0005')
    history = { 'projects' => [{ 'id' => 1, 'identifier' => 'demo' }],
                'items' => [{ 'key' => 'item:group-1', 'project_id' => 1, 'csid' => 'DEMO-0005', 'synthetic' => 'group' }] }
    proof = report('synthetic_chapter', 'Group', around: 'item:1')
    assert compare([], row, proof, history: history).ok?
    refute compare([], row, proof).ok?
    refute compare([], row, {}, history: history).ok?
    row['journals'] = [journal]
    refute compare([], row, proof, history: history).ok?
    row['journals'] = []
    history['items'][0] = { 'key' => 'item:datum-1', 'project_id' => 1, 'csid' => 'DEMO-0005', 'synthetic' => 'datum' }
    proof = report('datum_created', 'item:datum-1', variable: 'DEMO-0005')
    assert compare([], row, proof, history: history).ok?
    history['items'][0]['synthetic'] = 'data_section'
    refute compare([], row, proof, history: history).ok?
  end

  def test_notes_use_exact_item_mapping_and_never_blanket_number_normalization
    source, target = item, item(101)
    source['journals'] = [journal([], 'See #1 and #2')]
    target['journals'] = [journal([], 'See #101 and #102', 101)]
    sources, targets = [source, item(2, 'DEMO-0002')], [target, item(102, 'DEMO-0002')]
    assert compare(sources, targets).ok?
    target['journals'][0]['notes'] = 'See #102 and #102'
    refute compare(sources, targets).ok?
    target['journals'][0]['notes'] = 'See #1 and #2'
    refute compare(sources, targets).ok?
  end

  def test_unchanged_unknown_item_reference_still_needs_neutralization_evidence
    source, target = item, item(101)
    source['journals'] = [journal([], 'See #99')]
    target['journals'] = [journal([], 'See #99', 101)]
    result = compare(source, target)
    assert_empty result.failures
    refute_empty result.unexplained
  end

  def test_notes_escape_only_reported_unknown_reference_in_the_specific_journal
    source, target = item, item(101)
    source['journals'] = [journal([], 'See #99, !#98 and x#1')]
    target['journals'] = [journal([], 'See !#99, !#98 and x#1', 101)]
    proof = report('reference_neutralized', 'journal #1', reference: 99)
    assert compare(source, target, proof).ok?
    refute compare(source, target).ok?
    proof['entries'][0]['subject'] = 'journal #2'
    refute compare(source, target, proof).ok?
  end

  def test_missing_journal_is_failure_and_report_cannot_hide_notes
    source = item
    source['journals'] = [journal([], 'preserve me')]
    proof = report('history_journal_dropped', 'journal #1', item: 'item:1', reason: 'empty')
    refute compare(source, item(101), proof).ok?
    source['journals'][0]['notes'] = ''
    assert compare(source, item(101), proof).ok?
    proof['entries'][0]['detail']['item'] = 'item:2'
    refute compare(source, item(101), proof).ok?
  end

  def test_reported_detail_loss_is_exact_and_cannot_hide_other_detail
    before = detail('csID', 'x', 'y', property: 'cf', key: '8')
    source, target = item, item(101)
    source['journals'] = [journal([before], 'keep')]
    target['journals'] = [journal([], 'keep', 101)]
    proof = report('history_detail_dropped', 'detail #1', item: 'item:1', reason: 'csID: duplicate')
    assert compare(source, target, proof).ok?
    refute compare(source, target).ok?
    source['journals'][0] = journal([before, detail('subject', 'x', 'y', id: 2)], 'keep')
    refute compare(source, target, proof).ok?
  end

  def test_empty_journal_requires_all_detail_drops_to_be_reported
    source = item
    source['journals'] = [journal([detail('csID', 'x', 'y', property: 'cf')])]
    proof = report('history_journal_dropped', 'journal #1', item: 'item:1', reason: 'empty')
    refute compare(source, item(101), proof).ok?
    proof['entries'] += report('history_detail_dropped', 'detail #1', item: 'item:1', reason: 'csID')['entries']
    assert compare(source, item(101), proof).ok?
  end

  def test_native_field_mapping_requires_exact_mapped_value
    before = detail('rqType', 'Complex', 'Hw', property: 'cf', key: '8', label: 'rqType')
    after = detail('rq_type', 'complex', 'hardware', label: 'Tipo', rendered: ['Tipo changed from complex to hardware'])
    result = compare_detail(before, after)
    assert result.ok?, result.unexplained.inspect + result.failures.inspect
    after['value'] = 'software'
    refute compare_detail(before, after).ok?
  end

  def test_all_native_field_rules_preserve_or_map_both_values_exactly
    HistoryComparison::Rules::NATIVE_ISSUE_FIELDS.each do |name, native|
      old = native['map'] ? native['map'].keys.first : 'exact text'
      value = native['map'] ? native['map'].keys.last : 'new text'
      before = detail(name, old, value, property: 'cf', rendered: [])
      after = detail(native['field'], native['map'] ? native['map'][old] : old,
                     native['map'] ? native['map'][value] : value, rendered: [])
      assert compare_detail(before, after).ok?, name
      after['value'] = 'wrong'
      refute compare_detail(before, after).ok?, name
    end
  end

  def test_field_label_rule_does_not_rewrite_a_literal_value
    before = detail('csOldCode', 'csOldCode', 'csOldCode', property: 'cf', label: 'csOldCode')
    after = detail('cs_ext_code', 'csOldCode', 'csOldCode', label: 'csExtCode',
                   rendered: ['csExtCode changed from csExtCode to csExtCode'])
    result = compare_detail(before, after)
    assert_empty result.failures
    refute_empty result.unexplained
  end

  def status_detail(name, raw_id, **options)
    detail('status_id', nil, raw_id, ref: 'statuses', value_ref: { 'kind' => 'statuses', 'name' => name },
           rendered: ["Status set to #{name}"], **options)
  end

  def test_status_mapping_and_tracker_default_are_value_specific
    before, after = status_detail('rqZombie', '1'), status_detail('Erased', '101')
    assert compare_detail(before, after).ok?
    after = status_detail('Rejected', '102')
    refute compare_detail(before, after).ok?
    assert compare_detail(status_detail('csNone', '1'), status_detail('New', '101')).ok?
    refute compare_detail(status_detail('csNone', '1'), status_detail('Stable', '102')).ok?
  end

  def test_tracker_mapping_does_not_accept_arbitrary_renames
    before = detail('tracker_id', nil, '1', ref: 'trackers', value_ref: { 'kind' => 'trackers', 'name' => 'rq' }, rendered: ['Tracker set to rq'])
    after = detail('tracker_id', nil, '101', ref: 'trackers', value_ref: { 'kind' => 'trackers', 'name' => 'csRq' }, rendered: ['Tracker set to csRq'])
    assert compare_detail(before, after).ok?
    after['value_ref']['name'] = 'csInfo'
    refute compare_detail(before, after).ok?
  end

  def test_parent_label_and_item_id_mapping_are_narrow
    before = detail('parent_id', nil, '1', ref: 'items', value_ref: { 'kind' => 'items', 'id' => 1 }, label: 'Tarea padre', rendered: ['Tarea padre set to #1'])
    after = detail('parent_id', nil, '101', ref: 'items', value_ref: { 'kind' => 'items', 'id' => 101 }, label: 'Item padre', rendered: ['Item padre set to #101'])
    assert compare_detail(before, after).ok?
    after['rendered'] = ['Item padre set to #999']
    result = compare_detail(before, after)
    assert_empty result.failures
    refute_empty result.unexplained
    after['value_ref']['id'] = 999
    refute_empty compare_detail(before, after).failures
  end

  def test_rendered_reference_replacements_never_cascade
    source, other, target, other_target = item, item(101, 'DEMO-0002'), item(101), item(201, 'DEMO-0002')
    before = detail('parent_id', '1', '101', ref: 'items', old_ref: { 'kind' => 'items', 'id' => 1 },
                    value_ref: { 'kind' => 'items', 'id' => 101 }, rendered: ['Parent changed from #1 to #101'])
    after = detail('parent_id', '101', '201', ref: 'items', old_ref: { 'kind' => 'items', 'id' => 101 },
                   value_ref: { 'kind' => 'items', 'id' => 201 }, rendered: ['Parent changed from #101 to #201'])
    source['journals'], target['journals'] = [journal([before])], [journal([after], '', 101)]
    assert compare([source, other], [target, other_target]).ok?
  end

  def test_reference_identity_includes_project_and_login
    before = detail('fixed_version_id', nil, '1', ref: 'versions', value_ref: { 'kind' => 'versions', 'project' => 'demo', 'name' => 'v1' })
    after = copy(before)
    after['value'] = '101'
    assert compare_detail(before, after).ok?
    after['value_ref']['project'] = 'other'
    refute compare_detail(before, after).ok?
    before = detail('assigned_to_id', nil, '1', ref: 'users', value_ref: { 'kind' => 'users', 'login' => 'example' })
    after = copy(before)
    after['value_ref']['login'] = 'different'
    refute compare_detail(before, after).ok?
  end

  def test_decimal_hours_formatting_is_restricted_to_estimated_hours_and_exact_minutes
    before = detail('estimated_hours', nil, '0.0', rendered: ['Estimated hours set to 0.00 h'])
    after = detail('estimated_hours', nil, '0.0', rendered: ['Estimated hours set to 0:00 h'])
    assert compare_detail(before, after).ok?
    after['rendered'] = ['Estimated hours set to 1:00 h']
    refute compare_detail(before, after).ok?
    before['field'] = after['field'] = 'subject'
    refute compare_detail(before, after).ok?
  end

  def test_literal_numbers_tags_and_unknown_rendered_changes_are_not_explained
    before = detail('subject', '#1', '#2')
    after = detail('subject', '#101', '#102')
    refute compare_detail(before, after).ok?
    before = detail('tag_list', 'A,B', 'a,B')
    after = detail('tag_list', 'A,B', 'A,B')
    refute compare_detail(before, after).ok?
    after = copy(before)
    after['rendered'] = ['unexplained']
    result = compare_detail(before, after)
    assert_empty result.failures
    refute_empty result.unexplained
  end

  def test_kept_custom_field_cannot_silently_change_its_format
    before = detail('Example field', nil, 'text', property: 'cf')
    before['field_format'], before['multiple'] = 'text', false
    after = copy(before)
    assert compare_detail(before, after).ok?
    after['field_format'] = 'list'
    refute compare_detail(before, after).ok?
  end

  def test_description_references_preserve_target_identity
    before = detail('description', '#1', '#1')
    after = detail('description', '#101', '#101')
    assert compare_detail(before, after).ok?
    after['value'] = '#102'
    refute compare_detail(before, after).ok?
  end

  def test_extra_detail_and_duplicates_fail_even_if_rendered_strings_look_identical
    source, target = item, item(101)
    source['journals'] = [journal([detail])]
    target['journals'] = [journal([detail, detail(id: 2)], '', 101)]
    refute compare(source, target).ok?
  end

  def test_aggregate_rendering_cannot_hide_a_loss
    source, target = item, item(101)
    source['journals'] = [journal([detail])]
    target['journals'] = [journal([detail], '', 101)]
    target['journals'][0]['details'] = ['corrupt aggregate']
    refute_empty compare(source, target).unexplained
  end

  def test_translation_missing_edited_and_unresolved_references_fail_even_without_source
    target = item(101)
    target['journals'] = [journal([detail('cs_wload', nil, '1', rendered: ['Translation missing: field_cs_wload'])], '', 101)]
    assert compare([], target).failures.any? { |message| message.include?('Translation missing') }
    target['journals'][0]['edited'] = true
    assert compare([], target).failures.any? { |message| message.include?('edited') }
    target['journals'][0]['raw_details'][0]['value_ref'] = { 'kind' => 'items', 'missing' => '1' }
    assert compare([], target).failures.any? { |message| message.include?('unresolved') }
  end

  def test_importer_discards_fail_instead_of_excusing_a_loss
    imports = [{ 'dropped' => [{ 'kind' => 'journal', 'id' => 5, 'reason' => 'no detail could be translated' }] }]
    result = compare(item, item(101), {}, import_reports: imports)
    assert result.failures.any? { |message| message.include?('journal #5: no detail could be translated') }
    imports[0]['dry_run'] = true
    assert_raises(ArgumentError) { compare(item, item(101), {}, import_reports: imports) }
  end

  def templates
    { 'set_to' => '%{label} establecido a %{value}', 'added' => 'Añadido %{label} %{value}',
      'deleted' => '%{label} eliminado (%{old})', 'changed' => '%{label} cambiado de %{old} a %{new}',
      'changed_no_detail' => 'Se actualizó %{label}' }
  end

  def compare_native_render(before, after, **options)
    source, target = item, item(101)
    source['render_templates'] = target['render_templates'] = templates
    source['journals'] = [journal([before])]
    target['journals'] = [journal([after], '', 101)]
    compare(source, target, **options)
  end

  def test_r4_translated_enum_labels_still_require_exact_machine_values
    before = detail('rqType', 'Complex', 'Hw', property: 'cf', label: 'rqType',
                    rendered: ['rqType cambiado de Complex a Hw'])
    before['display_old'], before['display_value'] = 'Complex', 'Hw'
    after = detail('rq_type', 'complex', 'hardware', label: 'Tipo de requisito',
                   rendered: ['Tipo de requisito cambiado de Complejo a Hardware'])
    after['display_old'], after['display_value'] = 'Complejo', 'Hardware'
    assert compare_native_render(before, after).ok?
    after['value'] = 'software'
    refute compare_native_render(before, after).ok?
    after['value'] = 'hardware'
    after['rendered'] = ['Tipo de requisito cambiado de Complejo a Software']
    refute_empty compare_native_render(before, after).unexplained
  end

  def test_r5_added_verification_becomes_set_to_without_accepting_extra_lines
    before = detail('rqVerif', nil, 'Design', property: 'cf', label: 'rqVerif', rendered: ['Añadido rqVerif Design'])
    before['display_value'] = 'Design'
    before['multiple'] = true
    after = detail('rq_verif_methods', nil, 'design', label: 'Metodos de verificacion',
                   rendered: ['Metodos de verificacion establecido a Diseño'])
    after['display_value'] = 'Diseño'
    assert compare_native_render(before, after).ok?
    after['rendered'] << 'Metodos de verificacion establecido a Test'
    refute compare_native_render(before, after).ok?
    after['rendered'] = ['Metodos de verificacion establecido a Diseño']
    after['value'] = 'test'
    refute compare_native_render(before, after).ok?
  end

  def test_r6_hidden_legacy_long_text_is_compared_in_full
    before = detail('rqRationale', 'old full text', 'new full text', property: 'cf', label: 'rqRationale',
                    rendered: ['Se actualizó rqRationale'])
    before['field_format'] = 'text'
    after = detail('rq_rationale', 'old full text', 'new full text', label: 'Justificacion',
                   rendered: ['Justificacion cambiado de old full text a new full text'])
    after['display_old'], after['display_value'] = 'old full text', 'new full text'
    assert compare_native_render(before, after).ok?
    after['value'] = 'lost full text'
    refute_empty compare_native_render(before, after).failures
    after['value'] = 'new full text'
    after['rendered'] = ['Justificacion cambiado de old full text a wrong text']
    refute_empty compare_native_render(before, after).unexplained
  end

  def test_r1_relation_text_can_rename_tracker_only_for_the_mapped_item
    before = detail('copied_to', nil, '1', property: 'relation', ref: 'items',
                    value_ref: { 'kind' => 'items', 'id' => 1, 'tracker' => 'rq' }, rendered: ['Añadido copiada a rq #1'])
    after = detail('copied_to', nil, '101', property: 'relation', ref: 'items',
                   value_ref: { 'kind' => 'items', 'id' => 101, 'tracker' => 'csRq' }, rendered: ['Añadido copiada a csRq #101'])
    source, target = item, item(101)
    source['tracker'], target['tracker'] = 'rq', 'csRq'
    source['journals'], target['journals'] = [journal([before])], [journal([after], '', 101)]
    assert compare(source, target).ok?
    after['rendered'] = ['Añadido copiada a csInfo #101']
    refute compare(source, target).ok?
    after['rendered'] = ['Añadido copiada a csRq #101']
    after['value_ref']['id'] = 102
    refute compare(source, target).ok?
  end

  def test_ambiguous_tracker_text_replacements_cannot_hide_wrong_rendering
    source, other, target, other_target = item, item(2, 'DEMO-0002'), item(101), item(102, 'DEMO-0002')
    source['tracker'] = other['tracker'] = 'rq'
    other['legacy_rq_type'] = 'Info'
    target['tracker'], other_target['tracker'] = 'csRq', 'csInfo'
    before = detail('parent_id', '1', '2', ref: 'items',
                    old_ref: { 'kind' => 'items', 'id' => 1, 'tracker' => 'rq' },
                    value_ref: { 'kind' => 'items', 'id' => 2, 'tracker' => 'rq' },
                    rendered: ['Parent changed from rq #1 to rq #2'])
    after = detail('parent_id', '101', '102', ref: 'items',
                   old_ref: { 'kind' => 'items', 'id' => 101, 'tracker' => 'csRq' },
                   value_ref: { 'kind' => 'items', 'id' => 102, 'tracker' => 'csInfo' },
                   rendered: ['Parent changed from csInfo #101 to csInfo #102'])
    source['journals'], target['journals'] = [journal([before])], [journal([after], '', 101)]
    result = compare([source, other], [target, other_target])
    assert_empty result.failures
    refute_empty result.unexplained
  end

  def reference_report(code, **overrides)
    report(code, 'detail #1', **{ item: 'item:1', journal: 1, field: 'parent_id',
                                old_value: '99', value: '1', missing: ['old'] }.merge(overrides))
  end

  def test_r2_cleared_missing_parent_requires_full_matching_report
    before = detail('parent_id', '99', '1', ref: 'items', old_ref: { 'kind' => 'items', 'missing' => '99' },
                    value_ref: { 'kind' => 'items', 'id' => 1 }, label: 'Tarea padre',
                    rendered: ['Tarea padre cambiado de #99 a #1'])
    before['display_old'], before['display_value'] = '#99', '#1'
    after = detail('parent_id', nil, '101', ref: 'items', value_ref: { 'kind' => 'items', 'id' => 101 }, label: 'Item padre',
                   rendered: ['Item padre establecido a #101'])
    after['display_value'] = '#101'
    proof = reference_report('history_reference_cleared')
    source, target = item, item(101)
    source['render_templates'] = target['render_templates'] = templates
    source['journals'], target['journals'] = [journal([before])], [journal([after], '', 101)]
    assert compare(source, target, proof).ok?
    refute compare(source, target).ok?
    %i[journal field old_value value item missing].each do |key|
      wrong = reference_report('history_reference_cleared', **{ key => (key == :missing ? ['new'] : 'wrong') })
      refute compare(source, target, wrong).ok?, key
    end
    after['value_ref']['id'] = 102
    refute compare(source, target, proof).ok?
  end

  def test_reference_dropped_requires_both_sides_empty_after_clearing
    source, target = item, item(101)
    before = detail('parent_id', '99', nil, ref: 'items', old_ref: { 'kind' => 'items', 'missing' => '99' })
    source['journals'] = [journal([before], 'keep')]
    target['journals'] = [journal([], 'keep', 101)]
    proof = reference_report('history_reference_dropped', value: nil)
    assert compare(source, target, proof).ok?
    proof['entries'][0]['detail']['old_value'] = '98'
    refute compare(source, target, proof).ok?
    proof = reference_report('history_reference_dropped')
    before['value'], before['value_ref'] = '1', { 'kind' => 'items', 'id' => 1 }
    refute compare(source, target, proof).ok?
  end

  def attachment_detail(prop_key, field, old, value, id: 1)
    detail(field, old, value, id: id, property: 'attachment', key: prop_key, label: 'Fichero',
                                rendered: [value ? "Añadido Fichero #{value}" : "Fichero eliminado (#{old})"])
  end

  def attachment_report(**overrides)
    report('history_attachment_cleared', 'detail #1',
           **{ item: 'item:1', csid: 'DEMO-0001', journal: 1, attachment: '9', missing: ['old'],
               reason: 'deleted from the source', old_value: 'gone.txt', value: nil }.merge(overrides))
  end

  def test_attachment_cleared_needs_the_exact_report_entry_and_id_zero_in_the_target
    before = attachment_detail('9', { 'missing_attachment' => '9' }, 'gone.txt', nil)
    after = attachment_detail('0', { 'missing_attachment' => '0' }, 'gone.txt', nil, id: 7)
    proof = attachment_report
    result = compare_detail(before, after, proof)
    assert result.ok?, (result.failures + result.unexplained).inspect
    assert_equal 1, result.explained.keys.count { |reason| reason.start_with?('history_attachment_cleared') }

    refute compare_detail(before, after).ok?, 'without the report entry'
    { item: 'item:2', journal: 2, attachment: '8', missing: ['new'], old_value: 'other.txt', value: 'gone.txt',
      reason: 'not migrated with this item' }.each do |key, wrong|
      refute compare_detail(before, after, attachment_report(key => wrong)).ok?, key
    end
    wrong_subject = attachment_report
    wrong_subject['entries'][0]['subject'] = 'detail #2'
    refute compare_detail(before, after, wrong_subject).ok?, 'other detail'

    # The target must say 0 and keep the file name and the rendering.
    other = attachment_detail('5', { 'filename' => 'gone.txt', 'size' => 3, 'created' => nil }, 'gone.txt', nil, id: 7)
    refute compare_detail(before, other, proof).ok?, 'target names a real attachment'
    renamed = attachment_detail('0', { 'missing_attachment' => '0' }, 'renamed.txt', nil, id: 7)
    refute compare_detail(before, renamed, proof).ok?, 'file name changed'
    rendered = attachment_detail('0', { 'missing_attachment' => '0' }, 'gone.txt', nil, id: 7)
    rendered['rendered'] = ['Fichero eliminado (otro)']
    refute compare_detail(before, rendered, proof).ok?, 'rendering changed'
  end

  def test_attachment_not_migrated_with_its_item_needs_that_reason
    present = { 'filename' => 'other.txt', 'size' => 3, 'created' => '2020-01-01T00:00:00.000000Z' }
    before = attachment_detail('8', present, nil, 'other.txt')
    after = attachment_detail('0', { 'missing_attachment' => '0' }, nil, 'other.txt', id: 7)
    proof = attachment_report(attachment: '8', missing: ['new'], reason: 'not migrated with this item',
                              old_value: nil, value: 'other.txt')
    assert compare_detail(before, after, proof).ok?
    refute compare_detail(before, after, attachment_report(attachment: '8', missing: ['new'], old_value: nil,
                                                           value: 'other.txt')).ok?, 'deleted, but it exists'
    # A deleted attachment cannot be explained as not migrated either.
    gone = attachment_detail('9', { 'missing_attachment' => '9' }, 'gone.txt', nil)
    refute compare_detail(gone, attachment_detail('0', { 'missing_attachment' => '0' }, 'gone.txt', nil, id: 7),
                          attachment_report(reason: 'not migrated with this item')).ok?
  end

  def multiple_detail(id, old, value, label: 'Risk', multiple: true)
    shown = value ? "Añadido #{label} #{value}" : "#{label} eliminado (#{old})"
    row = detail('Risk', old, value, id: id, property: 'cf', key: '5', label: label, rendered: [shown])
    row.merge!('field_format' => 'list', 'multiple' => multiple, 'display_old' => old, 'display_value' => value)
  end

  # Redmine 4.2 and 7 (IssuesHelper#details_to_strings) render the values
  # added to one multiple custom field in one line, and the removed ones in
  # another, after the other changes of the journal.
  def grouped(details, lines)
    source, target = item, item(101)
    source['render_templates'] = target['render_templates'] = templates
    source['journals'] = [journal(details)]
    target['journals'] = [journal(copy(details).each_with_index.map { |row, index| row.merge('id' => 50 + index) }, '', 101)]
    source['journals'][0]['details'] = lines
    target['journals'][0]['details'] = copy(lines)
    compare(source, target)
  end

  def test_r5b_grouped_multiple_values_are_explained_only_by_the_exact_multiset
    details = [multiple_detail(1, nil, 'Alto'), multiple_detail(2, nil, 'Bajo'), multiple_detail(3, 'Medio', nil),
               detail('subject', 'before', 'after', id: 4)]
    lines = ['subject changed from before to after', 'Añadido Risk Alto, Bajo', 'Risk eliminado (Medio)']
    result = grouped(details, lines)
    assert result.ok?, result.unexplained.inspect
    assert_equal 2, result.explained.select { |reason, _rows| reason.start_with?('R5b') }.values.flatten.length
    assert grouped(details, lines.reverse).ok?, 'line order'
    assert grouped(details, [lines[0], 'Añadido Risk Bajo, Alto', lines[2]]).ok?, 'value order'

    {
      'a value missing' => [lines[0], 'Añadido Risk Alto', lines[2]],
      'a value repeated' => [lines[0], 'Añadido Risk Alto, Bajo, Bajo', lines[2]],
      'a value changed' => [lines[0], 'Añadido Risk Alto, Medio', lines[2]],
      'removed shown as added' => [lines[0], 'Añadido Risk Alto, Bajo, Medio'],
      'another label' => [lines[0], 'Añadido Riesgo Alto, Bajo', lines[2]],
      'a line missing' => lines.last(2),
      'a line repeated' => lines + [lines[2]],
      'not grouped but joined differently' => [lines[0], 'Añadido Risk Alto; Bajo', lines[2]]
    }.each do |name, wrong|
      refute grouped(details, wrong).ok?, name
    end
  end

  def test_r5b_needs_a_multiple_field_and_the_same_count_of_each_value
    single = [multiple_detail(1, nil, 'Alto', multiple: false), multiple_detail(2, nil, 'Bajo', multiple: false)]
    refute grouped(single, ['Añadido Risk Alto, Bajo']).ok?, 'not a multiple field'
    twice = [multiple_detail(1, nil, 'Alto'), multiple_detail(2, nil, 'Alto')]
    assert grouped(twice, ['Añadido Risk Alto, Alto']).ok?
    refute grouped(twice, ['Añadido Risk Alto']).ok?
    commas = [multiple_detail(1, nil, 'a, b'), multiple_detail(2, nil, 'c')]
    assert grouped(commas, ['Añadido Risk c, a, b']).ok?, 'a value with a comma'
    refute grouped(commas, ['Añadido Risk a, b']).ok?
    missing_display = [multiple_detail(1, nil, 'Alto'), multiple_detail(2, nil, 'Bajo')]
    missing_display[1]['display_value'] = nil
    refute grouped(missing_display, ['Añadido Risk Alto, Bajo']).ok?, 'no display value to prove it'
  end

  def test_data_section_is_tied_to_a_project_with_reported_variables
    source, target, section = item, item(101), item(102, 'DEMO-0002')
    section.merge!('tracker' => 'csData', 'subject' => 'Project data', 'parent_id' => nil)
    history = { 'projects' => [{ 'id' => 1, 'identifier' => 'demo' }],
                'items' => [{ 'key' => 'item:data-1', 'project_id' => 1, 'csid' => 'DEMO-0002', 'synthetic' => 'data_section', 'tracker' => 'csData' }] }
    proof = report('field_value_unmapped', 'item:1', field: 'rqVar', value: 'invalid key')
    assert compare(source, [target, section], proof, history: history).ok?
    refute compare(source, [target, section], {}, history: history).ok?
    section['subject'] = 'other section'
    refute compare(source, [target, section], proof, history: history).ok?
  end

  def test_explanations_are_grouped_and_detail_is_opt_in
    result = compare(item, [], report('document_item_absorbed', '#1 AD1'))
    out = StringIO.new
    result.print(out)
    assert_includes out.string, 'Explained differences (1)'
    assert_includes out.string, 'Unexplained differences (0)'
    assert_includes out.string, 'Failures (0)'
    refute_includes out.string, 'demo/DEMO-0001'
    out = StringIO.new
    result.print(out, details: true)
    assert_includes out.string, 'demo/DEMO-0001'
  end

  def test_history_reader_verifies_manifest_table_bytes_and_schema
    require_relative '../exporter/legacy_snapshot_format'
    format = SnapshotsGen::LegacySnapshot
    Dir.mktmpdir('comparison-package-test') do |directory|
      path = File.join(directory, 'history')
      writer = format::Writer.new(path, schema: format::HISTORY_SCHEMA)
      %w[projects items].each do |name|
        columns = [{ 'name' => 'id', 'type' => 'json', 'sql_type' => 'json', 'null' => false }]
        writer.write_table(name, columns: columns, primary_key: ['id'], order_by: ['id']) do |emit|
          emit.call('id' => 1)
        end
      end
      writer.finish!(captured_at: '2020-01-01T00:00:00Z', generator: {}, source: {}, consistency: {})
      assert_equal({ 'projects' => [{ 'id' => 1 }], 'items' => [{ 'id' => 1 }] }, HistoryComparison.read_history(path))
      File.open(File.join(path, 'tables', 'items.jsonl'), 'a') { |file| file.puts('{"id":2}') }
      assert_raises(ArgumentError) { HistoryComparison.read_history(path) }
      legacy = File.join(directory, 'legacy')
      writer = format::Writer.new(legacy)
      writer.finish!(captured_at: '2020-01-01T00:00:00Z', generator: {}, source: {}, consistency: {})
      assert_raises(ArgumentError) { HistoryComparison.read_history(legacy) }
    end
  end

  def test_cli_exit_codes_are_zero_for_pass_one_for_unexplained_and_two_for_invalid_input
    Dir.mktmpdir('history-comparison-test') do |dir|
      source, target = File.join(dir, 'source.jsonl'), File.join(dir, 'target.jsonl')
      File.write(source, JSON.generate(item) + "\n")
      File.write(target, JSON.generate(item(101)) + "\n")
      command = [RbConfig.ruby, File.expand_path('compare_history.rb', __dir__), source, target]
      out, err, status = Open3.capture3(*command)
      assert status.success?, out + err
      File.write(source, '')
      out, err, status = Open3.capture3(*command)
      assert_equal 1, status.exitstatus, out + err
      assert_includes out, 'Unexplained differences (1)'
      File.write(source, 'invalid JSON')
      _out, err, status = Open3.capture3(*command)
      assert_equal 2, status.exitstatus
      assert_includes err, 'comparison error:'
    end
  end
end
