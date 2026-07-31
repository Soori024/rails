# frozen_string_literal: true

# Benchmarks the Query Analyzer's hot-path components: SQL normalization and
# per-query collection. These run for every query when the analyzer is enabled,
# so their cost bounds the analyzer's development/test overhead.
#
# Run with benchmark-ips (preferred, as in examples/performance.rb):
#
#   ruby -Ilib -I../activesupport/lib activerecord/examples/query_analyzer_benchmark.rb
#
# If benchmark-ips is not installed it falls back to the stdlib Benchmark,
# reporting wall-clock time for a fixed number of iterations.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../../activesupport/lib", __dir__)

require "active_support"
require "active_support/isolated_execution_state"
require "active_record/query_analyzer"

QA = ActiveRecord::QueryAnalyzer
Normalizer = QA::Normalizer
Collector  = QA::Collector

SAMPLE_QUERIES = [
  %q{SELECT "posts".* FROM "posts" WHERE "posts"."id" = 42 LIMIT 1},
  %q{SELECT "users".* FROM "users" WHERE "users"."email" = 'alice@example.com'},
  %q{SELECT "comments".* FROM "comments" WHERE "comments"."post_id" IN (1, 2, 3, 4, 5)},
  %q{UPDATE "accounts" SET "balance" = 100.5 WHERE "accounts"."id" = $1},
  %q{SELECT COUNT(*) FROM "orders" WHERE "orders"."created_at" >= '2020-01-01' AND total > 9.99e3},
].freeze

def with_ips?
  require "benchmark/ips"
  true
rescue LoadError
  false
end

QA.enabled = true

if with_ips?
  Benchmark.ips do |x|
    x.report("Normalizer.normalize") do
      SAMPLE_QUERIES.each { |sql| Normalizer.normalize(sql) }
    end

    x.report("Collector#record") do
      collector = Collector.new
      SAMPLE_QUERIES.each { |sql| collector.record(sql: sql, duration_ms: 0.5) }
    end

    x.report("record + summary (100 queries)") do
      collector = Collector.new
      100.times { |i| collector.record(sql: SAMPLE_QUERIES[i % SAMPLE_QUERIES.size], duration_ms: 0.5) }
      collector.summary
    end

    x.compare!
  end
else
  require "benchmark"
  n = 50_000
  puts "benchmark-ips not available; using stdlib Benchmark (#{n} iterations)\n\n"
  Benchmark.bm(34) do |x|
    x.report("Normalizer.normalize (x5 each)") do
      n.times { SAMPLE_QUERIES.each { |sql| Normalizer.normalize(sql) } }
    end
    x.report("Collector#record (x5 each)") do
      n.times do
        collector = Collector.new
        SAMPLE_QUERIES.each { |sql| collector.record(sql: sql, duration_ms: 0.5) }
      end
    end
  end

  # Report a per-query figure so overhead is easy to reason about.
  require "benchmark"
  single = Benchmark.realtime { (n * 5).times { Normalizer.normalize(SAMPLE_QUERIES.first) } }
  per_query_us = (single / (n * 5)) * 1_000_000
  puts format("\nNormalizer.normalize: ~%.2f microseconds per query", per_query_us)
end
