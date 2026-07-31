# frozen_string_literal: true

module ActiveRecord
  module QueryAnalyzer
    # = Active Record Query Analyzer \Normalizer
    #
    # Normalizes SQL statements so that queries which are structurally
    # identical but differ only in their literal values collapse to the same
    # "fingerprint". This is what allows the analyzer to recognize that
    #
    #   SELECT * FROM "users" WHERE "users"."id" = 1
    #   SELECT * FROM "users" WHERE "users"."id" = 2
    #
    # are the *same* query template executed with different parameters, which
    # is the foundation for both duplicate and N+1 detection.
    #
    # The normalization is intentionally lightweight (regexp based) rather than
    # a full SQL parser: it must run on the hot path for every query and behave
    # consistently across the PostgreSQL, MySQL and SQLite adapters without
    # pulling in a database specific dependency.
    module Normalizer
      # Single-quoted string literal, honoring the SQL '' escape for an embedded
      # quote. Note: double-quoted identifiers (e.g. "users") are NOT literals in
      # standard SQL — they are quoted table/column names — so they are left
      # untouched on purpose.
      STRING_LITERAL = /'(?:[^']|'')*'/
      # Numeric literal, including sign, decimals and scientific notation. The
      # lookbehind/lookahead keep it from biting into identifiers or the digits
      # of already-substituted placeholders.
      NUMERIC_LITERAL = /(?<![\w."'?])[-+]?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?(?![\w."'])/
      # Collapses a list of placeholders of any arity, e.g. "IN (?, ?, ?)".
      IN_LIST = /\bIN\s*\(\s*\?(?:\s*,\s*\?)*\s*\)/i
      # Positional ($1) and named (:name) bind placeholders.
      BIND_PLACEHOLDER = /\$\d+|(?<!:):\w+/
      MULTIPLE_SPACES = /\s+/

      PLACEHOLDER = "?"

      class << self
        # Returns a normalized fingerprint for +sql+.
        #
        # The +binds+ are accepted for API symmetry and future use (e.g. typed
        # normalization) but the current implementation derives the fingerprint
        # purely from the SQL text, which keeps it adapter agnostic.
        def normalize(sql, _binds = nil)
          return sql if sql.nil? || sql.empty?

          normalized = sql.dup

          # Replace existing bind placeholders ($1, :name) with a canonical "?".
          normalized.gsub!(BIND_PLACEHOLDER, PLACEHOLDER)

          # Collapse literal values to placeholders. Strings first so that
          # digits inside a string literal are not matched as numbers.
          # NULL/TRUE/FALSE are intentionally left as-is: parameterized queries
          # never emit them as literals, and collapsing them would merge
          # semantically distinct templates (e.g. `IS NULL` vs `= ?`).
          normalized.gsub!(STRING_LITERAL, PLACEHOLDER)
          normalized.gsub!(NUMERIC_LITERAL, PLACEHOLDER)

          # Now that both binds and literals are "?", collapse "IN (?, ?, ?)" of
          # any arity to "IN (?)" so batches of varying size map to one template.
          normalized.gsub!(IN_LIST, "IN (#{PLACEHOLDER})")

          # Squish whitespace so formatting differences don't fork the template.
          normalized.gsub!(MULTIPLE_SPACES, " ")
          normalized.strip!

          normalized
        end

        # A stable, cheap-to-compare digest of the normalized SQL. Used as a
        # hash key when aggregating queries.
        def fingerprint(sql, binds = nil)
          normalize(sql, binds)
        end

        # Extracts the primary table name referenced by +sql+, if any. Used by
        # the N+1 heuristic to group repeated single-row lookups against the
        # same table. Returns +nil+ when no table can be confidently identified.
        def table_name(sql)
          return nil if sql.nil?

          if (match = sql.match(/\A\s*SELECT\b.*?\bFROM\s+("?[\w.]+"?|`[\w.]+`|\[[\w.]+\])/im))
            unquote(match[1])
          end
        end

        private
          def unquote(identifier)
            identifier.delete('"').delete("`").delete("[").delete("]")
          end
      end
    end
  end
end
