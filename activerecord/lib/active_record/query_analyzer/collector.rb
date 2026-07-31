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
        attr_accessor :count, :total_duration, :cached_count

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
        end

        # Number of times this shape ran beyond the first -- the count that
        # actually represents redundant work.
        def duplicate_count
          count - 1
        end

        def duplicated?
          count > 1
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
      end

      # Records one executed query. +duration+ is in milliseconds.
      def record(sql:, name: nil, duration: 0.0, cached: false, binds: nil)
        normalized = SqlNormalizer.normalize(sql)
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

      # Query shapes that ran more than once, worst offender first.
      def duplicates
        return [] unless QueryAnalyzer.detect_duplicates

        @query_stats.values.select(&:duplicated?).sort_by { |stat| -stat.count }
      end

      def duplicate_query_count
        duplicates.sum(&:duplicate_count)
      end

      # Shapes that look like an N+1: the same parameterized query, against the
      # same table, repeated at least +n_plus_one_threshold+ times.
      #
      # Requiring a bind placeholder is what separates a genuine per-record
      # lookup from a legitimately repeated constant query (a `SELECT 1`
      # health check, or a repeated `SELECT * FROM settings LIMIT 1`), which
      # keeps the false-positive rate down.
      def n_plus_one_candidates
        return [] unless QueryAnalyzer.detect_n_plus_one

        threshold = QueryAnalyzer.n_plus_one_threshold

        @query_stats.values.select { |stat|
          next false unless stat.count >= threshold
          next false unless stat.normalized_sql.match?(/\ASELECT\b/i)

          # A truncated shape may have lost its only placeholder to the length
          # cap. Repeating an identical constant SELECT that long is not a
          # realistic pattern, so treat it as a candidate rather than drop a
          # genuine N+1 on a technicality.
          stat.normalized_sql.include?(SqlNormalizer::PLACEHOLDER) ||
            SqlNormalizer.truncated?(stat.normalized_sql)
        }.sort_by { |stat| -stat.count }
      end

      # A Report snapshot of everything gathered so far.
      def report
        Report.new(
          total_queries: total_queries,
          cached_queries: cached_queries,
          total_duration: total_duration,
          duplicates: duplicates,
          n_plus_one_candidates: n_plus_one_candidates,
          ignored_queries: ignored_queries,
        )
      end

      def reset
        @query_stats.clear
        @total_queries = 0
        @cached_queries = 0
        @total_duration = 0.0
        @ignored_queries = 0
      end
    end
  end
end
