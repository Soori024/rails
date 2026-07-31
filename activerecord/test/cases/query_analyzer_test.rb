# frozen_string_literal: true

require "cases/helper"

module ActiveRecord
  class QueryAnalyzerTest < ActiveRecord::TestCase
    Normalizer = ActiveRecord::QueryAnalyzer::Normalizer
    Collector  = ActiveRecord::QueryAnalyzer::Collector
    Reporter   = ActiveRecord::QueryAnalyzer::Reporter
    Subscriber = ActiveRecord::QueryAnalyzer::Subscriber

    def setup
      # AR's own suite has no executor to reset state between tests.
      ActiveSupport::ExecutionContext.clear
      Collector.reset
      QueryAnalyzer.reset_configuration!
      QueryAnalyzer.enabled = true
    end

    def teardown
      QueryAnalyzer.uninstall
      QueryAnalyzer.reset_configuration!
      Collector.reset
    end

    # --- Normalization -------------------------------------------------------

    test "normalizes numeric literals to placeholders" do
      a = Normalizer.normalize(%q{SELECT * FROM "users" WHERE "users"."id" = 1})
      b = Normalizer.normalize(%q{SELECT * FROM "users" WHERE "users"."id" = 42})
      assert_equal a, b
      assert_includes a, "?"
    end

    test "normalizes string literals to placeholders" do
      a = Normalizer.normalize(%q{SELECT * FROM users WHERE name = 'Alice'})
      b = Normalizer.normalize(%q{SELECT * FROM users WHERE name = 'Bob'})
      assert_equal a, b
    end

    test "normalizes bind placeholders across adapters" do
      pg     = Normalizer.normalize("SELECT * FROM t WHERE id = $1")
      named  = Normalizer.normalize("SELECT * FROM t WHERE id = :id")
      qmark  = Normalizer.normalize("SELECT * FROM t WHERE id = ?")
      assert_equal pg, qmark
      assert_equal named, qmark
    end

    test "collapses IN lists of varying arity to a single template" do
      a = Normalizer.normalize("SELECT * FROM t WHERE id IN (1, 2, 3)")
      b = Normalizer.normalize("SELECT * FROM t WHERE id IN (4, 5)")
      assert_equal a, b
    end

    test "normalizes floating point and scientific notation literals" do
      assert_equal Normalizer.normalize("SELECT * FROM t WHERE x = 1.25"),
                   Normalizer.normalize("SELECT * FROM t WHERE x = 9.99")
      assert_equal Normalizer.normalize("SELECT * FROM t WHERE x = 1.5e10"),
                   Normalizer.normalize("SELECT * FROM t WHERE x = 1.5e11")
    end

    test "normalizes negative numeric literals" do
      assert_equal Normalizer.normalize("SELECT * FROM t WHERE x = -5"),
                   Normalizer.normalize("SELECT * FROM t WHERE x = 7")
    end

    test "honors the SQL escaped quote inside string literals" do
      assert_equal Normalizer.normalize(%q{SELECT * FROM u WHERE name = 'O''Brien'}),
                   Normalizer.normalize(%q{SELECT * FROM u WHERE name = 'Smith'})
    end

    test "does not confuse digits inside strings with numeric literals" do
      normalized = Normalizer.normalize(%q{SELECT * FROM t WHERE name = 'user123'})
      assert_equal Normalizer.normalize(%q{SELECT * FROM t WHERE name = 'other'}), normalized
    end

    test "extracts the primary table name" do
      assert_equal "accounts", Normalizer.table_name(%q{SELECT * FROM "accounts" WHERE id = 1})
      assert_equal "posts", Normalizer.table_name("SELECT * FROM `posts`")
      assert_nil Normalizer.table_name("UPDATE t SET x = 1")
    end

    test "normalize is nil/empty safe" do
      assert_nil Normalizer.normalize(nil)
      assert_equal "", Normalizer.normalize("")
    end

    # --- Duplicate detection -------------------------------------------------

    test "detects duplicate query templates" do
      collector = Collector.new
      3.times { |i| collector.record(sql: %Q{SELECT * FROM "t" WHERE id = #{i}}, duration_ms: 0.1) }
      collector.record(sql: %q{SELECT * FROM "other"}, duration_ms: 0.1)

      dups = collector.duplicates
      assert_equal 1, dups.size
      assert_equal 3, dups.first[:count]
      assert_equal 4, collector.total_count
    end

    test "does not report a single query as a duplicate" do
      collector = Collector.new
      collector.record(sql: %q{SELECT * FROM "t" WHERE id = 1}, duration_ms: 0.1)
      assert_empty collector.duplicates
    end

    test "duplicate detection can be disabled" do
      QueryAnalyzer.detect_duplicates = false
      collector = Collector.new
      3.times { |i| collector.record(sql: %Q{SELECT * FROM "t" WHERE id = #{i}}, duration_ms: 0.1) }
      assert_empty collector.duplicates
    end

    # --- N+1 detection -------------------------------------------------------

    test "detects potential N+1 patterns" do
      collector = Collector.new
      4.times { |i| collector.record(sql: %Q{SELECT * FROM "accounts" WHERE "accounts"."id" = #{i}}, duration_ms: 0.1) }

      issues = collector.potential_n_plus_ones
      assert_equal 1, issues.size
      assert_equal "accounts", issues.first[:table]
      assert_equal 4, issues.first[:count]
    end

    test "N+1 respects the configured threshold" do
      QueryAnalyzer.n_plus_one_threshold = 10
      collector = Collector.new
      4.times { |i| collector.record(sql: %Q{SELECT * FROM "accounts" WHERE id = #{i}}, duration_ms: 0.1) }
      assert_empty collector.potential_n_plus_ones
    end

    test "N+1 detection can be disabled independently of duplicates" do
      QueryAnalyzer.detect_n_plus_one = false
      collector = Collector.new
      4.times { |i| collector.record(sql: %Q{SELECT * FROM "accounts" WHERE id = #{i}}, duration_ms: 0.1) }
      assert_empty collector.potential_n_plus_ones
      assert_not_empty collector.duplicates
    end

    test "N+1 detection ignores non-parameterized repeated statements" do
      collector = Collector.new
      4.times { collector.record(sql: %q{SELECT COUNT(*) FROM "accounts"}, duration_ms: 0.1) }
      # Repeated identical count is a duplicate, but has no bind placeholder so
      # it is not flagged as N+1.
      assert_not_empty collector.duplicates
      assert_empty collector.potential_n_plus_ones
    end

    # --- Configuration -------------------------------------------------------

    test "is disabled by default" do
      QueryAnalyzer.reset_configuration!
      assert_not QueryAnalyzer.enabled?
      assert_nil Collector.current
    end

    test "defaults detect_duplicates and detect_n_plus_one to true" do
      QueryAnalyzer.reset_configuration!
      assert QueryAnalyzer.detect_duplicates?
      assert QueryAnalyzer.detect_n_plus_one?
      assert_equal 3, QueryAnalyzer.n_plus_one_threshold
    end

    test "configure applies an options hash" do
      QueryAnalyzer.configure(detect_duplicates: false, n_plus_one_threshold: 7)
      assert_not QueryAnalyzer.detect_duplicates?
      assert_equal 7, QueryAnalyzer.n_plus_one_threshold
    end

    # --- Concurrency ---------------------------------------------------------

    test "collectors are isolated per thread" do
      main = Collector.current
      main.record(sql: "SELECT 1", duration_ms: 0.1)

      other_count = Thread.new { Collector.current.total_count }.value

      assert_equal 0, other_count
      assert_equal 1, main.total_count
    end

    test "reset clears the current collector" do
      Collector.current.record(sql: "SELECT 1", duration_ms: 0.1)
      Collector.reset
      assert_nil Collector.current_without_create
    end

    # --- Memory bounding -----------------------------------------------------

    test "caps retained queries at max_queries but keeps counting" do
      QueryAnalyzer.max_queries = 3
      collector = Collector.new
      10.times { |i| collector.record(sql: %Q{SELECT * FROM t WHERE id = #{i}}, duration_ms: 0.1) }

      assert collector.overflowed?
      assert_equal 3, collector.analyzed_count
      assert_equal 10, collector.total_count
    end

    # --- Reporting -----------------------------------------------------------

    test "reporter includes totals, duplicates and N+1 guidance" do
      collector = Collector.new
      4.times { |i| collector.record(sql: %Q{SELECT * FROM "accounts" WHERE id = #{i}}, duration_ms: 0.1) }

      message = Reporter.build_message(collector)
      assert_includes message, "Total queries: 4"
      assert_includes message, "Duplicate queries: 4"
      assert_includes message, "Potential N+1"
      assert_includes message, "eager loading"
    end

    test "reporter reports nothing for an empty collector" do
      logger = ActiveSupport::Logger.new(StringIO.new)
      logged = StringIO.new
      logger = ActiveSupport::Logger.new(logged)
      Reporter.report(Collector.new, logger: logger)
      assert_empty logged.string
    end

    # --- Subscriber / end to end (via instrumentation) -----------------------

    test "records the measured duration from the instrumentation event" do
      QueryAnalyzer.reset_configuration!
      collector = QueryAnalyzer.analyze do
        ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT 1", name: "SQL") do
          sleep 0.01
        end
      end

      assert_equal 1, collector.total_count
      duration = collector.queries.first.duration_ms
      assert_not_nil duration, "duration must be derived from the event, not the payload"
      assert_operator duration, :>=, 5.0
    end

    test "analyze captures queries emitted through instrumentation" do
      QueryAnalyzer.reset_configuration!
      collector = QueryAnalyzer.analyze do
        ActiveSupport::Notifications.instrument(
          "sql.active_record",
          sql: %q{SELECT * FROM "posts" WHERE id = 1}, name: "Post Load"
        )
        ActiveSupport::Notifications.instrument(
          "sql.active_record",
          sql: %q{SELECT * FROM "posts" WHERE id = 2}, name: "Post Load"
        )
      end

      assert_equal 2, collector.total_count
      assert_equal 1, collector.duplicates.size
      assert_not Subscriber.subscribed?, "analyze must leave no subscription behind"
    end

    test "analyze does not corrupt a surrounding request's collector" do
      QueryAnalyzer.reset_configuration!
      QueryAnalyzer.enabled = true
      QueryAnalyzer.install

      outer = Collector.current
      outer.record(sql: "SELECT * FROM outer WHERE id = 1", duration_ms: 0.1)

      inner = QueryAnalyzer.analyze do
        ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT * FROM inner WHERE id = 1", name: "SQL")
      end

      assert_equal 1, inner.total_count
      assert_same outer, Collector.current_without_create
      assert_equal 1, outer.total_count
    end

    test "subscriber ignores schema and transaction statements" do
      QueryAnalyzer.reset_configuration!
      collector = QueryAnalyzer.analyze do
        ActiveSupport::Notifications.instrument("sql.active_record", sql: "BEGIN", name: "TRANSACTION")
        ActiveSupport::Notifications.instrument("sql.active_record", sql: "SHOW TABLES", name: "SCHEMA")
        ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT 1", name: "SQL")
      end
      assert_equal 1, collector.total_count
    ensure
      QueryAnalyzer.uninstall
    end
  end
end
