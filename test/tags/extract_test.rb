# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative 'compare'

# Small adapter double, limited to read-only snapshot semantics and raw bytes.
# Actual Redmine adapters are exercised in the rehearsal, not replaced by this.
module Redmine
  module Plugin
    class << self
      attr_accessor :defaults
      def find(id)
        Struct.new(:settings, :version).new({ default: defaults || {} }, id == :additional_tags ? '1.0.4' : '3.0.5.2')
      end
    end
  end
end

# Entry-point contract only: the real Rails/adapter run stays in the rehearsal.
module ActiveRecord
  class Base
    class << self
      attr_accessor :connection, :uncached_calls
      def uncached
        self.uncached_calls = (uncached_calls || 0) + 1
        yield
      end
    end
  end
end

class TagsExtractionTest < Minitest::Test
  Column = Struct.new(:name, :sql_type, :null, :limit, :precision)
  class Database
    attr_reader :commands
    attr_accessor :broken, :stored_settings
    def initialize(adapter)
      @adapter, @commands = adapter, []
    end

    def adapter_name; @adapter; end
    def open_transactions; 0; end
    def execute(sql); @commands << sql; end
    def table_exists?(_name); true; end
    def quote_table_name(name); name; end
    def columns(name)
      names = name == 'additional_tags' ? %w[id name taggings_count created_at updated_at] : %w[id tag_id taggable_id taggable_type context tagger_id tagger_type created_at]
      names.map { |field| Column.new(field, 'fixture', true, field == 'name' ? 191 : nil, nil) }
    end

    def select_all(sql)
      @commands << sql
      raise 'invented read failure' if broken && sql.include?('FROM wiki_pages')
      case sql
      when /FROM settings/ then stored_settings ? [{ 'value' => stored_settings }] : []
      when /FROM issues/ then [{ 'id' => 1, 'project' => 'demo', 'csid' => 'D-0001' }]
      when /FROM wiki_pages/ then []
      when /FROM additional_tags t/
        [ { 'id' => 1, 'name' => "A,🚀", 'taggings_count' => 1, 'actual_taggings_count' => 1,
            'created_at' => Time.utc(2023, 1, 1), 'updated_at' => Time.utc(2023, 1, 1) },
          { 'id' => 2, 'name' => "\xff".b, 'taggings_count' => 0, 'actual_taggings_count' => 0,
            'created_at' => Time.utc(2023, 1, 1), 'updated_at' => Time.utc(2023, 1, 1) } ]
      when /FROM additional_taggings/
        [{ 'id' => 1, 'tag_id' => 1, 'taggable_type' => 'Issue', 'taggable_id' => 1,
           'context' => 'tags', 'tagger_id' => nil, 'tagger_type' => nil, 'created_at' => nil }]
      else raise 'unexpected query in adapter double'
      end
    end
  end

  def setup
    @directory = Dir.mktmpdir('tags-extraction-')
    @path = File.join(@directory, 'evidence.jsonl')
    @db = Database.new('Mysql2')
    Redmine::Plugin.defaults = { 'active_issue_tags' => 0, 'active_wiki_tags' => 0 }
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def capture
    capture_io { TagsEvidence::Extractor.new(@db, 'source').capture(@path) }
  end

  def test_consistent_read_only_mysql_snapshot_and_exact_byte_evidence
    @db.stored_settings = "---\nactive_issue_tags: '1'\n"
    capture
    assert_equal ['SET NAMES utf8mb4', 'SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ',
                  'START TRANSACTION WITH CONSISTENT SNAPSHOT, READ ONLY'], @db.commands.first(3)
    assert_equal 'ROLLBACK', @db.commands.last
    evidence = TagsEvidence::Document.new(@path)
    assert_equal 'A,🚀', evidence.tags.first['name']
    assert_equal({ '$base64' => '/w==' }, evidence.tags.last['name'])
    assert_equal 2, evidence.tags.length
    assert_nil evidence.assignments.first['created_at']
    assert_equal 0o600, File.stat(@path).mode & 0o777
    assert_equal '1', evidence.meta.dig('settings', 'effective', 'active_issue_tags')
    assert_equal 0, evidence.meta.dig('settings', 'effective', 'active_wiki_tags')
    assert_equal 'default', evidence.meta.dig('settings', 'provenance', 'active_wiki_tags')
  end

  def test_failure_rolls_back_and_never_publishes_partial_output
    @db.broken = true
    assert_raises(RuntimeError) { capture }
    assert_equal 'ROLLBACK', @db.commands.last
    refute File.exist?(@path)
    assert_empty Dir.children(@directory)
  end

  def test_existing_evidence_is_never_overwritten
    File.write(@path, 'keep')
    assert_raises(RuntimeError) { capture }
    assert_equal 'keep', File.read(@path)
    assert_empty @db.commands
  end

  def test_postgresql_is_also_repeatable_read_and_read_only
    @db = Database.new('PostgreSQL')
    capture
    assert_equal 'BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY', @db.commands.first
    assert_equal 'ROLLBACK', @db.commands.last
  end

  def test_serialized_objects_are_rejected_in_settings
    @db.stored_settings = "--- !ruby/object:Object {}\n"
    assert_raises(Psych::DisallowedClass) { capture }
    assert_equal 'ROLLBACK', @db.commands.last
    refute File.exist?(@path)
  end

  def run_entry_point(side)
    previous = ARGV.dup
    ActiveRecord::Base.connection = @db
    ActiveRecord::Base.uncached_calls = 0
    ARGV.replace([@path])
    capture_io { load File.join(__dir__, "extract_#{side}.rb") }
    assert_equal 1, ActiveRecord::Base.uncached_calls
    evidence = TagsEvidence::Document.new(@path)
    assert_equal side, evidence.meta['side']
    assert_equal 'ROLLBACK', @db.commands.last
    evidence
  ensure
    ARGV.replace(previous)
    ActiveRecord::Base.connection = nil
  end

  def test_source_rails_runner_entry_point_uses_legacy_csid_join
    evidence = run_entry_point('source')
    assert_equal 'D-0001', evidence.objects.first['csid']
    assert @db.commands.any? { |sql| sql.include?('LEFT JOIN cosmosys_issues') }
  end

  def test_target_rails_runner_entry_point_reads_native_csid
    @db = Database.new('PostgreSQL')
    evidence = run_entry_point('target')
    assert_equal 'D-0001', evidence.objects.first['csid']
    assert @db.commands.any? { |sql| sql.include?('i.csid') }
    refute @db.commands.any? { |sql| sql.include?('cosmosys_issues') }
  end
end
