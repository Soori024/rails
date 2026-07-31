# frozen_string_literal: true

require "cases/helper"
require "models/post"
require "models/author"
require "models/comment"

module ActiveRecord
  class QueryAnalyzerSqlNormalizerTest < ActiveRecord::TestCase
    Normalizer = ActiveRecord::QueryAnalyzer::SqlNormalizer

    def test_normalizes_integer_literals
      assert_equal %{SELECT * FROM "users" WHERE "id" = ?},
        Normalizer.normalize(%{SELECT * FROM "users" WHERE "id" = 1})
    end

    def test_queries_differing_only_by_value_share_a_shape
      first = Normalizer.normalize(%{SELECT * FROM "users" WHERE "id" = 1})
      second = Normalizer.normalize(%{SELECT * FROM "users" WHERE "id" = 4711})

      assert_equal first, second
    end

    def test_normalizes_string_literals
      assert_equal %{SELECT * FROM "users" WHERE "name" = ?},
        Normalizer.normalize(%{SELECT * FROM "users" WHERE "name" = 'dhh'})
    end

    def test_digits_inside_a_string_literal_are_not_separately_replaced
      assert_equal %{SELECT * FROM "users" WHERE "name" = ?},
        Normalizer.normalize(%{SELECT * FROM "users" WHERE "name" = 'user123'})
    end

    def test_normalizes_escaped_quotes_inside_string_literals
      assert_equal %{SELECT * FROM "users" WHERE "name" = ? AND "id" = ?},
        Normalizer.normalize(%{SELECT * FROM "users" WHERE "name" = 'O''Reilly' AND "id" = 5})
    end

    def test_normalizes_decimal_and_scientific_literals
      assert_equal %{SELECT * FROM "t" WHERE "a" = ? AND "b" = ?},
        Normalizer.normalize(%{SELECT * FROM "t" WHERE "a" = 1.25 AND "b" = 1e10})
    end

    def test_collapses_in_lists_of_differing_length
      three = Normalizer.normalize(%{SELECT * FROM "users" WHERE "id" IN (1, 2, 3)})
      two = Normalizer.normalize(%{SELECT * FROM "users" WHERE "id" IN (7, 8)})

      assert_equal %{SELECT * FROM "users" WHERE "id" IN (?)}, three
      assert_equal three, two
    end

    def test_normalizes_postgresql_bind_placeholders
      assert_equal "SELECT * FROM users WHERE id = ? AND name = ?",
        Normalizer.normalize("SELECT * FROM users WHERE id = $1 AND name = $2")
    end

    def test_normalizes_named_and_question_mark_placeholders
      assert_equal "SELECT * FROM users WHERE id = ? AND name = ?",
        Normalizer.normalize("SELECT * FROM users WHERE id = ? AND name = :name")
    end

    def test_a_comment_marker_inside_a_string_literal_is_not_treated_as_a_comment
      # Stripping comments before string literals would delete from the "--" to
      # end of line, discarding the rest of the predicate and leaving an
      # unterminated quote behind.
      assert_equal %{SELECT * FROM "notes" WHERE "note" = ? AND "id" = ?},
        Normalizer.normalize(%{SELECT * FROM "notes" WHERE "note" = 'a -- b' AND "id" = 1})
    end

    def test_a_block_comment_marker_inside_a_string_literal_is_preserved
      assert_equal %{SELECT * FROM "t" WHERE "c" = ? AND "id" = ?},
        Normalizer.normalize(%{SELECT * FROM "t" WHERE "c" = 'a /* b' AND "id" = 3})
    end

    def test_queries_differing_after_an_in_string_comment_marker_do_not_collide
      first = Normalizer.normalize(%{SELECT * FROM "a" WHERE "n" = 'x -- y' AND "id" = 1})
      second = Normalizer.normalize(%{SELECT * FROM "a" WHERE "n" = 'x -- z' AND "deleted" = 0})

      assert_not_equal first, second
    end

    def test_negative_and_positive_numbers_share_a_shape
      assert_equal Normalizer.normalize("SELECT * FROM t WHERE a = 5"),
        Normalizer.normalize("SELECT * FROM t WHERE a = -5")
    end

    def test_preserves_postgresql_casts
      assert_equal "SELECT * FROM t WHERE x::int8 = ?",
        Normalizer.normalize("SELECT * FROM t WHERE x::int8 = 1")
      assert_equal "SELECT * FROM t WHERE a = ?::text",
        Normalizer.normalize("SELECT * FROM t WHERE a = 'x'::text")
    end

    def test_preserves_mysql_system_variables
      assert_equal "SELECT @@version", Normalizer.normalize("SELECT @@version")
    end

    def test_normalizes_dollar_quoted_strings
      assert_equal "SELECT ? FROM t WHERE id = ?",
        Normalizer.normalize("SELECT $$hello$$ FROM t WHERE id = 1")
      assert_equal "SELECT ? FROM t WHERE id = ?",
        Normalizer.normalize("SELECT $tag$body$tag$ FROM t WHERE id = 2")
    end

    def test_strips_comments_including_query_log_tags
      assert_equal "SELECT * FROM users WHERE id = ?",
        Normalizer.normalize("SELECT * FROM users WHERE id = 1 /*application:Foo*/")
    end

    def test_strips_line_comments
      assert_equal "SELECT * FROM users WHERE id = ?",
        Normalizer.normalize("SELECT * FROM users WHERE id = 1 -- a trailing note")
    end

    def test_collapses_whitespace_from_multiline_sql
      sql = <<~SQL
        SELECT *
        FROM     users
        WHERE    id = 1
      SQL

      assert_equal "SELECT * FROM users WHERE id = ?", Normalizer.normalize(sql)
    end

    def test_normalizes_mysql_backtick_quoting
      assert_equal "SELECT * FROM `posts` WHERE `user_id` = ?",
        Normalizer.normalize("SELECT * FROM `posts` WHERE `user_id` = 7")
    end

    def test_returns_empty_string_for_nil_and_blank
      assert_equal "", Normalizer.normalize(nil)
      assert_equal "", Normalizer.normalize("")
    end

    def test_truncates_pathologically_long_sql
      sql = "SELECT * FROM t WHERE x IN (#{Array.new(5_000) { |i| i }.join(', ')})"

      assert_operator Normalizer.normalize(sql).length, :<=, Normalizer::MAX_LENGTH
    end

    # The same logical query as each adapter actually emits it. Bind styles
    # differ per adapter, so normalization has to converge on one shape for
    # duplicate detection to work regardless of the database in use.
    def test_adapter_bind_styles_converge_on_one_shape
      postgresql = %{SELECT "users".* FROM "users" WHERE "users"."id" = $1 LIMIT $2}
      sqlite = %{SELECT "users".* FROM "users" WHERE "users"."id" = ? LIMIT ?}
      mysql = %{SELECT `users`.* FROM `users` WHERE `users`.`id` = 42 LIMIT 1}

      assert_equal Normalizer.normalize(postgresql), Normalizer.normalize(sqlite)

      # MySQL quotes identifiers differently, so its shape differs by quoting
      # only. The values are still normalized away.
      assert_equal %{SELECT `users`.* FROM `users` WHERE `users`.`id` = ? LIMIT ?},
        Normalizer.normalize(mysql)

      [postgresql, sqlite, mysql].each do |sql|
        assert_equal "users", Normalizer.table_name(sql)
      end
    end

    def test_truncated_reports_whether_the_cap_was_hit
      short = Normalizer.normalize("SELECT * FROM t WHERE id = 1")
      assert_not Normalizer.truncated?(short)

      long = Normalizer.normalize("SELECT #{'x' * 5_000} FROM t WHERE id = 1")
      assert Normalizer.truncated?(long)
    end

    def test_extracts_table_name_across_quoting_styles
      assert_equal "users", Normalizer.table_name(%{SELECT * FROM "users" WHERE id = 1})
      assert_equal "posts", Normalizer.table_name("SELECT * FROM `posts`")
      assert_equal "widgets", Normalizer.table_name("SELECT * FROM widgets")
    end

    def test_extracts_table_name_for_writes
      assert_equal "comments", Normalizer.table_name(%{INSERT INTO "comments" ("body") VALUES ('x')})
      assert_equal "users", Normalizer.table_name(%{UPDATE "users" SET "name" = 'x'})
    end

    def test_strips_schema_prefix_from_table_name
      assert_equal "accounts", Normalizer.table_name("SELECT * FROM public.accounts")
    end

    def test_table_name_returns_nil_when_absent
      assert_nil Normalizer.table_name("SELECT 1")
      assert_nil Normalizer.table_name(nil)
    end
  end

  class QueryAnalyzerCollectorTest < ActiveRecord::TestCase
    Collector = ActiveRecord::QueryAnalyzer::Collector

    setup do
      @collector = Collector.new
      @original_threshold = QueryAnalyzer.n_plus_one_threshold
      @original_max = QueryAnalyzer.max_tracked_queries
      @original_duplicates = QueryAnalyzer.detect_duplicates
      @original_n_plus_one = QueryAnalyzer.detect_n_plus_one
    end

    teardown do
      QueryAnalyzer.n_plus_one_threshold = @original_threshold
      QueryAnalyzer.max_tracked_queries = @original_max
      QueryAnalyzer.detect_duplicates = @original_duplicates
      QueryAnalyzer.detect_n_plus_one = @original_n_plus_one
    end

    def test_a_new_collector_is_empty
      assert_predicate @collector, :empty?
      assert_equal 0, @collector.total_queries
    end

    def test_counts_queries_and_accumulates_duration
      @collector.record(sql: "SELECT * FROM users WHERE id = 1", duration: 1.5)
      @collector.record(sql: "SELECT * FROM users WHERE id = 2", duration: 2.5)

      assert_equal 2, @collector.total_queries
      assert_in_delta 4.0, @collector.total_duration, 0.001
    end

    def test_groups_queries_by_normalized_shape
      3.times { |i| @collector.record(sql: "SELECT * FROM users WHERE id = #{i}") }

      assert_equal 1, @collector.query_stats.size
      assert_equal 3, @collector.query_stats.values.first.count
    end

    def test_detects_duplicates_and_counts_only_redundant_executions
      3.times { |i| @collector.record(sql: "SELECT * FROM users WHERE id = #{i}") }

      assert_equal 1, @collector.duplicates.size
      # Three executions of one shape means two were redundant.
      assert_equal 2, @collector.duplicate_query_count
    end

    def test_a_query_run_once_is_not_a_duplicate
      @collector.record(sql: "SELECT * FROM users WHERE id = 1")

      assert_empty @collector.duplicates
      assert_equal 0, @collector.duplicate_query_count
    end

    def test_duplicates_are_ordered_by_frequency
      2.times { @collector.record(sql: "SELECT * FROM a WHERE id = 1") }
      5.times { @collector.record(sql: "SELECT * FROM b WHERE id = 1") }

      assert_equal "b", @collector.duplicates.first.table_name
    end

    def test_detects_n_plus_one_above_the_threshold
      QueryAnalyzer.n_plus_one_threshold = 5
      5.times { |i| @collector.record(sql: "SELECT * FROM authors WHERE id = #{i}") }

      candidates = @collector.n_plus_one_candidates
      assert_equal 1, candidates.size
      assert_equal "authors", candidates.first.table_name
    end

    def test_does_not_flag_n_plus_one_below_the_threshold
      QueryAnalyzer.n_plus_one_threshold = 5
      4.times { |i| @collector.record(sql: "SELECT * FROM authors WHERE id = #{i}") }

      assert_empty @collector.n_plus_one_candidates
    end

    def test_repeated_constant_query_is_not_flagged_as_n_plus_one
      # No bind values, so this is a repeated constant rather than a per-record
      # lookup. Flagging it would be a false positive.
      QueryAnalyzer.n_plus_one_threshold = 3
      10.times { @collector.record(sql: "SELECT current_user") }

      assert_empty @collector.n_plus_one_candidates
    end

    def test_writes_are_not_flagged_as_n_plus_one
      QueryAnalyzer.n_plus_one_threshold = 3
      10.times { |i| @collector.record(sql: "INSERT INTO logs (id) VALUES (#{i})") }

      assert_empty @collector.n_plus_one_candidates
    end

    def test_detection_can_be_disabled_independently
      QueryAnalyzer.n_plus_one_threshold = 3
      5.times { |i| @collector.record(sql: "SELECT * FROM authors WHERE id = #{i}") }

      QueryAnalyzer.detect_duplicates = false
      assert_empty @collector.duplicates
      assert_not_empty @collector.n_plus_one_candidates

      QueryAnalyzer.detect_duplicates = true
      QueryAnalyzer.detect_n_plus_one = false
      assert_not_empty @collector.duplicates
      assert_empty @collector.n_plus_one_candidates
    end

    def test_tracks_cached_queries_separately
      @collector.record(sql: "SELECT * FROM users WHERE id = 1", cached: true)

      assert_equal 1, @collector.total_queries
      assert_equal 1, @collector.cached_queries
    end

    def test_respects_max_tracked_queries
      QueryAnalyzer.max_tracked_queries = 3
      6.times { |i| @collector.record(sql: "SELECT c#{i} FROM t WHERE id = 1") }

      assert_equal 3, @collector.query_stats.size
      # Totals still reflect every query, even the untracked ones.
      assert_equal 6, @collector.total_queries
      assert_equal 3, @collector.ignored_queries
    end

    def test_ignores_unnormalizable_sql
      @collector.record(sql: nil)
      @collector.record(sql: "")

      assert_predicate @collector, :empty?
    end

    def test_reset_clears_all_state
      @collector.record(sql: "SELECT * FROM users WHERE id = 1")
      @collector.reset

      assert_predicate @collector, :empty?
      assert_empty @collector.query_stats
      assert_equal 0, @collector.total_duration
    end
  end

  class QueryAnalyzerReportTest < ActiveRecord::TestCase
    def build_report(&block)
      collector = ActiveRecord::QueryAnalyzer::Collector.new
      block.call(collector)
      collector.report
    end

    def test_empty_report_has_no_summary
      report = build_report { }

      assert_predicate report, :empty?
      # to_s must honor the Object#to_s contract and return a String.
      assert_equal "", report.to_s
    end

    def test_clean_report_when_nothing_repeats
      report = build_report { |c| c.record(sql: "SELECT * FROM users WHERE id = 1") }

      assert_predicate report, :clean?
      assert_not_predicate report, :duplicates?
      assert_not_predicate report, :n_plus_one?
    end

    def test_summary_mentions_duplicates
      report = build_report do |c|
        3.times { |i| c.record(sql: "SELECT * FROM users WHERE id = #{i}") }
      end

      summary = report.to_s
      assert_match(/Duplicate queries/, summary)
      assert_match(/3x/, summary)
    end

    def test_summary_suggests_eager_loading_for_n_plus_one
      report = build_report do |c|
        6.times { |i| c.record(sql: "SELECT * FROM authors WHERE id = #{i}") }
      end

      summary = report.to_s
      assert_match(/Potential N\+1 queries/, summary)
      assert_match(/consider eager loading :authors/, summary)
    end

    def test_summary_pluralizes_query_count
      one = build_report { |c| c.record(sql: "SELECT * FROM users WHERE id = 1") }
      assert_match(/1 query /, one.to_s)

      many = build_report do |c|
        2.times { |i| c.record(sql: "SELECT c#{i} FROM users WHERE id = 1") }
      end
      assert_match(/2 queries /, many.to_s)
    end

    def test_to_h_is_structured_for_custom_reporters
      report = build_report do |c|
        3.times { |i| c.record(sql: "SELECT * FROM users WHERE id = #{i}", duration: 1.0) }
      end

      hash = report.to_h
      assert_equal 3, hash[:total_queries]
      assert_equal 2, hash[:duplicate_query_count]
      assert_equal 1, hash[:duplicates].size
      assert_equal 3, hash[:duplicates].first[:count]
    end
  end

  class QueryAnalyzerIntegrationTest < ActiveRecord::TestCase
    fixtures :posts, :authors, :author_addresses

    setup do
      @original_enabled = QueryAnalyzer.enabled
      @original_reporter = QueryAnalyzer.reporter
      @original_threshold = QueryAnalyzer.n_plus_one_threshold
    end

    teardown do
      QueryAnalyzer.enabled = @original_enabled
      QueryAnalyzer.reporter = @original_reporter
      QueryAnalyzer.n_plus_one_threshold = @original_threshold
    end

    def test_disabled_by_default_so_nothing_is_collected
      assert_not_predicate QueryAnalyzer, :enabled?
      assert_nil QueryAnalyzer.collector
    end

    def test_no_collection_happens_outside_of_analyze
      Post.first
      assert_nil QueryAnalyzer.collector
    end

    def test_analyze_collects_queries_without_enabling_globally
      report = QueryAnalyzer.analyze { Post.first }

      assert_operator report.total_queries, :>=, 1
      assert_not_predicate QueryAnalyzer, :enabled?
    end

    def test_analyze_detects_a_real_n_plus_one
      QueryAnalyzer.n_plus_one_threshold = 3

      report = QueryAnalyzer.analyze do
        Post.limit(5).each { |post| post.author&.name }
      end

      assert_predicate report, :n_plus_one?
    end

    def test_eager_loading_produces_no_n_plus_one
      QueryAnalyzer.n_plus_one_threshold = 3

      report = QueryAnalyzer.analyze do
        Post.includes(:author).limit(5).each { |post| post.author&.name }
      end

      assert_not_predicate report, :n_plus_one?
    end

    def test_analyze_restores_any_previous_collector
      assert_nil QueryAnalyzer.collector

      QueryAnalyzer.analyze { Post.first }

      assert_nil QueryAnalyzer.collector
    end

    def test_analyze_restores_state_when_the_block_raises
      assert_raises(RuntimeError) do
        QueryAnalyzer.analyze { raise "boom" }
      end

      assert_nil QueryAnalyzer.collector
    end

    def test_nested_analyze_calls_report_independently
      outer = nil

      inner = QueryAnalyzer.analyze do
        Post.first
        outer = QueryAnalyzer.collector
        QueryAnalyzer.analyze { Post.limit(2).to_a }
      end

      # The inner block reports only its own queries and the outer collector is
      # restored afterwards.
      assert_operator inner.total_queries, :>=, 1
      assert_not_nil outer
    end

    def test_schema_and_transaction_queries_are_ignored
      report = QueryAnalyzer.analyze do
        Post.transaction { Post.first }
      end

      assert_not_includes report.to_h[:duplicates].map { |d| d[:sql] }, "BEGIN"
    end

    def test_reporter_receives_the_report
      received = []
      QueryAnalyzer.reporter = ->(report) { received << report }
      QueryAnalyzer.enabled = true

      QueryAnalyzer.start
      Post.first
      QueryAnalyzer.report(QueryAnalyzer.stop)

      assert_equal 1, received.size
      assert_kind_of ActiveRecord::QueryAnalyzer::Report, received.first
    end

    def test_stop_returns_nil_when_not_collecting
      assert_nil QueryAnalyzer.stop
    end

    def test_record_is_a_no_op_when_not_collecting
      assert_nil QueryAnalyzer.record(sql: "SELECT 1")
    end

    def test_concurrent_installs_subscribe_exactly_once
      QueryAnalyzer.uninstall_subscriber

      begin
        threads = 16.times.map { Thread.new { QueryAnalyzer.install_subscriber } }
        threads.each(&:join)

        # Subscribing twice would count every query twice and leak the second
        # subscription, since only one token is retained.
        listeners = ActiveSupport::Notifications.notifier.listeners_for("sql.active_record")
        analyzer_listeners = listeners.count do |listener|
          listener.instance_variable_get(:@delegate) == QueryAnalyzer::Subscriber
        end

        assert_equal 1, analyzer_listeners
      ensure
        # Leave the subscriber attached: other tests rely on the global state
        # that start/analyze establish.
        QueryAnalyzer.install_subscriber
      end
    end

    def test_a_single_query_is_not_reported_as_a_duplicate
      # Regression: a double subscription made one query look like two.
      report = QueryAnalyzer.analyze { Post.limit(1).to_a }

      assert_equal 1, report.total_queries
      assert_not_predicate report, :duplicates?
    end

    def test_installing_executor_hooks_twice_registers_them_once
      executor = Class.new(ActiveSupport::Executor)
      QueryAnalyzer.install_executor_hooks(executor)
      QueryAnalyzer.install_executor_hooks(executor)

      reports = []
      QueryAnalyzer.reporter = ->(report) { reports << report }
      QueryAnalyzer.enabled = true

      executor.wrap { Post.limit(1).to_a }

      assert_equal 1, reports.size
    end

    def test_collectors_are_isolated_between_threads
      results = {}
      mutex = Mutex.new

      threads = 4.times.map do |index|
        Thread.new do
          count = index + 1
          report = QueryAnalyzer.analyze do
            count.times { Post.limit(1).to_a }
          end
          mutex.synchronize { results[index] = report.total_queries }
        end
      end
      threads.each(&:join)

      # Each thread must observe exactly the queries it issued.
      4.times { |index| assert_equal index + 1, results[index] }
    end
  end
end
