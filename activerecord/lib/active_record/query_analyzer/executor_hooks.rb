# frozen_string_literal: true

module ActiveRecord
  module QueryAnalyzer
    # = Active Record Query Analyzer \ExecutorHooks
    #
    # Ties the analyzer's lifecycle to the Rails executor, which wraps every
    # request and job. +run+ fires at the start of a unit of work (clearing any
    # stale collector) and +complete+ fires at the end (emitting the report and
    # clearing state). This is the same mechanism ActiveRecord::QueryCache uses,
    # which guarantees correct behavior under concurrency and nested execution.
    module ExecutorHooks
      class << self
        # Called when a unit of work begins. Start from a clean slate so metrics
        # from a previous request on this thread never bleed in, and re-arm the
        # subscriber's one-shot error warning for this request.
        def run
          Collector.reset
          Subscriber.reset_warnings
        end

        # Called when a unit of work ends. Emit the summary, then clear.
        def complete(_state)
          collector = Collector.current_without_create
          Reporter.report(collector) if collector
        ensure
          Collector.reset
        end
      end

      def self.install(executor = ActiveSupport::Executor)
        executor.register_hook(self)
      end
    end
  end
end
