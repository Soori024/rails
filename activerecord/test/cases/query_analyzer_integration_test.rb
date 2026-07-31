# frozen_string_literal: true

require "cases/helper"
require "models/post"
require "models/author"
require "models/comment"

module ActiveRecord
  # Integration tests that drive *real* Active Record queries against the test
  # database through the Query Analyzer, exercising the full instrumentation
  # path (adapter -> sql.active_record -> Subscriber -> Collector) rather than
  # feeding the Collector synthetic queries.
  class QueryAnalyzerIntegrationTest < ActiveRecord::TestCase
    fixtures :posts, :authors, :author_addresses, :comments

    def setup
      ActiveSupport::ExecutionContext.clear
      QueryAnalyzer::Collector.reset
      QueryAnalyzer.reset_configuration!
    end

    def teardown
      QueryAnalyzer.uninstall
      QueryAnalyzer.reset_configuration!
      QueryAnalyzer::Collector.reset
    end

    test "captures real queries executed by Active Record" do
      collector = QueryAnalyzer.analyze do
        Post.limit(3).to_a
      end

      assert_operator collector.total_count, :>=, 1
      assert(collector.queries.any? { |q| q.sql.match?(/SELECT.+FROM.+posts/i) })
    end

    test "records a real measured duration for executed queries" do
      collector = QueryAnalyzer.analyze do
        Post.first
      end

      durations = collector.queries.map(&:duration_ms)
      assert durations.all? { |d| !d.nil? && d >= 0.0 }
    end

    test "detects a real N+1 across an association" do
      QueryAnalyzer.n_plus_one_threshold = 2

      collector = QueryAnalyzer.analyze do
        # One query for the posts, then one per post for its author: a textbook
        # N+1 that eager loading (includes(:author)) would collapse.
        Post.limit(5).each { |post| post.author&.name }
      end

      issues = collector.potential_n_plus_ones
      assert_not_empty issues, "expected the author lookups to be flagged as N+1"
      assert(issues.any? { |i| i[:table] == "authors" })
    end

    test "eager loading avoids the N+1 flag" do
      QueryAnalyzer.n_plus_one_threshold = 2

      collector = QueryAnalyzer.analyze do
        Post.includes(:author).limit(5).each { |post| post.author&.name }
      end

      authors_n_plus_one = collector.potential_n_plus_ones.select { |i| i[:table] == "authors" }
      assert_empty authors_n_plus_one, "eager loaded authors should not be flagged"
    end

    test "detects duplicate identical queries within a unit of work" do
      collector = QueryAnalyzer.analyze do
        3.times { Post.where(id: 1).to_a }
      end

      assert(collector.duplicates.any? { |d| d[:count] >= 2 })
    end

    test "does not alter query results while analyzing" do
      expected = Post.order(:id).limit(3).pluck(:id)

      actual = nil
      QueryAnalyzer.analyze do
        actual = Post.order(:id).limit(3).pluck(:id)
      end

      assert_equal expected, actual
    end

    test "is inert when disabled" do
      # Disabled: no collector should be created even while queries run.
      QueryAnalyzer.reset_configuration! # enabled? => false
      Post.limit(2).to_a
      assert_nil QueryAnalyzer::Collector.current_without_create
    end

    test "flags a real query as slow when the threshold is very low" do
      QueryAnalyzer.slow_query_threshold_ms = 0.0 # everything with measured time qualifies

      collector = QueryAnalyzer.analyze do
        Post.limit(3).to_a
      end

      # With a zero threshold, any non-cached query with a measured duration is slow.
      assert_operator collector.slow_queries.size, :>=, 1
    end
  end
end
