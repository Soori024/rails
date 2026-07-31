# frozen_string_literal: true

module ActiveRecord
  module QueryAnalyzer
    # = Active Record Query Analyzer \SQL \Normalizer
    #
    # Reduces a SQL statement to a stable "shape" by replacing literal values
    # with placeholders. Two queries that differ only in the values they
    # interpolate normalize to the same string, which is what makes duplicate
    # and N+1 detection possible.
    #
    #   SqlNormalizer.normalize(%{SELECT * FROM "users" WHERE "id" = 1})
    #   # => %{SELECT * FROM "users" WHERE "id" = ?}
    #
    #   SqlNormalizer.normalize(%{SELECT * FROM "users" WHERE "id" IN (1, 2, 3)})
    #   # => %{SELECT * FROM "users" WHERE "id" IN (?)}
    #
    # The normalizer is deliberately lexical rather than a full SQL parser. A
    # parser would need a per-adapter grammar, would be far slower, and would
    # still fall back to heuristics for adapter-specific syntax. Since the
    # output is only ever a grouping key for diagnostics -- never used to build
    # or execute SQL -- an approximate but fast and predictable normalization is
    # the right trade-off.
    module SqlNormalizer # :nodoc:
      extend self

      # A single scanner alternation applied left to right, so quotes and
      # comments are always recognized in each other's context.
      #
      # Successive substitutions are not equivalent to one pass. Stripping
      # comments before string literals deletes from a "--" *inside* a literal
      # to end of line, discarding the rest of the predicate and leaving an
      # unterminated quote -- which collapses unrelated queries onto the same
      # shape and invents duplicates that were never executed.
      #
      # The two structural branches are named so the regex engine reports which
      # one matched. Re-testing each token against a case chain would run
      # several more matches per token, and identifiers are the most common
      # token in a typical query.
      TOKENS = /
        (?<comment>
          \/\*.*?\*\/ |     # block comments, including QueryLogs tags
          --[^\n]*          # line comments
        )
        |
        (?<keep>
          "(?:[^"]|"")*" |  # double-quoted identifiers (PostgreSQL, SQLite)
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
        \$\d+ | @\w+ | :\w+           # binds: $1 (PostgreSQL), @name, :name
        |
        # Numeric literals, including a leading sign, decimals, scientific
        # notation and hex. The sign is part of the literal: without it
        # "= -5" and "= 5" would normalize to different shapes.
        (?<![\w"`])-?(?:0x\h+|\d+\.?\d*(?:[eE][+-]?\d+)?)\b
      /xm

      # A parenthesized run of placeholders, e.g. "(?, ?, ?)", left behind once
      # the individual literals have been replaced.
      PLACEHOLDER_LIST = /\(\s*\?(?:\s*,\s*\?)+\s*\)/
      # Runs of whitespace, including newlines from heredoc-built SQL.
      WHITESPACE = /\s+/

      PLACEHOLDER = "?"

      # Bounds the memory a single pathological statement can occupy for the
      # life of a request.
      #
      # Truncation is lossy: two queries differing only past the limit collapse
      # onto one shape, and a shape can lose its only placeholder. Callers
      # should treat a shape at exactly MAX_LENGTH as approximate -- see
      # truncated?.
      MAX_LENGTH = 4096

      # Returns the normalized form of +sql+, or an empty string when +sql+ is
      # nil or blank, so callers can rely on getting a String back.
      def normalize(sql)
        return "" if sql.nil?

        sql = sql.to_s
        return "" if sql.empty?

        # Structural tokens are matched only so a comment marker inside them
        # isn't mistaken for a comment; they are written back unchanged.
        # Comments collapse to a space, and everything else -- the literals and
        # binds -- becomes the placeholder.
        normalized = sql.gsub(TOKENS) do
          if Regexp.last_match(:keep)
            Regexp.last_match(:keep)
          elsif Regexp.last_match(:comment)
            " "
          else
            PLACEHOLDER
          end
        end

        # Collapse "IN (?, ?, ?)" to "IN (?)" so the same lookup against a
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

      # Matches the table a statement touches. Quoting differs per adapter --
      # "users", `users`, [users] or bare users -- so all four are accepted.
      TABLE_NAME = /
        \b(?:FROM|INSERT\s+INTO|UPDATE|JOIN)\s+
        (?:
          "(?<double>[^"]+)" |
          `(?<backtick>[^`]+)` |
          \[(?<bracket>[^\]]+)\] |
          (?<bare>[A-Za-z_][A-Za-z0-9_$.]*)
        )
      /xi

      # Returns the table name a query touches, or +nil+ when it can't be
      # determined. Used to attribute an N+1 to the model it loaded.
      def table_name(sql)
        return nil if sql.nil?

        match = TABLE_NAME.match(sql.to_s)
        return nil unless match

        name = match[:double] || match[:backtick] || match[:bracket] || match[:bare]
        return nil if name.nil?

        # Strip a schema or database prefix ("public.users" -> "users") so the
        # same table groups consistently however it was referenced.
        name = name.split(".").last
        name.empty? ? nil : name
      end
    end
  end
end
