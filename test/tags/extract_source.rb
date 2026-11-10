# frozen_string_literal: true
require_relative 'extract'
raise 'usage: rails runner extract_source.rb OUT.jsonl' unless ARGV.length == 1
ActiveRecord::Base.uncached do
  TagsEvidence::Extractor.new(ActiveRecord::Base.connection, 'source').capture(ARGV.fetch(0))
end
