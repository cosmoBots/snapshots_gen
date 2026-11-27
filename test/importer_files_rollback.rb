# frozen_string_literal: true

# Checks on disk that the files the history import creates (the files of the
# Files module) do not survive a dry run or a failed import. For a disposable
# new instance only, after its .csys imports and before its real history
# import:
#
#   rails runner test/importer_files_rollback.rb /tmp/sg/pkg/NAME.cshistory
#
# It runs the history import twice and rolls both back: once as a dry run,
# and once forced to fail at its verification, after every file has been
# written. Each time it lists the attachment directory before, during (at
# the verification, inside the transaction) and after. Exits 1 if a file is
# left behind or the database keeps an attachment.
#
# allow_existing_journals=yes runs it on an instance whose history is
# already imported (only to measure: it is rolled back as well).
require_relative '../importer/history_importer'
require_relative '../importer/silence'

module SnapshotsGen
  module Importer
    # The real import, counting the files on disk when it verifies.
    class CountingRun < Run
      class << self
        attr_accessor :during
      end

      private

      def verify!
        CountingRun.during = Dir.glob(File.join(Attachment.storage_path, '**', '*')).count { |file| File.file?(file) }
        super
      end
    end

    # The same, with a verification that always fails.
    class FailingRun < CountingRun
      private

      def verify!
        super + ['forced failure of the rollback check']
      end
    end
  end
end

path = ARGV[0] || raise('usage: importer_files_rollback.rb HISTORY.cshistory [allow_existing_journals=yes]')
extra = ARGV[1] == 'allow_existing_journals=yes' ? { 'allow_existing_journals' => true } : {}
files = -> { Dir.glob(File.join(Attachment.storage_path, '**', '*')).select { |file| File.file?(file) }.sort }
attachments = -> { Attachment.where(container_type: %w[Project Version]).count }
failures = []
{ 'dry run' => [SnapshotsGen::Importer::CountingRun, { 'dry_run' => true }],
  'failed import' => [SnapshotsGen::Importer::FailingRun, {}] }.each do |label, (klass, options)|
  before_files = files.call
  before_rows = attachments.call
  outcome = begin
    SnapshotsGen::Importer::Silence.run do
      SnapshotsGen::Importer::Package.open(path) { |package| klass.new(package, options.merge('roles' => {}).merge(extra)).history! }
    end
    'finished'
  rescue SnapshotsGen::Importer::Error => error
    "refused: #{error.message.lines.first.strip}"
  end
  during = SnapshotsGen::Importer::CountingRun.during
  SnapshotsGen::Importer::CountingRun.during = nil
  left = files.call - before_files
  rows = attachments.call - before_rows
  puts "#{label}: #{outcome}; files on disk #{before_files.length} before, #{during.inspect} during, #{files.call.length} after, " \
       "new files left #{left.length}, " \
       "project and version attachments #{before_rows} -> #{attachments.call}"
  failures << "#{label}: #{left.length} files left on disk" if left.any?
  failures << "#{label}: #{rows} attachments left in the database" unless rows.zero?
end
if failures.empty?
  puts 'Rollback check: no file and no attachment left behind.'
else
  puts "Rollback check FAILED: #{failures.join('; ')}"
  exit 1
end
