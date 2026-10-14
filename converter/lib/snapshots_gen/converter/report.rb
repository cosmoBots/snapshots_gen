# frozen_string_literal: true

require 'json'

module SnapshotsGen
  module Converter
    # Findings of a conversion. Every transformation, loss or doubt is
    # recorded with a code, so nothing changes silently.
    class Report
      SEVERITIES = %w[blocking warning transformation information].freeze

      # Codes the converter emits, with the severity and the sentence shown in
      # the summary. Changes that the old cosmoSys never recorded in its
      # history are information: they cannot be recovered by any tool.
      CODES = {
        'project_code_normalized' => ['transformation', 'Project codes made alphanumeric'],
        'project_code_collision' => ['transformation', 'Project codes renamed because they collided'],
        'project_field_dropped' => ['transformation', 'Project custom fields without a current equivalent'],
        'identity_renumbered' => ['transformation', 'CSIDs renumbered (missing, invalid or repeated in the tree)'],
        'identity_foreign_prefix_kept' => ['information', 'CSIDs kept with the prefix of another project (moved items)'],
        'identity_prefix_normalized' => ['transformation', 'CSIDs rewritten with the normalized project code'],
        'synthetic_chapter' => ['transformation', 'Chapters generated around items that cannot have children'],
        'document_item_absorbed' => ['transformation', 'AD/RD/CD items turned into documents'],
        'document_metadata_extracted' => ['transformation', 'Document codes, versions and dates read from titles'],
        'catalog_reference' => ['transformation', 'Catalog references created'],
        'datum_created' => ['transformation', 'Requirement variables (rqVar, rqValue) turned into project data'],
        'status_mapped' => ['transformation', 'Statuses renamed'],
        'tracker_mapped' => ['transformation', 'Trackers renamed'],
        'field_native' => ['transformation', 'Custom field values moved to native fields'],
        'field_value_unmapped' => ['warning', 'Values without a current equivalent (default used)'],
        'field_dropped' => ['transformation', 'Custom fields without a current equivalent'],
        'field_kept' => ['information', 'Custom fields kept as custom fields (definition in the history package)'],
        'reference_text_kept' => ['warning', 'Document reference fields with text that is not a reference'],
        'position_renumbered' => ['transformation', 'Sibling positions renumbered'],
        'relation_to_document' => ['transformation', 'Relations to AD/RD/CD items turned into catalog references'],
        'relation_dropped' => ['warning', 'Relations whose other end is not migrated'],
        'poris_relation_reversed' => ['transformation', 'PORIS "blocks" relations reversed (the mode now blocks what it includes), with their history'],
        'relation_cross_package' => ['information', 'Relations between packages, restored by the history importer'],
        'relations_on_close' => ['information', 'Relations kept by erased or zombie requirements'],
        'relations_on_close_unparsed' => ['warning', 'Stored relations of erased requirements that could not be read'],
        'attachment_missing' => ['warning', 'Attachments without file in the source'],
        'reference_neutralized' => ['warning', 'Item references (#id) to items that are not migrated, escaped'],
        'reference_cross_package' => ['information', 'Item references to other packages, resolved by the history importer'],
        'other_references' => ['information', 'References to documents, versions, changesets or notes left as they are'],
        'ambiguous_markdown_table' => ['warning', 'Indented Markdown table headers that CommonMark shows as code'],
        'text_formatting' => ['information', 'Text formatting of the source'],
        'textile_source' => ['blocking', 'Textile content needs a conversion that this version does not do'],
        'history_detail_dropped' => ['warning', 'History details that cannot be translated'],
        'history_journal_dropped' => ['warning', 'Journals left empty after dropping details'],
        'history_journal_document' => ['information', 'Journals of AD/RD/CD items (absorbed into documents)'],
        'history_never_recorded' => ['information', 'Changes the old cosmoSys never recorded in the history'],
        'wiki_version_gap' => ['information', 'Wiki versions missing in the source'],
        'user_without_login' => ['warning', 'Users without login'],
        'user_external_auth' => ['warning', 'Users authenticated by an external source'],
        'user_2fa_reset' => ['information', 'Users whose 2FA is reset'],
        'role_mapped' => ['information', 'Roles of memberships'],
        'shared_version' => ['information', 'Versions shared with other projects, assigned by the history importer'],
        'source_gap' => ['warning', 'Gaps reported by the exporter'],
        'unsupported_content' => ['information', 'Content present in the source that this version does not migrate'],
        'plugin_data_not_migrated' => ['warning', 'Tables of other plugins with data, not migrated']
      }.freeze

      attr_reader :entries

      def initialize
        @entries = []
      end

      def add(code, subject = nil, **detail)
        raise ArgumentError, "unknown report code #{code}" unless CODES.key?(code)

        @entries << { 'code' => code, 'subject' => subject, 'detail' => detail.transform_keys(&:to_s) }
      end

      def count(code)
        @entries.count { |entry| entry['code'] == code }
      end

      def blocking?
        @entries.any? { |entry| CODES.fetch(entry['code']).first == 'blocking' }
      end

      def to_h(summary = {})
        {
          'format' => 'snapshots_gen-conversion-report-v1',
          'summary' => summary,
          'counts' => @entries.group_by { |entry| entry['code'] }.transform_values(&:length).sort.to_h,
          'entries' => @entries.sort_by { |entry| [entry['code'], entry['subject'].to_s] }
        }
      end

      def markdown(summary)
        lines = ['# Conversion report', '']
        summary.each { |key, value| lines << "- #{key}: #{value.is_a?(Array) ? value.join(', ') : value}" }
        lines << ''
        SEVERITIES.each do |severity|
          codes = CODES.select { |_code, (level, _text)| level == severity }.keys
          present = codes.select { |code| count(code).positive? }
          next if present.empty?

          lines << "## #{severity.capitalize}" << ''
          present.each do |code|
            lines << "### #{CODES.fetch(code).last} (`#{code}`, #{count(code)})" << ''
            @entries.select { |entry| entry['code'] == code }.first(50).each do |entry|
              detail = entry['detail'].map { |key, value| "#{key}=#{value.is_a?(String) ? value : JSON.generate(value)}" }.join(', ')
              lines << "- #{[entry['subject'], detail].reject { |part| part.to_s.empty? }.join(': ')}"
            end
            lines << "- ... #{count(code) - 50} more in report.json" if count(code) > 50
            lines << ''
          end
        end
        lines.join("\n")
      end
    end
  end
end
