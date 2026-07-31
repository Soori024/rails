# frozen_string_literal: true

module ActiveRecord
  module QueryAnalyzer
    # = Active Record Query Analyzer \Collector
    #
    # Accumulates the queries observed during a single unit of execution (a web
    # request, a job, or a test) and reports on the patterns it finds.
    #
    # A Collector instance is never shared between threads or fibers. Each unit
    # of execution gets its own, stored in ActiveSupport::IsolatedExecutionState,
    # so no locking is required on the hot path and metrics from concurrent
    # requests can't bleed into one another.
    #
    # Rather than retaining every statement, the collector aggregates into a
    # +QueryStat+ per normalized shape. Memory is therefore bounded by the number
    # of *distinct* query shapes, not by the number of queries executed -- an
    # important property for a request issuing thousands of queries, which is
    # exactly the pathological case this tool exists to surface.
    class Collector # :nodoc:
      # Aggregated totals for one normalized query shape.
      class QueryStat # :nodoc:
        attr_reader :normalized_sql, :table_name
        attr_accessor :count, :total_duration, :cached_count, :max_duration

        # Deliberately keeps no copy of the raw SQL. The normalized shape is
        # capped at SqlNormalizer::MAX_LENGTH, so retaining the original -- one
        # per distinct shape, up to max_tracked_queries -- would reintroduce the
        # unbounded memory use the cap exists to prevent.
        def initialize(normalized_sql, table_name)
          @normalized_sql = normalized_sql
          @table_name = table_name
          @count = 0
          @cached_count = 0
          @total_duration = 0.0
          @max_duration = 0.0
        end

        # Number of times this shape ran beyond the first -- the count that
        # actually represents redundant work.
        def duplicate_count
          count - 1
        end

        def duplicated?
          count > 1
        end

        def average_duration
          count.zero? ? 0.0 : total_duration / count
        end
      end

      attr_reader :query_stats

      def initialize
        @query_stats = {}
        @total_queries = 0
        @cached_queries = 0
        @total_duration = 0.0
        # Count of queries seen after max_tracked_queries was reached. They
        # still contribute to the totals but get no per-shape entry.
        @ignored_queries = 0
        # Memoizes normalization by raw SQL, see record.
        @normalized_cache = {}
      end

      # Records one executed query. +duration+ is in milliseconds.
      def record(sql:, name: nil, duration: 0.0, cached: false, binds: nil)
        # Normalizing is by far the most expensive part of recording a query,
        # and a request issues the same handful of statements over and over --
        # which is precisely the case this analyzer exists to detect. Caching
        # by raw SQL turns the repeat encounters into a hash lookup.
        #
        # The cache lives on the collector rather than in a global, so it is
        # confined to one unit of execution: no locking, and it is discarded
        # with the request instead of growing for the life of the process.
        normalized = @normalized_cache[sql]

        unless normalized
          normalized = SqlNormalizer.normalize(sql)
          # Bound the cache the same way the stats are bounded. Queries whose
          # values are interpolated rather than bound produce a distinct string
          # every time, which would otherwise grow this without limit.
          if @normalized_cache.size < QueryAnalyzer.max_tracked_queries
            @normalized_cache[sql] = normalized
          end
        end

        return if normalized.empty?

        @total_queries += 1
        @cached_queries += 1 if cached
        @total_duration += duration

        stat = @query_stats[normalized]

        unless stat
          # Guard against unbounded growth if an application generates an
          # effectively infinite number of distinct shapes (unnormalizable
          # generated SQL). Past the cap we keep counting totals but stop
          # tracking new shapes.
          if @query_stats.size >= QueryAnalyzer.max_tracked_queries
            @ignored_queries += 1
            return
          end

          stat = QueryStat.new(normalized, SqlNormalizer.table_name(sql))
          @query_stats[normalized] = stat
        end

        stat.count += 1
        stat.cached_count += 1 if cached
        stat.total_duration += duration
        # Track the worst single execution, not just the average: a shape that
        # is usually fast but occasionally slow is still worth surfacing.
        stat.max_duration = duration if duration > stat.max_duration

        nil
      end

      def total_queries
        @total_queries
      end

      def cached_queries
        @cached_queries
      end

      def total_duration
        @total_duration
      end

      def ignored_queries
        @ignored_queries
      end

      def empty?
        @total_queries.zero?
      end

      # The detection heuristics themselves live in Detectors, so that adding an
      # analysis doesn't mean growing this class.

      # Query shapes that ran more than once, worst offender first.
      def duplicates
        Detectors::Duplicates.call(@query_stats.values)
      end

      def duplicate_query_count
        duplicates.sum(&:duplicate_count)
      end

      # Query shapes that look like an N+1, most frequent first.
      def n_plus_one_candidates
        Detectors::NPlusOne.call(@query_stats.values)
      end

      # Query shapes whose slowest execution reached slow_query_threshold,
      # worst first.
      def slow_queries
        Detectors::SlowQueries.call(@query_stats.values)
      end

      # A Report snapshot of everything gathered so far.
      def report
        Report.new(
          total_queries: total_queries,
          cached_queries: cached_queries,
          total_duration: total_duration,
          duplicates: duplicates,
          n_plus_one_candidates: n_plus_one_candidates,
          slow_queries: slow_queries,
          ignored_queries: ignored_queries,
        )
      end

      def reset
        @query_stats.clear
        @normalized_cache.clear
        @total_queries = 0
        @cached_queries = 0
        @total_duration = 0.0
        @ignored_queries = 0
      end
    end
  end
end
