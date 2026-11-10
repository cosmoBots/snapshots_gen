# frozen_string_literal: true

require 'minitest/autorun'
SNAPSHOTS_GEN_LIBRARY_ONLY = true
require_relative '../exporter/export'
require_relative '../converter/lib/snapshots_gen/tags_package'

# The tag counts of the inventory (step 1 of the procedure): counts only, and
# the same scope rule as the converter. All names are invented.
class ExporterInventoryTest < Minitest::Test
  Inventory = SnapshotsGen::Exporter::Inventory

  def tagging(tag_id, type, id, context: 'tags', tagger_id: nil)
    { 'tag_id' => tag_id, 'taggable_type' => type, 'taggable_id' => id, 'tagger_id' => tagger_id, 'tagger_type' => nil, 'context' => context }
  end

  def test_counts_every_case_of_the_checklist
    # The no-break spaces are kept by String#strip, as by the 4.6.0 model: not edge spaces.
    names = ['A,B', 'a', 'A', 'b', 'B', 'grupo::uno', 'grupo::dos', 'grupo:tres', ' rim', "rim\t", "no\u00a0edge\u00a0", 'lonely', "bad \xFF".b]
    tags = names.each_with_index.map { |name, index| { 'id' => index + 1, 'name' => name } }
    taggings = [
      tagging(1, 'Issue', 1), tagging(2, 'Issue', 1), tagging(3, 'Issue', 2), tagging(4, 'WikiPage', 1), tagging(5, 'Issue', 3),
      tagging(6, 'Issue', 4), tagging(7, 'Issue', 4), tagging(6, 'Issue', 5), tagging(7, 'Issue', 6),
      tagging(8, 'Issue', 4, context: 'skills'), tagging(9, 'Issue', 7, tagger_id: 3), tagging(10, 'Issue', 7), tagging(12, 'Issue', 8)
    ]
    profile = Inventory.tag_profile(tags, taggings, 7)
    assert_equal({ 'tags' => 13, 'taggings' => 13, 'taggings_by_type' => { 'Issue' => 12, 'WikiPage' => 1 }, 'contexts' => 2,
                   'taggings_with_tagger' => 1, 'unused_tags' => 2, 'names_with_comma' => 1, 'case_variant_groups' => 2,
                   'scope_conflicts' => 1, 'names_with_edge_spaces' => 2, 'tag_list_changes' => 7 }, profile)
    line = Inventory.tags_summary('additional_tags_profile' => profile)
    assert_equal 'Tags: 13 tags (2 unused), 13 taggings (Issue=12, WikiPage=1), 2 distinct contexts, 1 with tagger; names with a comma: 1, ' \
                 'groups equal except for case: 2, scope conflicts on one object: 1, names with edge spaces: 2; tag changes in the history: 7',
                 line
    names.each { |name| refute_includes line, name if name.length > 2 && name.encoding == Encoding::UTF_8 }
  end

  def test_all_zero_and_missing_tables
    profile = Inventory.tag_profile([{ 'id' => 1, 'name' => 'one' }], [tagging(1, 'Issue', 1)], 0, context_column: false)
    assert_nil profile['contexts']
    assert_equal 0, profile.values_at('unused_tags', 'names_with_comma', 'case_variant_groups', 'scope_conflicts', 'names_with_edge_spaces').sum
    assert_includes Inventory.tags_summary('additional_tags_profile' => profile), 'no context column'
    assert_equal 'Tags: no additional_tags and additional_taggings tables', Inventory.tags_summary({})
  end

  def test_scope_group_is_the_one_of_the_converter
    ['grupo::uno', 'a::b::c', ' x :: y ', 'g:one', 'a:b:c', 'plain', 'a::', '::b'].each do |name|
      expected = SnapshotsGen::TagsPackage.scope_group(name)
      expected.nil? ? assert_nil(Inventory.scope_group(name), name) : assert_equal(expected, Inventory.scope_group(name), name)
    end
  end
end
