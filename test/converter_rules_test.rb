# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../converter/lib/snapshots_gen/converter/rules'

class ConverterRulesTest < Minitest::Test
  Rules = SnapshotsGen::Converter::Rules

  # The literal the old plugin stores, as Ruby 2.7 prints it.
  def test_relations_on_close_literal
    text = '[{:parent=>"1", :csID=>"SYR-0001"}, {:csID=>"SYR-0002", :ir=>{"id"=>4, "issue_from_id"=>2, ' \
           '"issue_to_id"=>8, "relation_type"=>"relates", "delay"=>nil}}]'
    parsed = Rules.parse_ruby_literal(text)
    assert_equal({ 'parent' => '1', 'csID' => 'SYR-0001' }, parsed[0])
    assert_equal 'relates', parsed[1].dig('ir', 'relation_type')
    assert_nil parsed[1].dig('ir', 'delay')
  end

  def test_literal_in_ruby_3_4_style_and_escapes
    parsed = Rules.parse_ruby_literal('[{parent: "a \"b\"\nc", n: -1.5, ok: true}]')
    assert_equal({ 'parent' => "a \"b\"\nc", 'n' => -1.5, 'ok' => true }, parsed.first)
  end

  def test_literal_never_evaluates_code
    assert_raises(ArgumentError) { Rules.parse_ruby_literal('[system("id")]') }
    assert_raises(ArgumentError) { Rules.parse_ruby_literal('[1] + [2]') }
  end

  def test_document_metadata_from_title
    metadata = Rules.document_metadata('Interface control document ABC-ICD-0042 v2, 03/2022')
    assert_equal 'Interface control document', metadata['title']
    assert_equal 'ABC-ICD-0042', metadata['external_code']
    assert_equal '2', metadata['version']
    assert_equal '2022-03-01', metadata['date']
    assert_equal({ 'title' => 'Plain title', 'external_code' => nil, 'version' => nil, 'date' => nil },
                 Rules.document_metadata('Plain title'))
  end

  def test_document_items_and_reference_lines
    assert_equal({ 'family' => 'R', 'position' => 12 }, Rules.document_reference('RD-12'))
    assert_nil Rules.document_reference('Requirements')
    lines = Rules.document_reference_lines("AD 1 | applies | section 3\nfree text\nAD2|x")
    assert_equal [1, 2], lines.map { |line| line['position'] }
    assert_equal "free text\n", Rules.unparsed_reference_text("AD 1 | applies\nfree text\n")
  end

  def test_ambiguous_markdown_tables
    assert_equal [1], Rules.ambiguous_markdown_tables("    | A | B |\n|---|---|\n| 1 | 2 |")
    assert_empty Rules.ambiguous_markdown_tables("| A | B |\n|---|---|\n| 1 | 2 |")
  end

  def test_old_yaml_values
    assert_equal %w[Low Medium], Rules.yaml_list("---\n- Low\n- Medium\n")
    assert_equal({ 'url_pattern' => '', 'text_formatting' => 'full' },
                 Rules.yaml_hash("--- !ruby/hash:ActiveSupport::HashWithIndifferentAccess\nurl_pattern: ''\ntext_formatting: full\n"))
  end

  def test_codes_and_text
    assert_equal 'SYRDOC', Rules.normalize_code('SYR-DOC')
    assert_equal 'ab', Rules.clean("a\u0000b")
    assert_equal 'ab', Rules.clean("a\xFFb".b)
  end
end
