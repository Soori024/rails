# frozen_string_literal: true

module ActiveRecord
  module QueryAnalyzer
    # = Active Record Query Analyzer \SQL \Normalizer
    #
    # Reduces a SQL statement to a stable "shape" (or fingerprint) by replacing
    # literal values with placeholders. Two queries that differ only in the
    # values they interpolate normalize to the same string, which is what makes
    # duplicate and N+1 detection possible.
    #
    #   SqlNormalizer.normalize(%{SELECT * FROM "users" WHERE "id" = 1})
    #   # => %{SELECT * FROM "users" WHERE "id" = ?}
    #
    #   SqlNormalizer.normalize(%{SELECT * FROM "users" WHERE "id" IN (1, 2, 3)})
    #   # => %{SELECT * FROM "users" WHERE "id" IN (?)}
    #
    # The normalizer is deliberately lexical rather than a full SQL parser. A
    # real parser would need a per-adapter grammar, would be far slower, and
    # would still have to fall back to heuristics for adapter-specific syntax.
    # Since the output is only ever used as a grouping key for diagnostics --
    # never to build or execute SQL -- an approximate but fast and predictable
    # normalization is the right trade-off.
    module SqlNormalizer # :nodoc:
      extend self

      # A single scanner alternation, applied left to right, so that quotes and
      # comments are always recognized in each other's context. Order matters:
      # the string-literal branches come first so that a "--" or "/*" appearing
      # *inside* a literal is consumed as part of that literal rather than
      # treated as the start of a comment.
      #
      # Matching these separately with successive gsubs is not equivalent. A
      # comment-stripping pass that runs before string handling deletes from an
      # in-string "--" to end of line, silently discarding the rest of the
      # predicate and leaving an unterminated quote -- which makes unrelated
      # queries collapse onto the same shape and fabricates duplicate reports.
      TOKENS = /
        (?<comment>
          \/\*.*?\*\/ |     # block comments, including QueryLogs tags
          --[^\n]*          # line comments
        )
        |
        (?<keep>
          "(?:[^"]|"")*" |  # double-quoted identifiers
          `(?:[^`]|``)*` |  # backtick identifiers (MySQL)
          ::\w+          |  # casts; matched before the ":name" bind form
          @@\w+             # MySQL system variables, e.g. @@version
        )
        |
        # Everything below is data, and normalizes to the placeholder.
        '(?:[^'\\]|''|\\.)*'          # strings, with '' and MySQL \ escapes
        |
        \$(?<dq>\w*)\$.*?\$\k<dq>\$   # PostgreSQL dollar-quoted strings
        |
        \$\d+ | @\w+ | :\w+           # binds: $1, @name, :name
        |
        # Numeric literals, including a leading sign, decimals, scientific
        # notation and hex. The sign is part of the literal: without it
        # "= -5" and "= 5" would normalize to different shapes.
        (?<![\w"`])-?(?:0x\h+|\d+\.?\d*(?:[eE][+-]?\d+)?)\b
      /xm

      # A parenthesized list of placeholders, e.g. "(?, ?, ?)" left behind once
      # the individual literals have been replaced.
      PLACEHOLDER_LIST = /\(\s*\?(?:\s*,\s*\?)+\s*\)/
      # Runs of whitespace, including newlines from heredoc-built SQL.
      WHITESPACE = /\s+/

      PLACEHOLDER = "?"

      # Truncating keeps a pathological query (a huge IN list that survived
      # normalization, say) from being retained in memory for the whole request.
      #
      # Truncation is lossy by nature: two queries that differ only past the
      # limit collapse onto one shape. Callers should treat a shape at exactly
      # MAX_LENGTH as approximate -- see truncated?.
      MAX_LENGTH = 4096

      # Returns the normalized form of +sql+.
      #
      # Returns an empty string when +sql+ is +nil+ or blank so that callers can
      # rely on a String coming back.
      def normalize(sql)
        return "" if sql.nil?

        sql = sql.to_s

        return "" if sql.empty?

        # One left-to-right pass. Structural tokens (quoted identifiers, casts,
        # system variables) are matched only so that a comment marker inside
        # them isn't mistaken for a comment; they are then written back
        # unchanged. Comments collapse to a space and everything else -- the
        # literals and binds -- becomes the placeholder.
        #
        # The two structural branches are named in the pattern so the regex
        # engine reports which one matched. Re-testing each token against a
        # case chain would run several more matches per token, and identifiers
        # are the most common token in a typical query.
        normalized = sql.gsub(TOKENS) do
          if Regexp.last_match(:keep)
            Regexp.last_match(:keep)
          elsif Regexp.last_match(:comment)
            " "
          else
            PLACEHOLDER
          end
        end

        # Collapse "IN (?, ?, ?)" to "IN (?)" so that the same lookup against a
        # different number of ids is recognized as one shape.
        normalized.gsub!(PLACEHOLDER_LIST, "(#{PLACEHOLDER})")

        normalized.gsub!(WHITESPACE, " ")
        normalized.strip!

        normalized = normalized[0, MAX_LENGTH] if normalized.length > MAX_LENGTH

        normalized
      end

      # Whether +normalized_sql+ hit the length cap, and so may be an
      # approximation of the real query shape.
      def truncated?(normalized_sql)
        normalized_sql.length >= MAX_LENGTH
      end

      # Returns the table name a query touches, or +nil+ when it can't be
      # determined. Used to group potential N+1 queries by the model they load.
      #
      # Quoting styles differ per adapter -- "users" (PostgreSQL, SQLite),
      # `users` (MySQL) or bare users -- so all three are accepted.
      TABLE_NAME = /
        \b(?:FROM|INSERT\s+INTO|UPDATE|JOIN)\s+
        (?:
          "(?<double>[^"]+)" |
          `(?<backtick>[^`]+)` |
          \[(?<bracket>[^\]]+)\] |
          (?<bare>[A-Za-z_][A-Za-z0-9_$.]*)
        )
      /xi

      def table_name(sql)
        return nil if sql.nil?

        match = TABLE_NAME.match(sql.to_s)
        return nil unless match

        name = match[:double] || match[:backtick] || match[:bracket] || match[:bare]
        return nil if name.nil?

        # Strip a schema/database prefix ("public.users" -> "users") so the same
        # table is grouped consistently however it was referenced.
        name = name.split(".").last
        name.empty? ? nil : name
      end
    end
  end
end
