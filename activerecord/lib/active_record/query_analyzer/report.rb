# frozen_string_literal: true

module ActiveRecord
  module QueryAnalyzer
    # = Active Record Query Analyzer \Report
    #
    # An immutable snapshot of what the Collector observed during one unit of
    # execution. Reports are what the analyzer hands to the logger, and what
    # applications receive from QueryAnalyzer.analyze, so this is the public
    # surface of the feature -- it's kept free of the collector's internals so
    # custom reporters have something stable to build on.
    class Report # :nodoc:
      attr_reader :total_queries, :cached_queries, :total_duration,
                  :duplicates, :n_plus_one_candidates, :ignored_queries

      def initialize(total_queries:, cached_queries:, total_duration:,
                     duplicates:, n_plus_one_candidates:, ignored_queries: 0)
        @total_queries = total_queries
        @cached_queries = cached_queries
        @total_duration = total_duration
        @duplicates = duplicates
        @n_plus_one_candidates = n_plus_one_candidates
        @ignored_queries = ignored_queries
      end

      # Total number of redundant executions across all duplicated shapes.
      def duplicate_query_count
        duplicates.sum(&:duplicate_count)
      end

      def duplicates?
        duplicates.any?
      end

      def n_plus_one?
        n_plus_one_candidates.any?
      end

      # True when nothing worth reporting was found.
      def clean?
        !duplicates? && !n_plus_one?
      end

      def empty?
        total_queries.zero?
      end

      # A Hash representation, useful for structured logging or for shipping the
      # report to an external collector.
      def to_h
        {
          total_queries: total_queries,
          cached_queries: cached_queries,
          total_duration_ms: total_duration.round(2),
          duplicate_query_count: duplicate_query_count,
          duplicates: duplicates.map { |stat|
            {
              sql: stat.normalized_sql,
              count: stat.count,
              total_duration_ms: stat.total_duration.round(2),
            }
          },
          potential_n_plus_one: n_plus_one_candidates.map { |stat|
            {
              sql: stat.normalized_sql,
              table: stat.table_name,
              count: stat.count,
            }
          },
          ignored_queries: ignored_queries,
        }
      end

      # A multi-line, human-readable summary, or an empty string when no
      # queries were recorded. Use empty? to decide whether to log at all.
      def to_s
        return "" if empty?

        lines = []
        unit = total_queries == 1 ? "query" : "queries"
        lines << "[ActiveRecord::QueryAnalyzer] #{total_queries} #{unit} " \
                 "(#{cached_queries} cached) in #{total_duration.round(1)}ms"

        if duplicates?
          lines << "  Duplicate queries (#{duplicate_query_count} redundant):"
          duplicates.each do |stat|
            lines << "    #{stat.count}x  #{truncate(stat.normalized_sql)}"
          end
        end

        if n_plus_one?
          lines << "  Potential N+1 queries:"
          n_plus_one_candidates.each do |stat|
            suggestion = if stat.table_name
              " (consider eager loading :#{stat.table_name})"
            else
              " (consider eager loading)"
            end
            lines << "    #{stat.count}x  #{truncate(stat.normalized_sql)}#{suggestion}"
          end
        end

        if ignored_queries > 0
          lines << "  Note: #{ignored_queries} queries not tracked " \
                   "(max_tracked_queries reached)"
        end

        lines.join("\n")
      end

      private
        MAX_SQL_LENGTH = 120

        def truncate(sql)
          if sql.length > MAX_SQL_LENGTH
            "#{sql[0, MAX_SQL_LENGTH]}..."
          else
            sql
          end
        end
    end
  end
end
