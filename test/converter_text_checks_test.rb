# frozen_string_literal: true

# What the report announces for a person to review: Markdown that Redcarpet
# and CommonMark render differently, and formulas of a MathJax plugin. Every
# text is invented.

require 'minitest/autorun'
require_relative 'converter_snapshot_helper'
require_relative '../converter/lib/snapshots_gen/converter/text_checks'

class ConverterTextChecksTest < Minitest::Test
  include ConverterSnapshotHelper
  Checks = SnapshotsGen::Converter::TextChecks

  def test_dialect_differences
    assert_equal ['underline'], Checks.dialect_differences('A _word_ and _**bold**_, not snake_case_name')
    assert_equal ['underscores'], Checks.dialect_differences('Length: ____mm and ____ cm')
    assert_empty Checks.dialect_differences('Length: ____ mm, snake__case')
    assert_equal ['strikethrough'], Checks.dialect_differences('Moved to ~room 2~')
    assert_equal ['superscript'], Checks.dialect_differences('Area x^2')
    assert_equal ['list_indent'], Checks.dialect_differences("1. First\n       - nested\n       - nested\n2. Second")
    assert_equal ['list_marker'], Checks.dialect_differences("* one\n* two\n- three")
    assert_equal ['list_marker'], Checks.dialect_differences("* one, with:\r\n\r\n- a\r\n- b")
    assert_empty Checks.dialect_differences("* one\n\nA paragraph.\n\n- a")
    assert_equal ['list_marker'], Checks.dialect_differences("* one:\n\n1. a\n2. b")
    assert_empty Checks.dialect_differences('[x](https://example.test/a?__x=1&__y=2) ~ https://example.test/~a~b')
    assert_equal ['quoted_destination'], Checks.dialect_differences('![]("image.png")')
    assert_equal ['empty_list_item'], Checks.dialect_differences('-')
    assert_empty Checks.dialect_differences("---\n- a\n* * *")
    assert_empty Checks.dialect_differences("1. First\n   - nested\n\n- a\n- b\n\nx ~~struck~~ y")
    # Code is never looked at.
    assert_empty Checks.dialect_differences("`_x_` and\n```\n~a~ x^2\n```\n")
  end

  def test_latex_formulas
    assert_equal({ 'inline' => 2, 'block' => 1 }, Checks.latex_formulas("$a_1$ and \\(b\\)\n$$\nc = d\n$$"))
    assert_equal({ 'macro' => 1 }, Checks.latex_formulas('{{mj(x^2)}}'))
    assert_empty Checks.latex_formulas('It costs $ 5 or `$x$`')
  end

  def tables
    issues = [issue(1), issue(2)]
    issues[0]['description'] = 'A _word_ with $x_1$'
    issues[0]['subject'] = 'Speed $v_0$'
    issues[1]['description'] = 'Nothing special'
    base_tables(issues).merge(
      'journals' => [{ 'id' => 5, 'journalized_id' => 2, 'journalized_type' => 'Issue', 'user_id' => 1,
                       'notes' => "* a\n- b", 'private_notes' => false, 'created_on' => TIME }]
    )
  end

  def run_conversion(settings, plugins)
    Dir.mktmpdir('text-checks') do |tmp|
      Converter::Source.open(legacy(File.join(tmp, 'legacy'), tables, settings: settings, plugins: plugins)) do |source|
        report = Converter::Report.new
        plan = Converter::Plan.new(source, report).build!
        Converter::HistoryBuilder.new(plan, csys_packages: []).entities
        yield report, plan
      end
    end
  end

  def test_report_lists_each_text_with_its_item
    mathjax = [{ 'id' => 'redmine_latex_mathjax', 'name' => 'Redmine LaTeX MathJax Macro' }]
    run_conversion({ 'text_formatting' => 'markdown' }, mathjax) do |report, plan|
      dialect = report.entries.select { |entry| entry['code'] == 'markdown_dialect' }
      assert_equal [['item:1', ['underline']], ['journal #5', ['list_marker']]],
                   dialect.map { |entry| [entry['subject'], entry.dig('detail', 'kinds')] }.sort
      assert_equal plan.item_for_issue(2).csid, dialect.find { |entry| entry['subject'] == 'journal #5' }.dig('detail', 'csid')
      latex = report.entries.select { |entry| entry['code'] == 'latex_formula' }
      assert_equal [['item:1', 1], ['item:1 subject', 1]], latex.map { |entry| [entry['subject'], entry.dig('detail', 'inline')] }.sort
      assert_equal 'redmine_latex_mathjax', latex.first.dig('detail', 'plugin')
    end
    # CommonMark in the source, no MathJax: nothing to announce.
    run_conversion({ 'text_formatting' => 'common_mark' }, []) do |report, _plan|
      assert_empty report.entries.select { |entry| %w[markdown_dialect latex_formula].include?(entry['code']) }
    end
  end
end
