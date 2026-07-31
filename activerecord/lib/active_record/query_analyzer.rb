# frozen_string_literal: true

require "active_record/query_analyzer/sql_normalizer"
require "active_record/query_analyzer/collector"
require "active_record/query_analyzer/report"

module ActiveRecord
  # = Active Record Query Analyzer
  #
  # An opt-in diagnostic that watches the SQL Active Record executes and reports
  # duplicate and potential N+1 query patterns. It is intended for development
  # and test environments.
  #
  # The analyzer is disabled by default. Enable it in an environment file:
  #
  #   config.active_record.query_analyzer = true
  #
  # With the analyzer on, a summary is logged at the end of each request:
  #
  #   [ActiveRecord::QueryAnalyzer] 27 queries (0 cached) in 14.2ms
  #     Duplicate queries (12 redundant):
  #       13x  SELECT * FROM "users" WHERE "users"."id" = ? LIMIT ?
  #     Potential N+1 queries:
  #       13x  SELECT * FROM "users" WHERE "users"."id" = ? LIMIT ? (consider eager loading :users)
  #
  # A block of code can also be analyzed directly, which is the most convenient
  # form inside tests:
  #
  #   report = ActiveRecord::QueryAnalyzer.analyze do
  #     Post.all.each { |post| post.author.name }
  #   end
  #
  #   report.n_plus_one?           # => true
  #   report.duplicate_query_count # => 4
  #
  # == Why this is opt-in
  #
  # Subscribing to +sql.active_record+ and normalizing every statement costs
  # real time on the hot path. Rather than pay that in production, the analyzer
  # attaches its subscriber only when enabled, so an application that leaves it
  # off carries no overhead beyond a single boolean check at boot.
  module QueryAnalyzer
    # Key under which the current unit of execution's Collector is stored.
    # Using IsolatedExecutionState keeps collectors per-thread (or per-fiber,
    # depending on ActiveSupport.isolation_level) so concurrent requests never
    # share or overwrite one another's metrics.
    STATE_KEY = :active_record_query_analyzer_collector

    class << self
      # Whether the analyzer is enabled. Defaults to +false+.
      attr_accessor :enabled

      # How many times a parameterized SELECT against the same table must repeat
      # before it is flagged as a potential N+1. Defaults to 5.
      attr_accessor :n_plus_one_threshold

      # Whether to report duplicate queries. Defaults to +true+.
      attr_accessor :detect_duplicates

      # Whether to report potential N+1 queries. Defaults to +true+.
      attr_accessor :detect_n_plus_one

      # Upper bound on distinct query shapes tracked per unit of execution.
      # Prevents unbounded memory growth. Defaults to 1000.
      attr_accessor :max_tracked_queries

      # A callable invoked with the Report at the end of each unit of execution.
      # Defaults to +nil+, in which case the report is written to the Active
      # Record logger.
      attr_accessor :reporter

      def enabled?
        !!@enabled
      end

      # The Collector for the current unit of execution, or +nil+ when the
      # analyzer isn't running.
      def collector
        ActiveSupport::IsolatedExecutionState[STATE_KEY]
      end

      # Starts collecting in the current unit of execution. Existing state is
      # replaced, so a fresh request never inherits a previous one's counts.
      #
      # Attaching the subscriber here rather than only at boot means a caller
      # that drives the analyzer directly -- including the executor hooks --
      # collects queries instead of silently reporting none.
      def start
        install_subscriber
        ActiveSupport::IsolatedExecutionState[STATE_KEY] = Collector.new
      end

      # Stops collecting and returns the final Report, or +nil+ if the analyzer
      # wasn't collecting.
      def stop
        current = collector
        return nil unless current

        ActiveSupport::IsolatedExecutionState.delete(STATE_KEY)
        current.report
      end

      # Records a query against the current collector. A no-op when the analyzer
      # isn't collecting, which is what makes it safe to call unconditionally
      # from the notification subscriber.
      def record(sql:, name: nil, duration: 0.0, cached: false, binds: nil)
        current = collector
        return unless current

        current.record(
          sql: sql, name: name, duration: duration, cached: cached, binds: binds
        )
      end

      # Analyzes the queries executed inside the block and returns a Report.
      #
      #   report = ActiveRecord::QueryAnalyzer.analyze do
      #     User.first
      #   end
      #   report.total_queries # => 1
      #
      # Works whether or not the analyzer is globally enabled, so tests can
      # assert on query patterns without turning it on for the whole suite. Any
      # collector already in progress is restored afterwards.
      def analyze
        previous = collector
        # start attaches the subscriber, so analyze works with the analyzer
        # globally disabled -- the common case in a test suite.
        start

        begin
          yield
          collector.report
        ensure
          if previous
            ActiveSupport::IsolatedExecutionState[STATE_KEY] = previous
          else
            # Delete rather than assign nil, so a thread that merely called
            # analyze once isn't left holding a permanent entry.
            ActiveSupport::IsolatedExecutionState.delete(STATE_KEY)
          end
        end
      end

      # Emits +report+ through the configured reporter, or to the logger.
      def report(report)
        return if report.nil? || report.empty?
        return if report.clean? && !reporter

        if reporter
          reporter.call(report)
        elsif (logger = ActiveRecord::Base.logger)
          logger.warn(report.to_s)
        end
      end

      # Subscribes to +sql.active_record+. Called from the Railtie when the
      # analyzer is enabled; calling it more than once is a no-op so that a
      # reloaded application doesn't double-count every query.
      def install_subscriber
        # Lock-free fast path: once subscribed, @subscriber never goes back to
        # nil except through uninstall_subscriber, so the common case avoids
        # taking the mutex on every analyze call.
        return if @subscriber

        # analyze calls this on every invocation, so two threads can reach an
        # unguarded check-and-set at once. Subscribing twice would count every
        # query twice and leak the second subscription permanently, since only
        # one token can be held in @subscriber.
        @install_lock.synchronize do
          return if @subscriber

          @subscriber = ActiveSupport::Notifications.monotonic_subscribe(
            "sql.active_record", Subscriber
          )
        end
      end

      def uninstall_subscriber # :nodoc:
        @install_lock.synchronize do
          return unless @subscriber

          ActiveSupport::Notifications.unsubscribe(@subscriber)
          @subscriber = nil
        end
      end

      # +register_hook+ does not deduplicate, and running the hooks twice would
      # discard the first collector mid-request, so guard against a second
      # registration on the same executor.
      def install_executor_hooks(executor = ActiveSupport::Executor) # :nodoc:
        @install_lock.synchronize do
          @hooked_executors ||= ObjectSpace::WeakMap.new
          return if @hooked_executors[executor]

          @hooked_executors[executor] = true
          executor.register_hook(ExecutorHooks)
        end
      end
    end

    @install_lock = Mutex.new
    @subscriber = nil
    @hooked_executors = nil

    self.enabled = false
    self.n_plus_one_threshold = 5
    self.detect_duplicates = true
    self.detect_n_plus_one = true
    self.max_tracked_queries = 1000
    self.reporter = nil

    # Translates +sql.active_record+ notifications into Collector calls.
    #
    # Implemented as a module responding to +call+ rather than an
    # ActiveSupport::LogSubscriber so that it receives monotonic timings and
    # skips the event-object allocation the log subscriber path performs.
    module Subscriber # :nodoc:
      extend self

      # Bookkeeping statements that aren't application queries. Reporting them
      # would be noise, and schema queries in particular repeat by design.
      IGNORED_NAMES = ["SCHEMA", "EXPLAIN", "TRANSACTION", "CACHE"].freeze

      def call(name, start, finish, id, payload)
        return unless QueryAnalyzer.collector
        return if IGNORED_NAMES.include?(payload[:name])

        QueryAnalyzer.record(
          sql: payload[:sql],
          name: payload[:name],
          duration: (finish - start) * 1_000.0,
          cached: payload[:cached],
          binds: payload[:binds],
        )
      end
    end

    # Starts a collector when the executor wraps a unit of execution, and
    # reports when it completes. This is what scopes the analyzer to a single
    # request or job without the analyzer needing to know anything about Action
    # Pack or Active Job.
    module ExecutorHooks # :nodoc:
      extend self

      def run
        QueryAnalyzer.start if QueryAnalyzer.enabled?
      end

      def complete(_state)
        return unless QueryAnalyzer.enabled?

        QueryAnalyzer.report(QueryAnalyzer.stop)
      end
    end
  end
end
