# frozen_string_literal: true

require "active_record/query_analyzer/normalizer"
require "active_record/query_analyzer/collector"
require "active_record/query_analyzer/reporter"
require "active_record/query_analyzer/subscriber"
require "active_record/query_analyzer/executor_hooks"

module ActiveRecord
  # = Active Record \Query \Analyzer
  #
  # An *optional*, opt-in tool that observes the SQL Active Record executes
  # during a request (or a single test) and surfaces common performance
  # problems — duplicated queries and potential N+1 patterns — without changing
  # how queries run.
  #
  # It is disabled by default and, once enabled, is intended for the
  # +development+ and +test+ environments only. Nothing here touches the query
  # execution path: metrics are gathered from +sql.active_record+ instrumentation
  # and reported at the end of the request via the Rails executor.
  #
  # == Enabling
  #
  #   # config/environments/development.rb
  #   config.active_record.query_analyzer = true
  #
  # Fine-grained options:
  #
  #   config.active_record.query_analyzer_options = {
  #     detect_duplicates: true,      # report duplicate query templates
  #     detect_n_plus_one: true,      # report potential N+1 patterns
  #     n_plus_one_threshold: 3,      # repetitions before flagging an N+1
  #     slow_query_threshold_ms: 100, # flag queries >= 100ms (nil disables)
  #     max_queries: 5000,            # retention cap (bounds memory use)
  #   }
  #
  # Set +config.active_record.query_analyzer = :force+ to activate it outside
  # development and test (not recommended for production).
  #
  # == Usage
  #
  # Beyond the automatic end-of-request report, the analyzer can profile an
  # arbitrary block and return the metrics directly:
  #
  #   collector = ActiveRecord::QueryAnalyzer.analyze do
  #     Post.all.each { |post| post.author }   # classic N+1
  #   end
  #
  #   collector.total_count           # => 11
  #   collector.duplicates            # => [{ fingerprint:, count:, ... }]
  #   collector.potential_n_plus_ones # => [{ table: "authors", count: 10, ... }]
  #
  # This is safe to call inside a live request: the surrounding request's
  # metrics are preserved and the block's queries are isolated.
  #
  # == Example report
  #
  # At the end of a request or test, a summary like the following is logged:
  #
  #   [QueryAnalyzer] Summary
  #     Total queries: 11 (0 cached)
  #     Duplicate queries: 10
  #     Duplicated templates:
  #       10x  SELECT "authors".* FROM "authors" WHERE "authors"."id" = ?
  #     Potential N+1 queries:
  #       10x on `authors` — consider eager loading (e.g. `includes(:authors)`)
  #         SELECT "authors".* FROM "authors" WHERE "authors"."id" = ?
  #
  # == Architecture
  #
  # The analyzer is a set of small, single-responsibility collaborators so that
  # additional detectors or reporters can be added without touching query
  # execution:
  #
  # * Normalizer — turns a raw SQL string into a stable fingerprint by
  #   collapsing literals, bind placeholders and variable-length +IN+ lists.
  #   Regexp based (no SQL parser) so it stays cheap on the hot path and behaves
  #   uniformly across PostgreSQL, MySQL and SQLite.
  # * Collector — a request-scoped, thread/fiber-isolated accumulator (stored in
  #   ActiveSupport::IsolatedExecutionState) that records each query and derives
  #   duplicate and N+1 diagnostics. Retention is capped by +max_queries+.
  # * Subscriber — attaches to +sql.active_record+ using the event-object
  #   subscription form (so the measured +duration+ is available) and feeds the
  #   current Collector. It never raises into query execution.
  # * Reporter — renders a Collector's metrics into a developer-friendly summary
  #   and logs it.
  # * ExecutorHooks — reset the collector when a unit of work begins and emit the
  #   report when it completes, mirroring how ActiveRecord::QueryCache integrates
  #   with the Rails executor.
  module QueryAnalyzer
    class << self
      # Whether the analyzer is active. Disabled by default.
      attr_writer :enabled

      # Detect duplicate query templates. Defaults to +true+.
      attr_writer :detect_duplicates

      # Detect potential N+1 query patterns. Defaults to +true+.
      attr_writer :detect_n_plus_one

      # Number of repetitions of the same parameterized query against a table
      # before it is flagged as a potential N+1. Defaults to +3+.
      attr_writer :n_plus_one_threshold

      # Default threshold used when none is configured.
      DEFAULT_N_PLUS_ONE_THRESHOLD = 3

      def n_plus_one_threshold
        @n_plus_one_threshold || DEFAULT_N_PLUS_ONE_THRESHOLD
      end

      # Maximum number of queries retained per unit of work. Bounds the
      # analyzer's own memory footprint; beyond this queries are still counted
      # but not stored for pattern analysis. Defaults to +5000+.
      attr_writer :max_queries

      # Default retention cap used when none is configured.
      DEFAULT_MAX_QUERIES = 5000

      def max_queries
        @max_queries || DEFAULT_MAX_QUERIES
      end

      # Queries whose measured execution time (in milliseconds) meets or exceeds
      # this threshold are flagged as slow in the report. Set to +nil+ (the
      # default) to disable slow-query monitoring.
      attr_accessor :slow_query_threshold_ms

      def monitor_slow_queries?
        !@slow_query_threshold_ms.nil?
      end

      # Logger used for reporting. Falls back to ActiveRecord::Base.logger.
      attr_writer :logger

      def enabled?
        @enabled.nil? ? false : @enabled
      end

      def detect_duplicates?
        @detect_duplicates.nil? ? true : @detect_duplicates
      end

      def detect_n_plus_one?
        @detect_n_plus_one.nil? ? true : @detect_n_plus_one
      end

      def logger
        @logger || (defined?(ActiveRecord::Base) ? ActiveRecord::Base.logger : nil)
      end

      # Applies a hash of options (as accepted by
      # +config.active_record.query_analyzer_options+).
      def configure(options = {})
        options = options || {}
        self.detect_duplicates    = options[:detect_duplicates]    if options.key?(:detect_duplicates)
        self.detect_n_plus_one    = options[:detect_n_plus_one]    if options.key?(:detect_n_plus_one)
        self.n_plus_one_threshold = options[:n_plus_one_threshold] if options.key?(:n_plus_one_threshold)
        self.max_queries          = options[:max_queries]          if options.key?(:max_queries)
        self.slow_query_threshold_ms = options[:slow_query_threshold_ms] if options.key?(:slow_query_threshold_ms)
        self
      end

      # Wires up the analyzer: subscribes to instrumentation and installs the
      # request-lifecycle executor hooks. Safe to call more than once.
      def install(executor = ActiveSupport::Executor)
        Subscriber.subscribe
        ExecutorHooks.install(executor)
        self
      end

      # Tears everything down. Primarily used by tests.
      def uninstall
        Subscriber.unsubscribe
        Collector.reset
        self
      end

      # Runs +block+ with the analyzer temporarily enabled and returns a
      # Collector holding *only* the metrics gathered during the block. Handy for
      # tests and one-off profiling:
      #
      #   collector = ActiveRecord::QueryAnalyzer.analyze do
      #     User.all.each { |u| u.account }
      #   end
      #   collector.potential_n_plus_ones # => [...]
      #
      # It is safe to call inside a live request: any collector the surrounding
      # request is already accumulating is saved and restored, so the block's
      # queries are isolated and never merged into (or wiped from) the outer
      # request's report.
      def analyze
        was_enabled = @enabled
        was_subscribed = Subscriber.subscribed?
        previous_collector = Collector.current_without_create

        self.enabled = true
        Subscriber.subscribe
        scoped_collector = Collector.swap(Collector.new)

        yield
        scoped_collector
      ensure
        Collector.swap(previous_collector)
        self.enabled = was_enabled
        Subscriber.unsubscribe unless was_subscribed
      end

      # Resets configuration to defaults. Used by tests.
      def reset_configuration!
        @enabled = nil
        @detect_duplicates = nil
        @detect_n_plus_one = nil
        @n_plus_one_threshold = nil
        @max_queries = nil
        @slow_query_threshold_ms = nil
        @logger = nil
      end
    end
  end
end
