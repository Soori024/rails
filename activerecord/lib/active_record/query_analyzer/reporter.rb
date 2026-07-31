# frozen_string_literal: true

module ActiveRecord
  module QueryAnalyzer
    # = Active Record Query Analyzer \Reporter
    #
    # Turns a Collector's aggregated metrics into a developer-friendly, human
    # readable summary and emits it through the configured logger at the end of
    # a request or test.
    #
    # Reporting is deliberately side-effect free with respect to the query
    # execution itself: it only reads the collected data and writes to a log.
    module Reporter
      class << self
        # Builds and logs the end-of-request/test summary for +collector+.
        # Does nothing when there is nothing to report.
        def report(collector, logger: QueryAnalyzer.logger)
          return unless collector&.any?
          return unless logger

          logger.info(build_message(collector))
        end

        # Returns the formatted multi-line report string. Exposed separately so
        # tests can assert on the content without a logger.
        def build_message(collector)
          summary = collector.summary
          lines = []
          lines << "[QueryAnalyzer] Summary"
          lines << "  Total queries: #{summary[:total_queries]} (#{summary[:cached_queries]} cached)"
          lines << "  Duplicate queries: #{summary[:duplicate_queries]}"

          if summary[:overflowed]
            lines << "  Note: query retention cap reached; only the first #{QueryAnalyzer.max_queries} queries were analyzed."
          end

          if summary[:duplicate_groups].any?
            lines << "  Duplicated templates:"
            summary[:duplicate_groups].each do |dup|
              lines << "    #{dup[:count]}x  #{truncate(dup[:sample_sql])}"
            end
          end

          if summary[:potential_n_plus_ones].any?
            lines << "  Potential N+1 queries:"
            summary[:potential_n_plus_ones].each do |issue|
              lines << "    #{issue[:count]}x on `#{issue[:table]}` — consider eager loading (e.g. `includes(:#{issue[:table]})`)"
              lines << "      #{truncate(issue[:sample_sql])}"
            end
          end

          lines.join("\n")
        end

        private
          def truncate(sql, length = 120)
            sql = sql.to_s.squeeze(" ").strip
            sql.length > length ? "#{sql[0, length]}…" : sql
          end
      end
    end
  end
end
