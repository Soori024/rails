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
                  :duplicates, :n_plus_one_candidates, :slow_queries,
                  :ignored_queries

      def initialize(total_queries:, cached_queries:, total_duration:,
                     duplicates:, n_plus_one_candidates:, slow_queries: [],
                     ignored_queries: 0)
        @total_queries = total_queries
        @cached_queries = cached_queries
        @total_duration = total_duration
        @duplicates = duplicates
        @n_plus_one_candidates = n_plus_one_candidates
        @slow_queries = slow_queries
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

      def slow_queries?
        slow_queries.any?
      end

      # True when nothing worth reporting was found.
      def clean?
        !duplicates? && !n_plus_one? && !slow_queries?
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
          slow_queries: slow_queries.map { |stat|
            {
              sql: stat.normalized_sql,
              count: stat.count,
              max_duration_ms: stat.max_duration.round(2),
              average_duration_ms: stat.average_duration.round(2),
            }
          },
          ignored_queries: ignored_queries,
        }
      end

      # A multi-line, human-readable summary, or an empty string when no
      # queries were recorded. Use empty? to decide whether to log at all.
      def to_s
        return "" if empty?

        lines = [header]

        # Findings come before the query list and most severe first: an N+1 is
        # usually the cause of the duplicates reported below it, so it is the
        # thing worth reading first.
        lines.concat(n_plus_one_section) if n_plus_one?
        lines.concat(slow_query_section) if slow_queries?
        lines.concat(duplicate_section) if duplicates?

        if ignored_queries > 0
          lines << "  #{ignored_queries} further queries were not tracked " \
                   "(max_tracked_queries reached)"
        end

        lines.join("\n")
      end

      private
        MAX_SQL_LENGTH = 100

        def header
          unit = total_queries == 1 ? "query" : "queries"
          summary = +"[ActiveRecord::QueryAnalyzer] #{total_queries} #{unit}"
          summary << " (#{cached_queries} cached)" if cached_queries > 0
          summary << " in #{format_ms(total_duration)}"
          summary
        end

        def n_plus_one_section
          lines = ["  Potential N+1 queries:"]

          n_plus_one_candidates.each do |stat|
            lines << "    #{stat.count}x (#{format_ms(stat.total_duration)})  " \
                     "#{truncate(stat.normalized_sql)}"
            lines << if stat.table_name
              "      -> consider eager loading :#{stat.table_name}"
            else
              "      -> consider eager loading the association"
            end
          end

          lines
        end

        def slow_query_section
          threshold = QueryAnalyzer.slow_query_threshold
          lines = ["  Slow queries (over #{format_ms(threshold)}):"]

          slow_queries.each do |stat|
            timing = if stat.count > 1
              "#{stat.count}x, worst #{format_ms(stat.max_duration)}, " \
                "avg #{format_ms(stat.average_duration)}"
            else
              format_ms(stat.max_duration)
            end

            lines << "    #{timing}  #{truncate(stat.normalized_sql)}"
          end

          lines
        end

        def duplicate_section
          redundant = duplicate_query_count
          unit = redundant == 1 ? "query" : "queries"
          lines = ["  Duplicate queries (#{redundant} redundant #{unit}):"]

          duplicates.each do |stat|
            lines << "    #{stat.count}x (#{format_ms(stat.total_duration)})  " \
                     "#{truncate(stat.normalized_sql)}"
          end

          lines
        end

        # Sub-millisecond timings are common with a warm cache or SQLite, and
        # rounding them all to "0.0ms" would make the report useless for
        # comparing one shape against another.
        def format_ms(milliseconds)
          if milliseconds < 1
            "#{(milliseconds * 1000).round}us"
          else
            "#{milliseconds.round(1)}ms"
          end
        end

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
