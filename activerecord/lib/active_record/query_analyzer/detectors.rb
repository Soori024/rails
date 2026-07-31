# frozen_string_literal: true

module ActiveRecord
  module QueryAnalyzer
    # = Active Record Query Analyzer \Detectors
    #
    # Each detector examines the query shapes a Collector gathered and returns
    # the ones matching a particular pattern, worst first. They are stateless
    # and take the stats as an argument rather than reaching into the collector,
    # so a detector can be tested against a handful of hand-built stats with no
    # database involved.
    #
    # Keeping the heuristics here rather than on Collector means adding a new
    # analysis -- unindexed columns, oversized IN lists, writes inside a loop --
    # is a matter of adding a module beside these and calling it from
    # Collector#report, without touching the recording hot path.
    module Detectors # :nodoc:
      # Shapes executed more than once. The count beyond the first is redundant
      # work, whatever the cause.
      module Duplicates # :nodoc:
        extend self

        def call(stats)
          return [] unless QueryAnalyzer.detect_duplicates

          stats.select(&:duplicated?).sort_by { |stat| -stat.count }
        end
      end

      # Shapes that look like an N+1: the same parameterized SELECT repeated at
      # least +n_plus_one_threshold+ times.
      #
      # Requiring a bind placeholder is what separates a genuine per-record
      # lookup from a legitimately repeated constant query (a `SELECT 1` health
      # check, or a repeated `SELECT * FROM settings LIMIT 1`), which keeps the
      # false-positive rate down.
      module NPlusOne # :nodoc:
        extend self

        SELECT = /\ASELECT\b/i

        def call(stats)
          return [] unless QueryAnalyzer.detect_n_plus_one

          threshold = QueryAnalyzer.n_plus_one_threshold

          stats.select { |stat|
            next false unless stat.count >= threshold
            next false unless stat.normalized_sql.match?(SELECT)

            # A truncated shape may have lost its only placeholder to the length
            # cap. Repeating an identical constant SELECT that long is not a
            # realistic pattern, so treat it as a candidate rather than drop a
            # genuine N+1 on a technicality.
            stat.normalized_sql.include?(SqlNormalizer::PLACEHOLDER) ||
              SqlNormalizer.truncated?(stat.normalized_sql)
          }.sort_by { |stat| -stat.count }
        end
      end

      # Shapes whose slowest single execution reached +slow_query_threshold+.
      #
      # The worst execution is used rather than the average so that a shape
      # which is usually fast but occasionally slow still surfaces. Cached
      # queries are excluded: a query cache hit does no database work, so
      # reporting one as slow would point at the wrong thing.
      module SlowQueries # :nodoc:
        extend self

        def call(stats)
          threshold = QueryAnalyzer.slow_query_threshold
          return [] unless threshold

          stats.select { |stat|
            stat.max_duration >= threshold && stat.cached_count < stat.count
          }.sort_by { |stat| -stat.max_duration }
        end
      end
    end
  end
end
