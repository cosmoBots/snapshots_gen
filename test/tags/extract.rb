# frozen_string_literal: true

# Independent SQL evidence for G3. Does not load migration code or tag models.
require 'json'
require 'base64'
require 'digest'
require 'time'
require 'yaml'
require 'tempfile'

module TagsEvidence
  SCHEMA = 'snapshots-gen-tags-evidence-v1'
  TABLES = %w[additional_tags additional_taggings].freeze
  SETTINGS = %w[active_issue_tags active_wiki_tags open_issues_only show_with_count
                tags_sidebar tags_sort_by tags_sort_order tags_suggestion_order
                use_colors tags_color_theme show_tags_after_queries].freeze

  module_function

  # UTF-8 is deliberately not normalized, stripped or case folded.
  def safe(value)
    case value
    when String
      utf8 = value.dup.force_encoding(Encoding::UTF_8)
      utf8.valid_encoding? ? utf8 : { '$base64' => Base64.strict_encode64(value.b) }
    when Time, DateTime then value.to_time.utc.iso8601(6)
    when Hash then value.keys.sort.each_with_object({}) { |key, hash| hash[key] = safe(value[key]) }
    when Array then value.map { |item| safe(item) }
    else value
    end
  end

  def json(value)
    JSON.generate(safe(value))
  end

  class Extractor
    # Redmine's settings page stores plugin settings as a
    # HashWithIndifferentAccess, so the YAML root carries that Ruby tag. The
    # tree is checked before anything is built: only that tag on the root, and
    # no other tag, anchor or alias anywhere. Then it is loaded as plain data.
    INDIFFERENT_HASH_TAG = '!ruby/hash:ActiveSupport::HashWithIndifferentAccess'

    def self.plain_settings(text)
      stream = Psych.parse_stream(text)
      raise 'plugin settings must be exactly one YAML document' unless stream.children.length == 1

      root = stream.children.first.root
      raise 'plugin settings are not a YAML mapping' unless root.is_a?(Psych::Nodes::Mapping)
      raise "plugin settings carry an unexpected YAML tag: #{root.tag}" unless root.tag.nil? || root.tag == INDIFFERENT_HASH_TAG
      raise 'plugin settings use a YAML anchor' if root.anchor

      root.children.each { |node| check_plain_node(node) }
      root.tag = nil
      root.implicit = true
      YAML.safe_load(stream.to_yaml, permitted_classes: [], aliases: false)
    end

    def self.check_plain_node(node)
      raise 'plugin settings use a YAML alias' if node.is_a?(Psych::Nodes::Alias)
      raise "plugin settings carry an unexpected YAML tag: #{node.tag}" if node.respond_to?(:tag) && node.tag
      raise 'plugin settings use a YAML anchor' if node.respond_to?(:anchor) && node.anchor
      raise 'plugin settings hold an unexpected YAML node' unless node.is_a?(Psych::Nodes::Scalar) ||
                                                                  node.is_a?(Psych::Nodes::Sequence) ||
                                                                  node.is_a?(Psych::Nodes::Mapping)

      node.children.each { |child| check_plain_node(child) } unless node.is_a?(Psych::Nodes::Scalar)
    end

    def initialize(connection, side)
      @db, @side = connection, side
      raise ArgumentError, 'side must be source or target' unless %w[source target].include?(side)
    end

    def rows(sql)
      @db.select_all(sql).to_a
    end

    def table(name)
      @db.quote_table_name(name)
    end

    def all(name)
      rows("SELECT * FROM #{table(name)} ORDER BY id")
    end

    def read_only
      raise 'cannot nest the evidence transaction' if @db.open_transactions.positive?

      adapter = @db.adapter_name.downcase
      started = false
      if adapter.include?('mysql')
        # A utf8 session would silently replace a four-byte emoji with '?'.
        @db.execute('SET NAMES utf8mb4')
        @db.execute('SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ')
        @db.execute('START TRANSACTION WITH CONSISTENT SNAPSHOT, READ ONLY')
      elsif adapter.include?('postg')
        @db.execute('BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY')
      else
        raise 'only MySQL and PostgreSQL read-only snapshots are supported'
      end
      started = true
      yield
    ensure
      @db.execute('ROLLBACK') if started
    end

    def schema
      TABLES.each_with_object({}) do |name, result|
        raise "missing required table: #{name}" unless @db.table_exists?(name)

        result[name] = @db.columns(name).map do |column|
          { 'name' => column.name, 'sql_type' => column.sql_type, 'null' => column.null,
            'limit' => column.limit, 'precision' => column.precision }
        end
      end
    end

    def settings
      plugin = Redmine::Plugin.find(:additional_tags)
      defaults = (plugin.settings || {}).fetch(:default, {})
      stored_rows = rows("SELECT value FROM settings WHERE name = 'plugin_additional_tags'")
      raise 'ambiguous plugin settings' if stored_rows.length > 1

      stored = stored_rows.empty? ? {} : self.class.plain_settings(stored_rows.first.fetch('value'))
      raise 'plugin settings are not a plain hash' unless stored.is_a?(Hash) && defaults.is_a?(Hash)

      effective = {}
      provenance = {}
      SETTINGS.each do |key|
        next unless stored.key?(key) || defaults.key?(key) || defaults.key?(key.to_sym)

        effective[key] = stored.key?(key) ? stored[key] : (defaults.key?(key) ? defaults[key] : defaults[key.to_sym])
        provenance[key] = stored.key?(key) ? 'stored' : 'default'
      end
      { 'effective' => effective, 'provenance' => provenance }
    end

    def objects
      issues = if @side == 'source'
                 rows('SELECT i.id, p.identifier AS project, c.identifier AS csid FROM issues i ' \
                      'LEFT JOIN projects p ON p.id = i.project_id ' \
                      'LEFT JOIN cosmosys_issues c ON c.issue_id = i.id ORDER BY i.id, c.id')
               else
                 rows('SELECT i.id, p.identifier AS project, i.csid FROM issues i ' \
                      'LEFT JOIN projects p ON p.id = i.project_id ORDER BY i.id')
               end
      wiki = rows('SELECT wp.id, p.identifier AS project, wp.title FROM wiki_pages wp ' \
                  'LEFT JOIN wikis w ON w.id = wp.wiki_id ' \
                  'LEFT JOIN projects p ON p.id = w.project_id ORDER BY wp.id')
      issues.map { |row| row.merge('kind' => 'object', 'type' => 'Issue', 'source_order' => nil) } +
        wiki.map { |row| row.merge('kind' => 'object', 'type' => 'WikiPage', 'source_order' => nil) }
    end

    def capture(path)
      File.umask(0o077)
      raise 'output already exists' if File.exist?(path)

      staged = Tempfile.new(['.tags-evidence-', '.jsonl'], File.dirname(File.expand_path(path)))
      staged.binmode
      counts = Hash.new(0)
      digest = Digest::SHA256.new
      emit = lambda do |row|
        bytes = TagsEvidence.json(row) + "\n"
        staged.write(bytes)
        digest.update(bytes)
        counts[row.fetch('kind')] += 1
      end
      read_only do
        descriptors = schema
        plugins = %i[additional_tags additionals].map do |id|
          plugin = Redmine::Plugin.find(id)
          { 'id' => id.to_s, 'version' => plugin.version.to_s }
        end
        emit.call('kind' => 'meta', 'schema' => SCHEMA, 'side' => @side,
                  'captured_at' => Time.now.utc.iso8601(6), 'tables' => descriptors,
                  'plugins' => plugins, 'settings' => settings, 'order' => 'not-certified')
        objects.each { |row| emit.call(row) }
        rows('SELECT t.*, (SELECT COUNT(*) FROM additional_taggings g WHERE g.tag_id = t.id) ' \
             'AS actual_taggings_count FROM additional_tags t ORDER BY t.id').each do |row|
          emit.call(row.merge('kind' => 'tag'))
        end
        all('additional_taggings').each { |row| emit.call(row.merge('kind' => 'assignment')) }
      end
      staged.write(TagsEvidence.json('kind' => 'end', 'counts' => counts, 'sha256' => digest.hexdigest) + "\n")
      staged.close
      # Link refuses to overwrite an output created while the snapshot ran.
      File.link(staged.path, path)
      puts "tags evidence: objects=#{counts['object']} tags=#{counts['tag']} assignments=#{counts['assignment']}"
    ensure
      staged.close! if staged
    end
  end
end
