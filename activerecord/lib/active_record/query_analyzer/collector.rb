# frozen_string_literal: true

module ActiveRecord
  module QueryAnalyzer
    # = Active Record Query Analyzer \Collector
    #
    # Aggregates the queries observed during a single unit of work (an HTTP
    # request, a background job, or a single test) and derives diagnostics from
    # them: duplicate query counts and potential N+1 patterns.
    #
    # Instances are *request scoped* and stored in
    # ActiveSupport::IsolatedExecutionState, so every thread/fiber gets its own
    # collector and metrics never leak across concurrent requests.
    class Collector
      STORE_KEY = :active_record_query_analyzer_collector

      # A single recorded query occurrence.
      Query = Struct.new(:sql, :fingerprint, :duration_ms, :binds, :adapter, :cached, keyword_init: true)

      class << self
        # Returns the collector for the current execution context, creating one
        # on first access. Returns +nil+ when the analyzer is disabled so the
        # subscriber can cheaply short-circuit.
        def current
          return nil unless QueryAnalyzer.enabled?
          ActiveSupport::IsolatedExecutionState[STORE_KEY] ||= new
        end

        # Returns the current collector without creating one. Used by reporting
        # so we don't materialize an empty collector for idle contexts.
        def current_without_create
          ActiveSupport::IsolatedExecutionState[STORE_KEY]
        end

        # Clears the collector for the current execution context. Called at the
        # start of every request so metrics are never carried over.
        def reset
          ActiveSupport::IsolatedExecutionState[STORE_KEY] = nil
        end
      end

      attr_reader :queries

      def initialize
        @queries = []
      end

      # Records a single observed query. +binds+ is captured defensively (a
      # shallow copy of the values) to avoid retaining adapter internals.
      def record(sql:, duration_ms:, binds: nil, adapter: nil, cached: false)
        fingerprint = Normalizer.fingerprint(sql, binds)
        @queries << Query.new(
          sql: sql,
          fingerprint: fingerprint,
          duration_ms: duration_ms,
          binds: bind_values(binds),
          adapter: adapter,
          cached: cached,
        )
      end

      # Total number of queries recorded (including cached hits).
      def total_count
        @queries.size
      end

      # Groups of identical query templates executed more than once. Returns an
      # array of hashes: { fingerprint:, count:, sample_sql:, total_duration_ms: }.
      def duplicates
        return [] unless QueryAnalyzer.detect_duplicates?
        duplicate_groups
      end

      # Potential N+1 patterns: the same query template repeated at least
      # +threshold+ times against the same table. This heuristic favors low
      # false positives by only flagging repeated *parameterized* lookups,
      # which is the signature of a loop issuing one query per parent record.
      #
      # Returns an array of hashes:
      # { fingerprint:, table:, count:, sample_sql: }.
      def potential_n_plus_ones(threshold: QueryAnalyzer.n_plus_one_threshold)
        return [] unless QueryAnalyzer.detect_n_plus_one?

        # Group counting for N+1 is independent of the duplicate toggle, so
        # compute groups directly rather than reusing #duplicates.
        duplicate_groups.filter_map do |dup|
          next if dup[:count] < threshold

          table = Normalizer.table_name(dup[:sample_sql])
          next unless table
          # Only SELECTs against a single table with a bind placeholder look
          # like per-record lookups; bulk statements are excluded.
          next unless dup[:fingerprint].match?(/\ASELECT\b/i)
          next unless dup[:fingerprint].include?(Normalizer::PLACEHOLDER)

          {
            fingerprint: dup[:fingerprint],
            table: table,
            count: dup[:count],
            sample_sql: dup[:sample_sql],
          }
        end
      end

      # A plain-Ruby summary suitable for logging or assertions in tests.
      def summary
        {
          total_queries: total_count,
          duplicate_queries: duplicates.sum { |d| d[:count] },
          duplicate_groups: duplicates,
          potential_n_plus_ones: potential_n_plus_ones,
        }
      end

      # Whether anything worth reporting was observed.
      def any?
        @queries.any?
      end

      private
        # Groups queries by fingerprint and returns those seen more than once,
        # ordered by descending count. Independent of the +detect_duplicates+
        # toggle so N+1 detection can rely on it directly.
        def duplicate_groups
          grouped = Hash.new { |h, k| h[k] = [] }
          @queries.each { |q| grouped[q.fingerprint] << q }

          grouped.filter_map do |fingerprint, occurrences|
            next if occurrences.size < 2

            {
              fingerprint: fingerprint,
              count: occurrences.size,
              sample_sql: occurrences.first.sql,
              total_duration_ms: occurrences.sum { |q| q.duration_ms || 0.0 },
            }
          end.sort_by { |d| -d[:count] }
        end

        def bind_values(binds)
          return nil if binds.nil?
          Array(binds).map do |bind|
            bind.respond_to?(:value_for_database) ? safe_bind_value(bind) : bind
          end
        rescue StandardError
          nil
        end

        def safe_bind_value(bind)
          bind.value_for_database
        rescue StandardError
          bind.respond_to?(:value) ? bind.value : nil
        end
    end
  end
end
