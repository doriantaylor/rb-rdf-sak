require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

task :default => :spec

#desc 'Generate Vocabularies'
#task :gen_vocabs => %w(ci).map { |v| "lib/rdf/sak/#{v}.rb" }

# XXX turn this into a rake task at some point :P

# rdf serialize --uri 'https://privatealpha.com/ontology/content-inventory/1#' --output-format vocabulary --module-name RDF::SAK --class-name CI -o lib/rdf/sak/ci.rb --strict 'https://privatealpha.com/ontology/content-inventory/1#'
