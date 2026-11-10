# frozen_string_literal: true

require 'minitest/autorun'
require 'base64'
require_relative 'converter_fixture'
require_relative '../converter/convert'

# The tags package (.cstags) of the converter: exact names, strict profile,
# identities from the plan and nothing dropped in silence. All names are
# invented.
class ConverterTagsTest < Minitest::Test
  include ConverterFixture
  TP = SnapshotsGen::TagsPackage
  TIME = ConverterFixture::TIME
  LONG = 'x' * 255
  ENABLED = "--- !ruby/hash:ActiveSupport::HashWithIndifferentAccess\nactive_issue_tags: '1'\nactive_wiki_tags: '1'\n" \
            "open_issues_only: '0'\nshow_with_count: '1'\ntags_sidebar: cloud\ntags_sort_by: count\ntags_sort_order: desc\n" \
            "tags_suggestion_order: last_created\nuse_colors: '0'\n"

  SETTINGS_COLUMNS = [
    { 'name' => 'id', 'type' => 'integer', 'sql_type' => 'int(11)', 'null' => false },
    { 'name' => 'name', 'type' => 'string', 'sql_type' => 'varchar(255)', 'null' => false },
    { 'name' => 'value', 'type' => 'text', 'sql_type' => 'text', 'null' => true },
    { 'name' => 'updated_on', 'type' => 'datetime', 'sql_type' => 'datetime', 'null' => true }
  ].freeze

  def tag(id, name, count = 1)
    { 'id' => id, 'name' => name, 'taggings_count' => count, 'created_at' => TIME, 'updated_at' => TIME }
  end

  def tagging(id, tag_id, type, object_id, context: 'tags', tagger_type: nil, tagger_id: nil)
    { 'id' => id, 'tag_id' => tag_id, 'taggable_type' => type, 'taggable_id' => object_id, 'tagger_type' => tagger_type,
      'tagger_id' => tagger_id, 'context' => context, 'created_at' => TIME }
  end

  def tag_tables(tags, taggings, settings: ENABLED, tag_columns: ConverterFixture::TAG_COLUMNS,
                 tagging_columns: ConverterFixture::TAGGING_COLUMNS)
    tables = ConverterFixture.base_tables
    tables['additional_tags'] = { columns: tag_columns, rows: tags } if tags
    tables['additional_taggings'] = { columns: tagging_columns, rows: taggings } if taggings
    rows = settings ? [{ 'id' => 9, 'name' => 'plugin_additional_tags', 'value' => settings, 'updated_on' => TIME }] : []
    tables['settings'] = { columns: SETTINGS_COLUMNS, rows: rows }
    tables
  end

  # Converts the tables with the whole converter and yields the verified
  # package, the conversion summary and the report document.
  def convert(tables, **options)
    Dir.mktmpdir('converter-tags') do |tmp|
      legacy = ConverterFixture.legacy(File.join(tmp, 'legacy'), tables, **options)
      out = File.join(tmp, 'out')
      summary = SnapshotsGen::Converter.run(legacy, out)
      history = Dir[File.join(out, '*.cshistory')].first
      csys = Dir[File.join(out, '*.csys')]
      cstags = Dir[File.join(out, '*.cstags')]
      assert_equal 1, cstags.length
      package = TP.read(cstags.first, history: history, csys: csys)
      yield package, summary, JSON.parse(File.read(File.join(out, 'report.json'))), cstags.first, history, csys
    end
  end

  def codes(package)
    package.rows.fetch('anomalies').map { |row| row['code'] }.tally
  end

  def blocking(package)
    package.rows.fetch('anomalies').select { |row| row['severity'] == 'blocking' }.map { |row| row['code'] }.uniq.sort
  end

  def test_exact_names_identities_and_settings
    names = ['A,B', 'a', 'A', 'café', "café", 'with  two spaces', 'quote "x" and \'y\'', "emoji \u{1F600}", LONG,
             'group::one', 'group:one', 'lonely tag']
    tags = names.each_with_index.map { |name, index| tag(index + 1, name) }
    tags[0]['taggings_count'] = 5 # wrong stored counter
    taggings = [
      tagging(1, 1, 'Issue', 1), tagging(2, 1, 'Issue', 4), tagging(3, 1, 'WikiPage', 1), tagging(4, 1, 'WikiPage', 2),
      tagging(5, 2, 'Issue', 1), tagging(6, 3, 'Issue', 1), tagging(7, 4, 'Issue', 6), tagging(8, 5, 'Issue', 6),
      tagging(9, 6, 'Issue', 7), tagging(10, 7, 'Issue', 3), tagging(11, 8, 'Issue', 3), tagging(12, 9, 'Issue', 2),
      tagging(13, 10, 'Issue', 2), tagging(14, 11, 'Issue', 2)
    ]
    convert(tag_tables(tags, taggings)) do |package, summary, report|
      assert package.importable?, package.rows.fetch('anomalies').inspect
      assert_equal true, summary['tags_importable']
      assert_equal 'test.cstags', summary['tags_package']
      assert_equal %w[case_variant_names comma_in_name counter_mismatch unused_tag], codes(package).keys.sort
      # Only "A,B" has a comma; it stays one tag and is reported.
      comma = package.rows.fetch('anomalies').select { |row| row['code'] == 'comma_in_name' }
      assert_equal [[1]], comma.map { |row| row['source_ids'] }
      assert_equal 'warning', comma.first['severity']

      # Every name exactly as stored, also the unused one.
      assert_equal names, package.rows.fetch('tags').map { |row| row['name'] }
      assert_equal 255, package.rows.fetch('tags')[8]['name'].length

      objects = package.rows.fetch('objects').to_h { |row| [row['id'], row] }
      assert_equal 10, objects.length # 7 issues and 3 wiki pages, tagged or not
      target = ->(id) { objects.fetch(id)['target'] }
      assert_equal({ 'type' => 'Issue', 'project_identifier' => 'alpha', 'csid' => 'ALP-0001', 'item_key' => 'item:1' }, target.call('Issue:1'))
      # The same old CSID in another tree, and the CSIDs the plan renumbered.
      assert_equal %w[beta ALP-0001], target.call('Issue:4').values_at('project_identifier', 'csid')
      assert_equal %w[alpha ALP-0003], target.call('Issue:6').values_at('project_identifier', 'csid')
      assert_equal %w[beta BET-0001], target.call('Issue:7').values_at('project_identifier', 'csid')
      assert_equal %w[alpha-sub SUB-0001], target.call('Issue:3').values_at('project_identifier', 'csid')
      # The absorbed AD item is listed, without target, and untagged.
      assert_nil target.call('Issue:5')
      assert_equal 'absorbed_into_document', objects.fetch('Issue:5')['untargeted_reason']
      # Same wiki title in two projects: two objects.
      assert_equal({ 'type' => 'WikiPage', 'project_identifier' => 'alpha', 'title' => 'Wiki' }, target.call('WikiPage:1'))
      assert_equal({ 'type' => 'WikiPage', 'project_identifier' => 'beta', 'title' => 'Wiki' }, target.call('WikiPage:2'))
      assert objects.key?('WikiPage:3')
      assert(objects.values.all? { |row| row['source_order'].nil? })

      # One global tag on two issues and two wiki pages, never one per project.
      assert_equal %w[Issue:1 Issue:4 WikiPage:1 WikiPage:2],
                   package.rows.fetch('taggings').select { |row| row['tag_id'] == 1 }.map { |row| row['object_id'] }
      tagging = package.rows.fetch('taggings').first
      assert_equal({ 'context' => 'tags', 'created_at' => TIME, 'id' => 1, 'object_id' => 'Issue:1', 'ordinal' => 1, 'source_extra' => {},
                     'tag_id' => 1, 'taggable_id' => 1, 'taggable_type' => 'Issue', 'tagger_id' => nil, 'tagger_type' => nil }, tagging)

      content = package.content
      assert_equal 'not-preserved', content.dig('profile', 'order_policy')
      assert_equal 12, content.dig('counts', 'source_tags')
      assert_equal 14, content.dig('counts', 'source_taggings')
      assert_equal 1, content.dig('counts', 'unused_tags')
      assert_equal [{ 'id' => 'additional_tags', 'version' => '1.0.4' }, { 'id' => 'additionals', 'version' => '3.0.5.2' }],
                   content.dig('source', 'plugins')
      settings = content.dig('source', 'settings')
      assert_equal({ 'value' => '1', 'provenance' => 'stored', 'source_key' => 'active_issue_tags', 'source_value' => '1' },
                   settings['active_issue_tags'])
      assert_equal({ 'value' => '0', 'provenance' => 'mapped', 'source_key' => 'use_colors', 'source_value' => '0' },
                   settings['tags_color_theme'])
      assert_equal 'destination_default', settings.dig('show_tags_after_queries', 'provenance')
      assert_equal %w[cloud count desc last_created], %w[tags_sidebar tags_sort_by tags_sort_order tags_suggestion_order].map { |key| settings.dig(key, 'value') }
      assert_equal 'stored', content.dig('source', 'settings_provenance')
      assert_equal [true, true], content.dig('source', 'tables_present').values

      # The conversion report counts codes and never names a tag.
      assert_equal 0, report['counts'].fetch('tags_blocking', 0)
      assert_equal 3, report['counts']['tags_warning']
      assert_includes report['entries'].map { |entry| entry['subject'] }, 'comma_in_name'
      dumped = JSON.generate(report)
      names.each { |name| refute_includes dumped, JSON.generate(name)[1..-2] if name.length > 3 }
      refute(report['entries'].any? { |entry| entry['code'] == 'plugin_data_not_migrated' && entry['subject'].start_with?('additional_') })
    end
  end

  # R1 of the adversarial review: a tag removed from an item that is absorbed
  # into a document, or whose item is not in the source, leaves no current
  # tagging; its change in the history must not disappear in silence.
  def test_tag_changes_in_the_history_of_items_that_are_not_migrated_block
    tables = tag_tables([tag(1, 'one', 1)], [tagging(1, 1, 'Issue', 1)])
    tables['journals'] = [
      { 'id' => 98, 'journalized_id' => 1, 'journalized_type' => 'Issue', 'user_id' => 1, 'notes' => '', 'private_notes' => false, 'created_on' => TIME },
      { 'id' => 99, 'journalized_id' => 5, 'journalized_type' => 'Issue', 'user_id' => 1, 'notes' => '', 'private_notes' => false, 'created_on' => TIME },
      { 'id' => 100, 'journalized_id' => 999, 'journalized_type' => 'Issue', 'user_id' => 1, 'notes' => 'x', 'private_notes' => false, 'created_on' => TIME },
      { 'id' => 101, 'journalized_id' => 5, 'journalized_type' => 'Issue', 'user_id' => 1, 'notes' => 'only a note', 'private_notes' => false,
        'created_on' => TIME }
    ]
    tables['journal_details'] = [
      { 'id' => 1, 'journal_id' => 98, 'property' => 'attr', 'prop_key' => 'tag_list', 'old_value' => '', 'value' => 'one' },
      { 'id' => 2, 'journal_id' => 99, 'property' => 'attr', 'prop_key' => 'tag_list', 'old_value' => 'synthetic-old-tag', 'value' => '' },
      { 'id' => 3, 'journal_id' => 99, 'property' => 'attr', 'prop_key' => 'subject', 'old_value' => 'a', 'value' => 'b' },
      { 'id' => 4, 'journal_id' => 100, 'property' => 'attr', 'prop_key' => 'tag_list', 'old_value' => 'gone', 'value' => '' }
    ]
    convert(tables) do |package, summary, report|
      refute package.importable?
      assert summary['blocking']
      assert_equal %w[history_tag_change_dropped], blocking(package)
      dropped = package.rows.fetch('anomalies').select { |row| row['code'] == 'history_tag_change_dropped' }
      assert_equal [[2], [4]], dropped.map { |row| row['source_ids'] }
      assert_equal %w[history history], dropped.map { |row| row['table'] }
      assert_equal ['journal 99 of Issue:5: absorbed into document', 'journal 100 of Issue:999: not in source'], dropped.map { |row| row['reason'] }
      entry = report['entries'].find { |row| row['code'] == 'tags_blocking' && row['subject'] == 'history_tag_change_dropped' }
      assert_equal 2, entry['detail']['records']
      refute_includes JSON.generate(report), 'synthetic-old-tag'
    end
  end

  def test_tag_permissions_of_the_source_roles
    tables = tag_tables([tag(1, 'one', 1)], [tagging(1, 1, 'Issue', 1)])
    tables['roles'] += [
      ConverterFixture.role(6, 'Strange', 0, []).merge('permissions' => "--- !ruby/object:OpenStruct\ntable: {}\n"),
      ConverterFixture.role(7, 'Mapped', 0, []).merge('permissions' => "---\nview_issue_tags: true\n"),
      ConverterFixture.role(8, 'Empty', 0, []).merge('permissions' => nil),
      ConverterFixture.role(9, 'Quoted', 0, []).merge('permissions' => "---\n- view_issue_tags\n- \":add_wiki_tags\"\n- :x\n")
    ]
    convert(tables) do |package, _summary, report|
      assert package.importable?
      roles = package.rows.fetch('roles').to_h { |row| [row['name'], row] }
      assert_equal({ 'builtin' => 1, 'id' => 1, 'name' => 'Non member', 'ordinal' => 1, 'tag_permissions' => %w[view_issue_tags] },
                   roles['Non member'])
      assert_equal [], roles['Anonymous']['tag_permissions']
      assert_equal TP::TAG_PERMISSIONS, roles['rqMngr']['tag_permissions']
      assert_equal %w[view_issue_tags], roles['rqReader']['tag_permissions']
      assert_equal [], roles['rqWriter']['tag_permissions']
      # Never loaded as Ruby objects: a tagged or mapped value is unreadable, not guessed.
      assert_nil roles['Strange']['tag_permissions']
      assert_nil roles['Mapped']['tag_permissions']
      assert_equal [], roles['Empty']['tag_permissions']
      assert_equal %w[add_wiki_tags view_issue_tags], roles['Quoted']['tag_permissions']
      unreadable = package.rows.fetch('anomalies').select { |row| row['code'] == 'unreadable_role_permissions' }
      assert_equal [[6], [7]], unreadable.map { |row| row['source_ids'] }
      assert_equal %w[roles roles], unreadable.map { |row| row['table'] }
      assert_equal 9, package.content.dig('counts', 'source_roles')
      assert_equal 4, package.content.dig('counts', 'roles_with_tag_permissions')
      info = report['entries'].find { |entry| entry['code'] == 'tags_information' && entry['subject'] == 'package' }
      assert_equal 4, info['detail']['roles_with_tag_permissions'], info.inspect
    end
    tables = tag_tables([tag(1, 'one', 1)], [tagging(1, 1, 'Issue', 1)])
    tables.delete('roles')
    convert(tables) do |package|
      # Without roles the tags still import; nobody gets permissions from the package.
      assert package.importable?
      assert_empty package.rows.fetch('roles')
      assert_equal({ 'unreadable_role_permissions' => 1 }, codes(package))
    end
  end

  # R3 of the adversarial review: the targets are bound to the sibling
  # history by source id, so swapped targets do not verify.
  def test_verifier_binds_objects_to_the_history_by_source_id
    tables = tag_tables([tag(1, 'one', 2)], [tagging(1, 1, 'Issue', 1), tagging(2, 1, 'WikiPage', 1)])
    convert(tables) do |package, _summary, _report, _path, history, csys|
      Dir.mktmpdir('cstags-swap') do |tmp|
        content = package.content.reject { |key, _value| %w[profile files counts].include?(key) }
        forge = lambda do |label|
          rows = Marshal.load(Marshal.dump(package.rows))
          [rows, File.join(tmp, "#{label}.cstags")]
        end
        check = lambda do |label, expected, &mutate|
          rows, path = forge.call(label)
          mutate.call(rows)
          TP.write(path, content: content, rows: rows)
          errors = TP::Verifier.new(path).verify(history: history, csys: csys).errors
          assert(errors.any? { |error| error.include?(expected) }, "#{label}: #{errors.inspect}")
        end
        swap = lambda do |rows, first, second|
          a, b = [first, second].map { |id| rows['objects'].find { |row| row['id'] == id } }
          a['target'], b['target'] = b['target'], a['target']
        end
        check.call('issues', 'Issue:1 does not match the history') { |rows| swap.call(rows, 'Issue:1', 'Issue:2') }
        check.call('wiki', 'WikiPage:1 does not match the history') { |rows| swap.call(rows, 'WikiPage:1', 'WikiPage:2') }
        check.call('csid', 'Issue:2 does not match the history') do |rows|
          rows['objects'].find { |row| row['id'] == 'Issue:2' }['target']['csid'] = 'ALP-0099'
        end
        check.call('duplicate', 'objects repeat a source type and id') do |rows|
          rows['objects'].find { |row| row['id'] == 'Issue:2' }['source_id'] = 1
        end
        check.call('id', 'object Issue:2 has an id that is not its source type and id') do |rows|
          rows['objects'].find { |row| row['id'] == 'Issue:2' }['source_id'] = 3
        end
        check.call('unsupported', 'object unsupported:1 is unsupported without the reason unsupported_type') do |rows|
          rows['objects'] << { 'id' => 'unsupported:1', 'source_type' => 'Issue', 'source_id' => nil, 'source_order' => nil, 'target' => nil,
                               'untargeted_reason' => 'not_in_source' }
        end
        # Without the history only the package itself is checked.
        rows, path = forge.call('alone')
        swap.call(rows, 'Issue:1', 'Issue:2')
        TP.write(path, content: content, rows: rows)
        assert TP::Verifier.new(path).verify.ok?
      end
    end
  end

  def test_verifier_rejects_forged_roles
    convert(tag_tables([tag(1, 'one', 1)], [tagging(1, 1, 'Issue', 1)])) do |package|
      Dir.mktmpdir('cstags-roles') do |tmp|
        content = package.content.reject { |key, _value| %w[profile files counts].include?(key) }
        { 'unknown' => %w[view_issue_tags delete_everything], 'unsorted' => %w[view_issue_tags add_wiki_tags], 'text' => 'view_issue_tags' }
          .each do |label, permissions|
            rows = package.rows.transform_values { |list| list.map(&:dup) }
            rows['roles'].first['tag_permissions'] = permissions
            forged = File.join(tmp, "#{label}.cstags")
            TP.write(forged, content: content, rows: rows)
            errors = TP::Verifier.new(forged).verify.errors
            assert(errors.any? { |error| error.include?('tag_permissions that are not a sorted list') }, "#{label}: #{errors.inspect}")
          end
        # The manifest counts the roles: a row removed after writing does not verify.
        rows = package.rows.transform_values { |list| list.map(&:dup) }
        forged = File.join(tmp, 'counted.cstags')
        manifest = TP.write(forged, content: content, rows: rows)
        assert_equal 3, manifest.dig('content', 'counts', 'roles_with_tag_permissions')
        Zip::OutputStream.open(File.join(tmp, 'dropped.cstags')) do |zip|
          Zip::File.open(forged) do |archive|
            archive.each do |entry|
              data = entry.get_input_stream(&:read)
              data = data.lines.drop(1).join if entry.name == 'tables/roles.jsonl'
              zip.put_next_entry(entry.name)
              zip.write(data)
            end
          end
        end
        assert_includes TP::Verifier.new(File.join(tmp, 'dropped.cstags')).verify.errors, 'tables/roles.jsonl has a different SHA-256'
      end
    end
  end

  def test_rows_the_destination_cannot_hold_block_the_import
    invalid = { '$base64' => Base64.strict_encode64("bad \xFF".b) }
    tags = [tag(1, 'ok'), tag(2, nil), tag(3, ''), tag(4, '   '), tag(5, ' edge'), tag(6, "nul\u0000"), tag(7, "#{LONG}y"),
            tag(8, invalid), tag(9, 'same'), tag(10, 'same'), tag(11, 'group::one'), tag(12, 'group::two')]
    taggings = [
      tagging(1, 1, 'Issue', 1, context: 'skills'), tagging(2, 1, 'Issue', 2, context: nil),
      tagging(3, 1, 'Issue', 3, tagger_type: 'User', tagger_id: 1), tagging(4, 1, 'Issue', 4, tagger_type: ''),
      # The same tag on the same object twice: possible because of null keys.
      tagging(5, 1, 'Issue', 6, context: nil), tagging(6, 1, 'Issue', 6, context: nil),
      tagging(7, 1, 'Project', 1), tagging(8, 1, nil, nil), tagging(9, 1, 'issue', 1),
      tagging(10, 1, 'Issue', 5), tagging(11, 1, 'Issue', 999), tagging(12, 999, 'Issue', 1), tagging(13, nil, 'WikiPage', 3),
      tagging(14, 11, 'Issue', 7), tagging(15, 12, 'Issue', 7)
    ] + (2..10).map { |id| tagging(100 + id, id, 'WikiPage', 1) }
    convert(tag_tables(tags, taggings)) do |package, summary, report|
      refute package.importable?
      assert_equal false, summary['tags_importable']
      assert summary['blocking']
      assert_equal %w[absorbed_issue duplicate_name duplicate_projection invalid_encoding invalid_name non_null_tagger orphan_object
                      orphan_tag unsupported_context unsupported_type], blocking(package)
      found = codes(package)
      assert_equal 6, found['invalid_name']
      assert_equal 2, found['non_null_tagger']
      assert_equal 4, found['unsupported_context']
      assert_equal 3, found['unsupported_type']
      assert_equal 1, found['scoped_tag_conflict']
      # Every source row is kept as evidence, the invalid name as $base64.
      assert_equal 12, package.rows.fetch('tags').length
      assert_equal taggings.length, package.rows.fetch('taggings').length
      assert_equal invalid, package.rows.fetch('tags')[7]['name']
      assert_nil package.rows.fetch('tags')[1]['name']
      unsupported = package.rows.fetch('objects').reject { |row| %w[Issue WikiPage].include?(row['source_type']) }
      assert_equal [[nil, nil], ['Project', 1], ['issue', 1]], unsupported.map { |row| row.values_at('source_type', 'source_id') }
      assert_equal 'not_in_source', package.rows.fetch('objects').find { |row| row['id'] == 'Issue:999' }['untargeted_reason']
      assert_operator report['counts']['tags_blocking'], :>=, 10
    end
  end

  def test_columns_the_profile_does_not_know
    tag_columns = ConverterFixture::TAG_COLUMNS + [{ 'name' => 'color', 'type' => 'string', 'sql_type' => 'varchar(7)', 'null' => true }]
    tagging_columns = ConverterFixture::TAGGING_COLUMNS.reject { |column| column['name'] == 'context' }
    tags = [tag(1, 'one').merge('color' => '#fff')]
    taggings = [tagging(1, 1, 'Issue', 1).tap { |row| row.delete('context') }]
    convert(tag_tables(tags, taggings, tag_columns: tag_columns, tagging_columns: tagging_columns)) do |package|
      refute package.importable?
      assert_equal %w[missing_column unknown_column unsupported_context], blocking(package)
      assert_equal({ 'color' => '#fff' }, package.rows.fetch('tags').first['source_extra'])
      descriptors = package.content.dig('source', 'table_descriptors')
      assert_equal %w[additional_taggings additional_tags], descriptors.map { |entry| entry['name'] }
      refute_includes descriptors.first['columns'].map { |column| column['name'] }, 'context'
    end
  end

  def test_missing_and_empty_tables
    convert(tag_tables(nil, nil)) do |package, summary|
      refute package.importable?
      assert summary['blocking']
      assert_equal({ 'missing_table' => 2 }, codes(package))
      assert_equal({ 'additional_taggings' => false, 'additional_tags' => false }, package.content.dig('source', 'tables_present'))
      assert_equal 10, package.rows.fetch('objects').length
    end
    convert(tag_tables([tag(1, 'one', 0)], nil)) do |package|
      assert_equal %w[missing_table], blocking(package)
    end
    convert(tag_tables([], [])) do |package, summary|
      assert package.importable?
      refute summary['blocking']
      assert_empty package.rows.fetch('anomalies')
      assert_equal 0, package.content.dig('counts', 'source_tags')
    end
  end

  def test_settings_absent_redacted_and_unsafe
    taggings = [tagging(1, 1, 'Issue', 1), tagging(2, 1, 'WikiPage', 1)]
    convert(tag_tables([tag(1, 'one', 2)], taggings, settings: nil)) do |package|
      # Never saved: the old plugin defaults, which switch tags off.
      assert package.importable?
      settings = package.content.dig('source', 'settings')
      assert_equal({ 'value' => '0', 'provenance' => 'default', 'source_key' => 'active_issue_tags', 'source_value' => 0 },
                   settings['active_issue_tags'])
      assert_equal({ 'value' => '1', 'provenance' => 'mapped', 'source_key' => 'use_colors', 'source_value' => 1 },
                   settings['tags_color_theme'])
      assert_equal 'plugin_defaults', package.content.dig('source', 'settings_provenance')
      assert_equal({ 'tags_not_visible' => 2 }, codes(package))
    end
    redactions = [{ 'table' => 'settings', 'id' => 9, 'column' => 'value', 'reason' => 'setting holds credentials' }]
    tables = tag_tables([tag(1, 'one', 1)], [tagging(1, 1, 'Issue', 1)])
    tables['settings'][:rows].first['value'] = nil
    convert(tables, redactions: redactions) do |package|
      refute package.importable?
      assert_equal %w[missing_settings], blocking(package)
      assert_equal 'incomplete', package.content.dig('source', 'settings_provenance')
      assert_nil package.content.dig('source', 'settings', 'active_issue_tags', 'value')
    end
    tables = tag_tables([tag(1, 'one', 1)], [tagging(1, 1, 'Issue', 1)])
    tables.delete('settings')
    convert(tables) do |package|
      assert_equal %w[missing_settings], blocking(package)
    end
    unsafe = "--- !ruby/object:OpenStruct\ntable:\n  active_issue_tags: '1'\n"
    convert(tag_tables([tag(1, 'one', 1)], [tagging(1, 1, 'Issue', 1)], settings: unsafe)) do |package|
      assert_equal %w[missing_settings], blocking(package)
    end
    partial = "---\nactive_issue_tags: 1\nactive_wiki_tags: true\ntags_sidebar: sideways\n"
    convert(tag_tables([tag(1, 'one', 1)], [tagging(1, 1, 'Issue', 1)], settings: partial)) do |package|
      assert package.importable?
      settings = package.content.dig('source', 'settings')
      assert_equal %w[1 1], [settings.dig('active_issue_tags', 'value'), settings.dig('active_wiki_tags', 'value')]
      assert_nil settings.dig('tags_sidebar', 'value')
      assert_equal 'sideways', settings.dig('tags_sidebar', 'source_value')
      assert_equal 7, codes(package)['invalid_setting']
    end
  end

  def test_verifier_rejects_tampering_and_forged_importability
    convert(tag_tables([tag(1, 'one', 1)], [tagging(1, 1, 'Issue', 1)])) do |package, _summary, _report, path, history, csys|
      Dir.mktmpdir('cstags-tamper') do |tmp|
        assert_empty TP::Verifier.new(path).verify.errors
        # Another history package.
        other = File.join(tmp, 'other.cshistory')
        File.binwrite(other, File.binread(history) + 'x')
        refute TP::Verifier.new(path).verify(history: other).ok?
        refute TP::Verifier.new(path).verify(csys: csys.first(0)).ok?

        # A row changed after writing.
        rows = package.rows.transform_values { |list| list.map(&:dup) }
        content = package.content.reject { |key, _value| %w[profile files counts].include?(key) }
        forged = File.join(tmp, 'forged.cstags')
        rows['taggings'].first['context'] = 'skills'
        TP.write(forged, content: content, rows: rows)
        errors = TP::Verifier.new(forged).verify.errors
        assert(errors.any? { |error| error.include?('breaks the strict profile: a tagging has another context') }, errors.inspect)
        assert_raises(TP::Error) { TP.read(forged) }

        # A byte changed inside an entry.
        tampered = File.join(tmp, 'tampered.cstags')
        Zip::OutputStream.open(tampered) do |zip|
          Zip::File.open(path) do |archive|
            archive.each do |entry|
              data = entry.get_input_stream(&:read)
              data = data.sub('"one"', '"onE"') if entry.name == 'tables/tags.jsonl'
              zip.put_next_entry(entry.name)
              zip.write(data)
            end
          end
        end
        assert_includes TP::Verifier.new(tampered).verify.errors, 'tables/tags.jsonl has a different SHA-256'
      end
    end
  end

  def test_ambiguous_destination_identities
    tables = tag_tables([tag(1, 'one', 1)], [tagging(1, 1, 'WikiPage', 4)])
    tables['wiki_pages'] += [{ 'id' => 4, 'wiki_id' => 1, 'title' => 'wiki', 'created_on' => TIME, 'protected' => false, 'parent_id' => nil },
                             { 'id' => 5, 'wiki_id' => 2, 'title' => 'Other', 'created_on' => TIME, 'protected' => false, 'parent_id' => nil },
                             { 'id' => 6, 'wiki_id' => 2, 'title' => 'OTHER', 'created_on' => TIME, 'protected' => false, 'parent_id' => nil }]
    convert(tables) do |package|
      assert_equal %w[ambiguous_object], blocking(package)
      assert_equal 1, codes(package)['ambiguous_untagged_object']
      ambiguous = package.rows.fetch('anomalies').find { |row| row['code'] == 'ambiguous_object' }
      assert_equal %w[WikiPage:1 WikiPage:4], ambiguous['source_ids']
    end
  end

  def test_verifier_rejects_unexpected_archives
    convert(tag_tables([], [])) do |_package, _summary, _report, path|
      Dir.mktmpdir('cstags-archive') do |tmp|
        entries = {}
        Zip::File.open(path) { |archive| archive.each { |entry| entries[entry.name] = entry.get_input_stream(&:read) } }
        rezip = lambda do |name, pairs|
          target = File.join(tmp, name)
          Zip::OutputStream.open(target) do |zip|
            pairs.each do |entry_name, data|
              zip.put_next_entry(entry_name)
              zip.write(data)
            end
          end
          TP::Verifier.new(target).verify.errors
        end
        assert_includes rezip.call('extra.cstags', entries.to_a + [['notes.txt', 'x']]), 'unexpected entry "notes.txt"'
        assert_includes rezip.call('missing.cstags', entries.reject { |name, _data| name == 'tables/objects.jsonl' }.to_a),
                        'missing entries tables/objects.jsonl'
        manifest = JSON.parse(entries.fetch('manifest.json')).merge('schema_version' => '2')
        errors = rezip.call('version.cstags', entries.merge('manifest.json' => SnapshotsGen::LegacySnapshot::CanonicalJson.generate(manifest)).to_a)
        assert_includes errors, 'unsupported schema "cosmosys-tags" "2"'
        # rubyzip keeps one central record for a repeated name, but both local entries stay in the file.
        errors = rezip.call('repeated.cstags', entries.to_a + [['tables/tags.jsonl', entries.fetch('tables/tags.jsonl')]])
        assert_includes errors, 'the archive holds data outside its listed entries (repeated names?)'
      end
    end
  end
end
