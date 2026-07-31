# frozen_string_literal: true

require "cases/helper"

module ActiveRecord
  # Regression tests: each locks in a specific bug that was found and fixed
  # during development so it cannot silently return. Named by the defect.
  class QueryAnalyzerRegressionTest < ActiveRecord::TestCase
    Normalizer = ActiveRecord::QueryAnalyzer::Normalizer
    Collector  = ActiveRecord::QueryAnalyzer::Collector
    Subscriber = ActiveRecord::QueryAnalyzer::Subscriber

    def setup
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

    # Bug: duration was read from `payload[:duration_ms]`, a key the raw
    # sql.active_record payload never sets, so every duration was nil. Fixed by
    # subscribing with the arity-1 event form and reading `event.duration`.
    test "regression: duration is derived from the event, never nil for timed queries" do
      collector = QueryAnalyzer.analyze do
        ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT 1", name: "SQL") do
          sleep 0.005
        end
      end

      duration = collector.queries.first.duration_ms
      assert_not_nil duration
      assert_operator duration, :>=, 1.0
    end

    # Bug: scientific-notation literals were not normalized (the exponent letter
    # broke the numeric regexp), so 1.5e10 and 1.5e11 forked into distinct
    # fingerprints and duplicates/N+1s were undercounted.
    test "regression: scientific notation normalizes to one fingerprint" do
      assert_equal Normalizer.normalize("SELECT * FROM t WHERE x = 1.5e10"),
                   Normalizer.normalize("SELECT * FROM t WHERE x = 1.5e11")
    end

    # Bug: `analyze` called Collector.reset, wiping a surrounding request's
    # collector and merging the block's queries into it. Fixed with save/restore.
    test "regression: analyze does not corrupt a surrounding request's collector" do
      QueryAnalyzer.install
      outer = Collector.current
      outer.record(sql: "SELECT * FROM outer WHERE id = 1", duration_ms: 0.1)

      QueryAnalyzer.analyze do
        ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT * FROM inner WHERE id = 1", name: "SQL")
      end

      assert_same outer, Collector.current_without_create
      assert_equal 1, outer.total_count
    end

    # Bug: the one-shot warning latch (@warned) never reset, suppressing all
    # future warnings process-wide; and the mutex-block `return` leaked, still
    # logging when already warned. Fixed to re-arm per unit of work.
    test "regression: warning latch re-arms after reset_warnings" do
      warnings = []
      fake_logger = Class.new do
        def initialize(sink) = @sink = sink
        def warn(msg) = @sink << msg
      end.new(warnings)
      QueryAnalyzer.logger = fake_logger

      Subscriber.reset_warnings
      3.times { Subscriber.send(:warn_once, RuntimeError.new("boom")) }
      assert_equal 1, warnings.size, "warn_once must fire exactly once per unit of work"

      Subscriber.reset_warnings
      Subscriber.send(:warn_once, RuntimeError.new("again"))
      assert_equal 2, warnings.size, "reset_warnings must re-arm the latch"
    end

    # Bug risk: PostgreSQL `::type` casts could be mangled by the named-bind
    # placeholder regexp. Lock in that casts survive normalization.
    test "regression: postgresql type casts are preserved" do
      assert_equal "SELECT id::text FROM t WHERE x = ?",
                   Normalizer.normalize("SELECT id::text FROM t WHERE x = 1")
    end

    # Bug: `duplicate_groups` was recomputed on every summary access; memoization
    # must return a stable result and still reflect newly recorded queries.
    test "regression: duplicate grouping stays correct after incremental records" do
      collector = Collector.new
      collector.record(sql: "SELECT * FROM t WHERE id = 1", duration_ms: 0.1)
      assert_empty collector.duplicates

      collector.record(sql: "SELECT * FROM t WHERE id = 2", duration_ms: 0.1)
      assert_equal 1, collector.duplicates.size
      assert_equal 2, collector.duplicates.first[:count]
    end
  end
end
