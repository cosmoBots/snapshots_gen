# frozen_string_literal: true
require_relative 'extract'
raise 'usage: rails runner extract_target.rb OUT.jsonl' unless ARGV.length == 1
ActiveRecord::Base.uncached do
  TagsEvidence::Extractor.new(ActiveRecord::Base.connection, 'target').capture(ARGV.fetch(0))
end
