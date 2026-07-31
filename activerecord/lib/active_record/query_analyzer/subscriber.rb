# frozen_string_literal: true

module ActiveRecord
  module QueryAnalyzer
    # = Active Record Query Analyzer \Subscriber
    #
    # Bridges +sql.active_record+ ActiveSupport::Notifications events into the
    # request-scoped Collector. Attaching a subscriber (rather than patching the
    # adapter) means the analyzer observes every query without changing how any
    # query is executed — a hard requirement for backward compatibility.
    module Subscriber
      # Payload names that don't represent user queries and should be ignored
      # so they never count toward duplicate/N+1 metrics.
      IGNORED_NAMES = ["SCHEMA", "EXPLAIN", "TRANSACTION"].freeze

      class << self
        # Handles a single +sql.active_record+ event. The signature matches the
        # block form of ActiveSupport::Notifications.subscribe, receiving the
        # parsed event's fields.
        def call(_name, _start, _finish, _id, payload)
          collector = Collector.current
          return unless collector

          return if IGNORED_NAMES.include?(payload[:name])

          collector.record(
            sql: payload[:sql],
            duration_ms: duration_for(payload),
            binds: payload[:binds],
            adapter: adapter_for(payload),
            cached: payload[:cached] || false,
          )
        rescue StandardError => error
          # The analyzer must never break query execution. Swallow and warn.
          warn_once(error)
        end

        # Subscribes to the notification stream if not already subscribed.
        # Idempotent so repeated railtie runs (e.g. in tests) don't stack
        # subscribers.
        def subscribe
          @subscription ||= ActiveSupport::Notifications.subscribe("sql.active_record", method(:call))
        end

        # Detaches the subscriber. Primarily used by tests.
        def unsubscribe
          if @subscription
            ActiveSupport::Notifications.unsubscribe(@subscription)
            @subscription = nil
          end
        end

        def subscribed?
          !@subscription.nil?
        end

        private
          def duration_for(payload)
            payload[:duration_ms] if payload.key?(:duration_ms)
          end

          def adapter_for(payload)
            connection = payload[:connection]
            connection&.adapter_name
          rescue StandardError
            nil
          end

          def warn_once(error)
            return if @warned
            @warned = true
            QueryAnalyzer.logger&.warn("[QueryAnalyzer] disabled recording after error: #{error.class}: #{error.message}")
          end
      end
    end
  end
end
