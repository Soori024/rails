# frozen_string_literal: true

module ActiveRecord
  module QueryAnalyzer
    # = Active Record Query Analyzer \Subscriber
    #
    # Bridges +sql.active_record+ ActiveSupport::Notifications events into the
    # request-scoped Collector. Attaching a subscriber (rather than patching the
    # adapter) means the analyzer observes every query without changing how any
    # query is executed — a hard requirement for backward compatibility.
    #
    # The subscription uses the single-argument (event object) form so that the
    # event's measured +duration+ is available. The raw +sql.active_record+
    # instrument payload does *not* carry a duration; it is derived from the
    # event's start/finish timestamps, which only the event object exposes.
    module Subscriber
      # Payload names that don't represent user queries and should be ignored
      # so they never count toward duplicate/N+1 metrics.
      IGNORED_NAMES = ["SCHEMA", "EXPLAIN", "TRANSACTION"].freeze

      # Guards mutation of the shared @subscription / @warned state below.
      MUTEX = Mutex.new

      class << self
        # Handles a single +sql.active_record+ event. Receives an
        # ActiveSupport::Notifications::Event (arity-1 subscription form) so that
        # +event.duration+ (in milliseconds) is available.
        def call(event)
          collector = Collector.current
          return unless collector

          payload = event.payload
          return if IGNORED_NAMES.include?(payload[:name])

          collector.record(
            sql: payload[:sql],
            duration_ms: event.duration,
            binds: payload[:binds],
            adapter: adapter_for(payload),
            cached: payload[:cached] || false,
          )
        rescue StandardError => error
          # The analyzer must never break query execution. Swallow and warn.
          warn_once(error)
        end

        # Subscribes to the notification stream if not already subscribed.
        # Idempotent and thread-safe so repeated railtie runs (e.g. in tests)
        # don't stack subscribers.
        def subscribe
          MUTEX.synchronize do
            @subscription ||= ActiveSupport::Notifications.subscribe("sql.active_record") do |event|
              call(event)
            end
          end
        end

        # Detaches the subscriber. Primarily used by tests.
        def unsubscribe
          MUTEX.synchronize do
            if @subscription
              ActiveSupport::Notifications.unsubscribe(@subscription)
              @subscription = nil
            end
          end
        end

        def subscribed?
          !@subscription.nil?
        end

        # Clears the one-shot warning latch so a fresh unit of work can warn
        # again. Called from the executor +run+ hook at the start of each request.
        def reset_warnings
          MUTEX.synchronize { @warned = false }
        end

        private
          def adapter_for(payload)
            connection = payload[:connection]
            connection&.adapter_name
          rescue StandardError
            nil
          end

          def warn_once(error)
            should_warn = MUTEX.synchronize do
              next false if @warned
              @warned = true
            end
            return unless should_warn
            QueryAnalyzer.logger&.warn("[QueryAnalyzer] disabled recording after error: #{error.class}: #{error.message}")
          end
      end
    end
  end
end
