# frozen_string_literal: true

require 'date'
require 'strscan'
require 'yaml'

module SnapshotsGen
  module Converter
    # Mapping rules from the old cosmoSys model to the current one. Most come
    # from the csys legacy_cosmosys pipeline (normalize.rb and
    # legacy_package_importer.rb); here they work by name, never by id.
    module Rules
      module_function

      REQUIREMENT_TRACKER = 'rq'
      # Old tracker name => current tracker key and name.
      # The old PORIS had three value trackers; the current one has a single
      # value kind (prValue), the only one a parameter accepts as a child. The
      # type-specific old fields stay as custom fields.
      TRACKERS = {
        'csInfo' => { 'key' => 'cs_info', 'name' => 'csInfo', 'item_profile' => 'info' },
        'csRefDoc' => { 'key' => 'cs_ref_doc', 'name' => 'csRefDoc', 'item_profile' => 'doc' },
        'prValFloat' => { 'key' => 'prValue', 'name' => 'prValue', 'item_profile' => nil },
        'prValText' => { 'key' => 'prValue', 'name' => 'prValue', 'item_profile' => nil }
      }.freeze
      INFO_TRACKER = TRACKERS.fetch('csInfo')
      REQUIREMENT = { 'key' => 'requirement', 'name' => 'csRq', 'item_profile' => 'requirement' }.freeze
      DATA_SECTION = { 'key' => 'cs_data', 'name' => 'csData', 'item_profile' => 'data_section' }.freeze
      DATUM = { 'key' => 'cs_datum', 'name' => 'csDatum', 'item_profile' => 'datum' }.freeze

      # Trackers of the old PORIS plugin (cosmosys_req_poris_rm). Its "blocks"
      # relations point from what a mode includes to the mode; cosmosys_poris
      # points from the mode to what it includes (CosmosysPoris::IssueRelationPatch).
      PORIS_TRACKERS = %w[prSys prParam prMode prValue prValFloat prValText prCmd].freeze

      # Profiles whose items may only hang from an info chapter, and profiles
      # that cannot have children (see Cosmosys::ItemKindRegistry).
      INFO_PARENT_ONLY = %w[requirement doc negative].freeze
      CHILDLESS = %w[requirement doc negative datum].freeze

      # Old requirement statuses => current ones. csNone was the old default of
      # csInfo and csRefDoc; it becomes the destination tracker's default.
      STATUSES = {
        'rqDraft' => 'Draft', 'rqStable' => 'Stable', 'rqApproved' => 'Approved',
        'rqRejected' => 'Rejected', 'rqErased' => 'Erased', 'rqZombie' => 'Erased',
        'csNone' => nil
      }.freeze

      TYPE_MAP = { 'Complex' => 'complex', 'Opt' => 'optical', 'Mech' => 'mechanical', 'Hw' => 'hardware', 'Sw' => 'software' }.freeze
      LEVEL_MAP = { 'System' => 'system', 'Derived' => 'derived', 'External' => 'external', 'Shared' => 'shared' }.freeze
      COMPLIANCE_MAP = { 'To Be Confirmed' => 'to_be_confirmed', 'Not Compliant' => 'not_compliant',
                         'Partially Compliant' => 'partially_compliant', 'Compliant' => 'compliant',
                         'Not Applicable' => 'not_applicable' }.freeze
      VERIFICATION_MAP = { 'To Be Defined' => 'to_be_defined', 'Design' => 'design', 'Analysis' => 'analysis',
                           'Test' => 'test', 'Inspection' => 'inspection' }.freeze

      # Old issue custom fields that become native columns. Each entry gives
      # the native profile field, a value map (nil keeps the text) and whether
      # it applies only to requirements.
      NATIVE_ISSUE_FIELDS = {
        'rqType' => { 'field' => 'rq_type', 'map' => TYPE_MAP, 'requirement' => true, 'default' => 'complex' },
        'rqLevel' => { 'field' => 'rq_level', 'map' => LEVEL_MAP, 'requirement' => true, 'default' => 'system' },
        'rqRationale' => { 'field' => 'rq_rationale', 'requirement' => true },
        'rqSources' => { 'field' => 'rq_srcs', 'requirement' => true },
        'rqComplanceState' => { 'field' => 'rq_compl_state', 'map' => COMPLIANCE_MAP, 'requirement' => true,
                                'default' => 'to_be_confirmed' },
        'rqComplianceJustif' => { 'field' => 'rq_compl_justif', 'requirement' => true },
        'rqVerifDescr' => { 'field' => 'rq_verif_description', 'requirement' => true },
        'Verif_Descr' => { 'field' => 'rq_verif_description', 'requirement' => true },
        'rqVerif' => { 'field' => 'rq_verif_methods', 'map' => VERIFICATION_MAP, 'requirement' => true, 'multiple' => true },
        'Verification' => { 'field' => 'rq_verif_methods', 'map' => VERIFICATION_MAP, 'requirement' => true, 'multiple' => true },
        'csOldCode' => { 'field' => 'cs_ext_code', 'requirement' => false },
        'csWload' => { 'field' => 'cs_wload', 'requirement' => false }
      }.freeze

      DROPPED_ISSUE_FIELDS = {
        'csID' => 'copy of the old internal identifier; the item keeps it as its native CSID',
        'csChapter' => 'copy of the old chapter number; the current cosmoSys computes chapters',
        'depGrahInReports' => 'old report rendering flag without a current equivalent'
      }.freeze
      DATUM_FIELDS = %w[rqVar rqValue].freeze
      DOCUMENT_REFERENCE_FIELDS = { 'rqAplDocs' => 'A', 'rqApplicableDocs' => 'A', 'rqRefDocs' => 'R',
                                    'rqComplianceDocs' => 'C' }.freeze

      PROJECT_CODE_FIELD = 'csCode'
      PROJECT_REPORT_CODE_FIELD = 'csDocCode'
      DROPPED_PROJECT_FIELDS = {
        'csReportMetadata' => 'old report configuration (YAML); the current cosmoSys configures reports per project'
      }.freeze

      DOCUMENT_ITEM = /\A(AD|RD|CD)[\s.\-_]*(\d+)\z/i.freeze
      DOCUMENT_FAMILIES = { 'AD' => 'A', 'RD' => 'R', 'CD' => 'C' }.freeze

      CORE_MODULES = %w[issue_tracking time_tracking news documents files wiki repository boards calendar gantt].freeze

      # Tables of Redmine 4.2 and of the old cosmoSys plugins. Any other table
      # with rows belongs to another plugin, whose data is not migrated yet.
      REDMINE_TABLES = %w[
        ar_internal_metadata attachments auth_sources boards changes changeset_parents changesets changesets_issues
        comments custom_field_enumerations custom_fields custom_fields_projects custom_fields_roles custom_fields_trackers
        custom_values documents email_addresses enabled_modules enumerations groups_users import_items imports
        issue_categories issue_relations issue_statuses issues journal_details journals member_roles members messages
        news open_id_authentication_associations open_id_authentication_nonces projects projects_trackers queries
        queries_roles repositories roles roles_managed_roles schema_migrations settings time_entries tokens trackers
        user_preferences users versions watchers wiki_content_versions wiki_contents wiki_pages wiki_redirects wikis
        workflows
      ].freeze
      COSMOSYS_TABLES = %w[
        cosmosys_issues cosmosys_projects cosmosys_trackers cosmosys_users cosmosys_versions cosmosys_documents
        cosmosys_project_gits csys_reqs csys_poris
      ].freeze

      # Old serialized YAML (possible_values, format_store). Tagged Ruby
      # objects are read as plain lists or "key: value" lines.
      def yaml_list(text)
        return [] if text.to_s.strip.empty?

        Array(YAML.safe_load(text.to_s, permitted_classes: [], aliases: false)).map(&:to_s)
      rescue Psych::Exception
        text.to_s.lines.map(&:chomp).filter_map { |line| line[/\A-\s*(.*)\z/, 1]&.strip&.delete_prefix("'")&.delete_suffix("'") }
      end

      def yaml_hash(text)
        return {} if text.to_s.strip.empty?

        value = YAML.safe_load(text.to_s, permitted_classes: [], aliases: false)
        value.is_a?(Hash) ? value.transform_keys(&:to_s) : {}
      rescue Psych::Exception
        text.to_s.lines.each_with_object({}) do |line, result|
          match = line.chomp.match(/\A([a-z_]+):\s*(.*)\z/)
          result[match[1]] = match[2].strip.delete_prefix("'").delete_suffix("'") if match
        end
      end

      def clean(value)
        return nil if value.nil?

        value.to_s.dup.force_encoding('UTF-8').encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
             .delete("\u0000")
      end

      def normalize_code(code)
        code.to_s.gsub(/[^a-zA-Z0-9]/, '')
      end

      def document_reference(subject)
        match = subject.to_s.strip.match(DOCUMENT_ITEM)
        match && { 'family' => DOCUMENT_FAMILIES.fetch(match[1].upcase), 'position' => match[2].to_i }
      end

      # The pipeline's parser for document titles of the form
      # "Title CODE-WITH-DASHES v2, 03/2022". Installation specific: every
      # extraction is reported.
      def document_metadata(title)
        text = title.to_s.strip
        external_code = text.scan(/\b[A-Z0-9]+(?:-[A-Z0-9]+){2,}\b/i).first
        version = if external_code
                    suffix = text[(text.index(external_code) + external_code.length)..]
                    suffix.to_s.match(/\A[\s,]*(v?\d+(?:\.[A-Za-z0-9]+)?)/i)&.[](1)
                  end
        version ||= text.match(/(?:\A|[\s,])(v\d+(?:\.[A-Za-z0-9]+)?)(?=\s*,|\s*\z)/i)&.[](1)
        version = version.to_s.sub(/\Av/i, '')
        version = nil if version.empty?
        month_year = text.match(%r{(?:\A|[\s,])(0?[1-9]|1[0-2])/(\d{4})\s*\z})
        document_date = Date.new(month_year[2].to_i, month_year[1].to_i, 1).iso8601 if month_year
        clean_title = text.dup
        [month_year&.[](0), version && text.match(/(?:\A|[\s,])v?#{Regexp.escape(version)}(?=\s*,|\s*\z)/i)&.[](0),
         external_code].compact.each do |fragment|
          index = clean_title.rindex(fragment)
          clean_title.slice!(index, fragment.length) if index
        end
        clean_title.gsub!(/\s*,\s*,+/, ', ')
        clean_title.gsub!(/\A[\s,;:\-]+|[\s,;:\-]+\z/, '')
        clean_title.gsub!(/\s{2,}/, ' ')
        { 'title' => clean_title.empty? ? text : clean_title, 'external_code' => external_code,
          'version' => version, 'date' => document_date }
      end

      # Lines of a document reference field: "AD 1 | sense | location".
      def document_reference_lines(text)
        text.to_s.lines.each_with_index.filter_map do |line, index|
          parts = line.strip.split('|', 3).map(&:strip)
          match = parts.first.to_s.match(/\A(?:AD|RD|CD)[\s.\-_]*(\d+)\z/i)
          next unless match

          { 'line' => index, 'position' => match[1].to_i, 'sense' => parts[1].to_s, 'location' => parts[2].to_s }
        end
      end

      def unparsed_reference_text(text)
        text.to_s.lines.reject do |line|
          line.strip.empty? || line.strip.split('|', 3).first.to_s.strip.match?(/\A(?:AD|RD|CD)[\s.\-_]*\d+\z/i)
        end.join
      end

      def ambiguous_markdown_tables(text)
        lines = text.to_s.gsub("\r\n", "\n").split("\n", -1)
        lines.each_cons(2).with_index.filter_map do |(header, separator), index|
          ambiguous = header.match?(/\A[ \t]{4,}\|/) || (header.include?('|') && !header.lstrip.start_with?('|'))
          cells = separator.strip.sub(/\A\|/, '').sub(/\|\z/, '').split('|').map(&:strip)
          next unless ambiguous && cells.length >= 2 && cells.all? { |cell| cell.match?(/\A:?-{3,}:?\z/) }

          index + 1
        end
      end

      # Parses the Ruby literal that the old plugin stored in
      # cosmosys_issues.relations_on_close (Array#to_s of Hashes). It never
      # evaluates code: only arrays, hashes, symbols, strings, numbers, nil,
      # true and false are accepted.
      def parse_ruby_literal(text)
        scanner = StringScanner.new(text.to_s)
        value = literal(scanner)
        scanner.skip(/\s*/)
        raise ArgumentError, "unexpected text at #{scanner.pos}" unless scanner.eos?

        value
      end

      def literal(scanner)
        scanner.skip(/\s*/)
        if scanner.scan(/\[/)
          items = []
          loop do
            scanner.skip(/\s*/)
            break if scanner.scan(/\]/)

            items << literal(scanner)
            scanner.skip(/\s*/)
            next if scanner.scan(/,/)
            raise ArgumentError, "expected , or ] at #{scanner.pos}" unless scanner.scan(/\]/)

            break
          end
          items
        elsif scanner.scan(/\{/)
          hash = {}
          loop do
            scanner.skip(/\s*/)
            break if scanner.scan(/\}/)

            key = if scanner.scan(/:([A-Za-z_][A-Za-z0-9_]*[?!]?)\s*=>/) || scanner.scan(/([A-Za-z_][A-Za-z0-9_]*):(?!:)/)
                    scanner[1]
                  else
                    found = literal(scanner)
                    scanner.skip(/\s*/)
                    raise ArgumentError, "expected => at #{scanner.pos}" unless scanner.scan(/=>/)

                    found
                  end
            hash[key.to_s] = literal(scanner)
            scanner.skip(/\s*/)
            next if scanner.scan(/,/)
            raise ArgumentError, "expected , or } at #{scanner.pos}" unless scanner.scan(/\}/)

            break
          end
          hash
        elsif scanner.scan(/"((?:[^"\\]|\\.)*)"/)
          scanner[1].gsub(/\\(u\{?[0-9a-fA-F]+\}?|.)/) do
            escape = Regexp.last_match(1)
            case escape
            when 'n' then "\n"
            when 't' then "\t"
            when 'r' then "\r"
            when /\Au\{?([0-9a-fA-F]+)\}?\z/ then [Regexp.last_match(1).hex].pack('U')
            else escape
            end
          end
        elsif scanner.scan(/:([A-Za-z_][A-Za-z0-9_]*[?!]?)/)
          scanner[1]
        elsif scanner.scan(/-?\d+\.\d+(?:e[+-]?\d+)?/i)
          scanner.matched.to_f
        elsif scanner.scan(/-?\d+/)
          scanner.matched.to_i
        elsif scanner.scan(/nil\b/)
          nil
        elsif scanner.scan(/true\b/)
          true
        elsif scanner.scan(/false\b/)
          false
        else
          raise ArgumentError, "unsupported literal at #{scanner.pos}: #{scanner.peek(20).inspect}"
        end
      end
    end
  end
end
