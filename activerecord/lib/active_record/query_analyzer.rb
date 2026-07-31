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
  #     detect_duplicates: true,
  #     detect_n_plus_one: true,
  #     n_plus_one_threshold: 3,
  #   }
  #
  # == How it works
  #
  # * A Subscriber listens to +sql.active_record+ and feeds each query into a
  #   request-scoped Collector (isolated per thread/fiber).
  # * The Normalizer collapses literal values to placeholders so structurally
  #   identical queries share a fingerprint.
  # * The Collector aggregates fingerprints to count duplicates and flag
  #   repeated per-record lookups as potential N+1 issues.
  # * ExecutorHooks reset the collector at the start of each unit of work and,
  #   at the end, hand it to the Reporter which logs a summary.
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
        self.detect_duplicates   = options[:detect_duplicates]   if options.key?(:detect_duplicates)
        self.detect_n_plus_one   = options[:detect_n_plus_one]   if options.key?(:detect_n_plus_one)
        self.n_plus_one_threshold = options[:n_plus_one_threshold] if options.key?(:n_plus_one_threshold)
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

      # Runs +block+ with the analyzer temporarily enabled and returns the
      # Collector holding the metrics gathered during the block. Handy for
      # tests and one-off profiling:
      #
      #   collector = ActiveRecord::QueryAnalyzer.analyze do
      #     User.all.each { |u| u.account }
      #   end
      #   collector.potential_n_plus_ones # => [...]
      def analyze
        was_enabled = @enabled
        subscribed = Subscriber.subscribed?
        self.enabled = true
        Subscriber.subscribe
        Collector.reset
        yield
        Collector.current_without_create || Collector.current
      ensure
        self.enabled = was_enabled
        Subscriber.unsubscribe unless subscribed
      end

      # Resets configuration to defaults. Used by tests.
      def reset_configuration!
        @enabled = nil
        @detect_duplicates = nil
        @detect_n_plus_one = nil
        @n_plus_one_threshold = nil
        @logger = nil
      end
    end
  end
end
