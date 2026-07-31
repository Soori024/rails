# frozen_string_literal: true

# Measures the overhead the query analyzer adds to query execution, and
# demonstrates the report it produces.
#
#   ruby -Ilib -I../activesupport/lib -I../activemodel/lib examples/query_analyzer.rb

require "active_record"
require "benchmark"

QUERIES = (ENV["BENCHMARK_QUERIES"] || 3_000).to_i
RECORDS = (ENV["BENCHMARK_RECORDS"] || 200).to_i

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")

class Sample < ActiveRecord::Base
  connection.create_table :samples, force: true do |t|
    t.string :name
    t.integer :group_id
  end
end

RECORDS.times { |i| Sample.create!(name: "sample #{i}", group_id: i % 10) }

analyzer = ActiveRecord::QueryAnalyzer

def run(count)
  count.times { |i| Sample.where(id: (i % RECORDS) + 1).to_a }
end

run(50) # warm up the statement cache and the connection

disabled = Benchmark.realtime { run(QUERIES) }

analyzer.install_subscriber
enabled = Benchmark.realtime do
  analyzer.analyze { run(QUERIES) }
end

overhead = enabled - disabled

puts "#{QUERIES} queries over #{RECORDS} records"
puts
puts format("  disabled:  %.3fs  (%.4f ms/query)", disabled, disabled * 1000 / QUERIES)
puts format("  analyzing: %.3fs  (%.4f ms/query)", enabled, enabled * 1000 / QUERIES)
puts format("  overhead:  %.4f ms/query  (%+.1f%%)", overhead * 1000 / QUERIES, overhead / disabled * 100)
puts
puts "Note: the analyzer is disabled by default and only subscribes when"
puts "enabled, so an application that leaves it off pays none of the above."
puts

# Show the report an N+1 produces.
analyzer.n_plus_one_threshold = 5
analyzer.slow_query_threshold = ENV["SLOW_QUERY_THRESHOLD"]&.to_f
report = analyzer.analyze do
  Sample.limit(10).each { |sample| Sample.where(group_id: sample.group_id).to_a }
end

puts report.to_s
