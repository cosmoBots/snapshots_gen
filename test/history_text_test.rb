# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'open3'
require_relative 'compare_history'

# A small read-only Rails double executes the extractor itself in a separate
# Ruby process. It does not stand in for the required real Redmine rehearsal.
class HistoryTextTest < Minitest::Test
  RAILS_DOUBLE = <<'CODE'
require 'ostruct'
require 'erb'
require 'time'
SIDE = ARGV.shift
SCRIPT = ARGV.shift
LEGACY = SIDE == 'legacy'
ITEM_ID = LEGACY ? 1 : 101
TEMPLATES = {
  'changed' => '%{label} cambiado de %{old} a %{new}',
  'changed_no_detail' => 'Se actualizó %{label}',
  'set_to' => '%{label} establecido a %{value}',
  'deleted' => '%{label} eliminado (%{old})',
  'added' => 'Añadido %{label} %{value}'
}
module I18n
  def self.with_locale(language)
    yield
  end
  def self.t(key, **options)
    return TEMPLATES.fetch(key.sub('text_journal_', '')) if key.start_with?('text_journal_')
    { 'field_rq_type' => 'Tipo de requisito', 'field_rq_rationale' => 'Justificacion',
      'field_parent_issue' => (LEGACY ? 'Tarea padre' : 'Item padre') }.fetch(key, options[:default] || key)
  end
end
module Redmine
  module I18n; end
end
module ActionView
  module Helpers
    module TagHelper; end
  end
end
module ApplicationHelper; end
module CustomFieldsHelper; end
class Query
  def initialize(rows); @rows = rows; end
  def order(*); self; end
  def first; @rows.first; end
  def pluck(*names); @rows.map { |row| names.length == 1 ? row.public_send(names[0]) : names.map { |name| row.public_send(name) } }; end
  def sum(*); 0; end
  def each(&block); @rows.each(&block); end
end
class User
  class << self; attr_accessor :current; end
  def self.record; OpenStruct.new(id: 5, name: 'Example', login: 'example'); end
  def self.where(*); Query.new([record]); end
  def self.find_by(*); record; end
end
class Project
  def self.find_by(*); OpenStruct.new(id: 3, identifier: 'demo'); end
end
class CustomField
  def self.where(*); Query.new([find_by(id: 7)]); end
  def self.find_by(id:)
    return OpenStruct.new(id: 7, name: 'rqType', field_format: 'list') if id.to_s == '7'
    return OpenStruct.new(id: 8, name: 'rqRationale', field_format: 'text') if id.to_s == '8'
    nil
  end
end
class CustomValue
  def self.where(*); Query.new([OpenStruct.new(customized_id: ITEM_ID, value: 'Complex')]); end
end
class TimeEntry
  def self.where(*); Query.new([]); end
end
class IssueStatus; end
class Tracker; end
class IssuePriority; end
class IssueCategory; end
class Version; end
class Attachment; end
Detail = Struct.new(:id, :property, :prop_key, :old_value, :value)
class Issue
  def self.record
    tracker = OpenStruct.new(name: LEGACY ? 'rq' : 'csRq', default_status: OpenStruct.new(name: 'Draft'))
    stamp = Time.iso8601('2020-01-01T01:02:03.123456Z')
    details = if LEGACY
                [Detail.new(1, 'cf', '7', 'Complex', 'Hw'), Detail.new(2, 'cf', '8', 'old full text', 'new full text')]
              else
                [Detail.new(101, 'attr', 'rq_type', 'complex', 'hardware'), Detail.new(102, 'attr', 'rq_rationale', 'old full text', 'new full text')]
              end
    details << Detail.new(LEGACY ? 3 : 103, 'attr', 'parent_id', nil, ITEM_ID.to_s)
    journal = OpenStruct.new(id: LEGACY ? 1 : 101, created_on: stamp, updated_on: stamp, user: User.record,
                             private_notes: false, notes: "See ##{ITEM_ID}", details: details)
    OpenStruct.new(id: ITEM_ID, csid: 'DEMO-0001', author: User.record, project: Project.find_by(id: 3), tracker: tracker,
                   parent_id: nil, subject: 'Example', created_on: stamp, updated_on: stamp, closed_on: nil,
                   watcher_users: [], journals: [journal])
  end
  def self.includes(*); Query.new([record]); end
  def self.pluck(*); [[ITEM_ID, 'DEMO-0001']]; end
  def self.find_by(id:); id.to_i == ITEM_ID ? record : nil; end
end
module ActiveRecord
  class Base
    def self.connection
      connection = Object.new
      def connection.table_exists?(*); LEGACY; end
      def connection.select_rows(*); [[ITEM_ID, 'DEMO-0001']]; end
      connection
    end
  end
end
module IssuesHelper
  def details_to_strings(details, no_html)
    details.map do |d|
      field = d.property == 'cf' ? CustomField.find_by(id: d.prop_key) : nil
      key = d.prop_key == 'parent_id' ? 'field_parent_issue' : "field_#{d.prop_key}"
      label = field ? field.name : ::I18n.t(key, default: d.prop_key)
      values = [d.old_value, d.value].map do |value|
        if d.prop_key == 'rq_type'
          { 'complex' => 'Complejo', 'hardware' => 'Hardware' }[value]
        elsif d.prop_key == 'parent_id'
          value && "##{value}"
        else
          value
        end
      end
      old, value = values
      kind = if field && field.field_format == 'text'
               'changed_no_detail'
             elsif old.nil? || old == ''
               field ? 'added' : 'set_to'
             elsif value.nil? || value == ''
               'deleted'
             else
               'changed'
             end
      tokens = { 'label' => label, 'old' => old.to_s, 'new' => value.to_s, 'value' => value.to_s }
      TEMPLATES[kind].gsub(/%\{(\w+)\}/) { tokens.fetch(Regexp.last_match(1)) }
    end
  end
end
load SCRIPT
CODE

  def test_extractor_outputs_exact_references_values_translations_timestamps_and_private_files
    Dir.mktmpdir('history-text-test') do |directory|
      rows = %w[legacy target].map do |side|
        path = File.join(directory, "#{side}.jsonl")
        # An existing world-readable file must also be restricted.
        File.write(path, 'old')
        File.chmod(0o644, path)
        out, err, status = Open3.capture3(RbConfig.ruby, '-e', RAILS_DOUBLE, side,
                                        File.expand_path('history_text.rb', __dir__), path, 'es')
        assert status.success?, out + err
        assert_equal 0o600, File.stat(path).mode & 0o777
        JSON.parse(File.read(path))
      end
      source, target = rows
      assert_equal '2020-01-01T01:02:03.123456Z', source['created']
      assert_equal 'old full text', source['journals'][0]['raw_details'][1]['old_value']
      assert_equal 'Complejo', target['journals'][0]['raw_details'][0]['display_old']
      assert_equal 'Hardware', target['journals'][0]['raw_details'][0]['display_value']
      assert_equal({ 'id' => 101, 'tracker' => 'csRq', 'kind' => 'items' }, target['journals'][0]['raw_details'][2]['value_ref'])
      result = HistoryComparison::Comparison.new([source], [target]).run
      assert result.ok?, result.failures.inspect + result.unexplained.inspect
    end
  end
end
