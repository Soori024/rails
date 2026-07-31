# Add an optional Query Analyzer for Active Record

## Summary

This PR adds an **opt-in Query Analyzer** to Active Record. When enabled, it
observes every SQL statement Active Record executes, normalizes it, and reports
**duplicate queries** and **potential N+1 patterns** at the end of each request
or test — without changing how any query is executed.

It is **disabled by default** for complete backward compatibility, and when
enabled it activates only in the `development` and `test` environments (unless
explicitly forced). Query collection is request-scoped and isolated per
thread/fiber, so metrics never leak across concurrent requests.

## Motivation

Duplicate queries and N+1 access patterns are among the most common performance
problems in Rails apps, and they usually surface only in production. Existing
tooling either lives in third-party gems (bullet, prosopite) or requires reading
raw logs. This provides a lightweight, first-party, framework-integrated way to
catch these issues early — during development and in the test suite.

## What it adds

* **Query collection** — captures each `sql.active_record` event (SQL, measured
  duration, binds, adapter, cache status).
* **SQL normalization** — collapses literals, bind placeholders, and
  variable-length `IN (...)` lists into a stable fingerprint so structurally
  identical queries group together, consistently across PostgreSQL, MySQL and
  SQLite.
* **Duplicate detection** — counts repeated query templates within a unit of work.
* **N+1 detection** — flags the same parameterized query repeated against one
  table beyond a configurable threshold, with an eager-loading suggestion.
* **Slow-query monitoring** — flags queries whose measured duration meets or
  exceeds a configurable threshold (opt-in, off by default).
* **Summary reporting** — a developer-friendly end-of-request/test log summary.
* **Configuration** — Rails config options, disabled by default.

## Usage

```ruby
# config/environments/development.rb
config.active_record.query_analyzer = true
config.active_record.query_analyzer_options = {
  detect_duplicates: true,      # report duplicate query templates
  detect_n_plus_one: true,      # report potential N+1 patterns
  n_plus_one_threshold: 3,      # repetitions before flagging an N+1
  slow_query_threshold_ms: 100, # flag queries >= 100ms (nil disables)
  max_queries: 5000,            # retention cap (bounds memory use)
}
```

It can also profile an arbitrary block directly:

```ruby
collector = ActiveRecord::QueryAnalyzer.analyze do
  Post.all.each { |post| post.author }   # classic N+1
end

collector.total_count           # => 11
collector.potential_n_plus_ones # => [{ table: "authors", count: 10, ... }]
```

Example logged report:

```
[QueryAnalyzer] Summary
  Total queries: 11 (0 cached)
  Duplicate queries: 10
  Duplicated templates:
    10x  SELECT "authors".* FROM "authors" WHERE "authors"."id" = ?
  Potential N+1 queries:
    10x on `authors` — consider eager loading (e.g. `includes(:authors)`)
      SELECT "authors".* FROM "authors" WHERE "authors"."id" = ?
```

## Implementation details

The feature is a set of small, single-responsibility collaborators under
`ActiveRecord::QueryAnalyzer`:

| Component | Responsibility |
| --- | --- |
| `Normalizer` | Regexp-based SQL → fingerprint (no SQL parser; cheap on the hot path). |
| `Collector` | Request-scoped, thread/fiber-isolated accumulation + duplicate/N+1 derivation. |
| `Subscriber` | Bridges `sql.active_record` events into the current `Collector`. |
| `Reporter` | Renders a `Collector`'s metrics into a readable summary and logs it. |
| `ExecutorHooks` | Reset at the start of a unit of work; report on completion. |

Wiring: an autoload in `active_record.rb`, config defaults + a dev/test-guarded
initializer in `railtie.rb`.

## Design decisions

* **Observe via instrumentation, never patch the adapter.** The `Subscriber`
  attaches to `ActiveSupport::Notifications` (`sql.active_record`). No
  `prepend`/`alias_method`/`execute` override exists anywhere in the feature, so
  query execution is provably unchanged.
* **Event-object subscription form.** The raw `sql.active_record` instrument
  payload does not carry a duration; it is derived from the event's
  start/finish timestamps. The subscriber uses the arity-1 (event) form so
  `event.duration` is available.
* **Executor hooks for lifecycle**, mirroring `ActiveRecord::QueryCache`. This
  gives correct behavior under concurrency and nested execution for free.
* **Per-thread/fiber isolation via `IsolatedExecutionState`**, so concurrent
  requests never share metrics.
* **Regexp normalization rather than a SQL parser** — it must run for every
  query, so it is kept lightweight and adapter-agnostic. `NULL`/`TRUE`/`FALSE`
  are intentionally *not* collapsed, to avoid merging semantically distinct
  templates (e.g. `IS NULL` vs `= ?`).
* **Bounded memory** — retention is capped (`max_queries`, default 5000);
  excess queries are counted but not stored.
* **Never raises into query execution** — the subscriber rescues and warns once
  per request if recording fails.

## Testing performed

* New unit/integration test file `activerecord/test/cases/query_analyzer_test.rb`
  — 29 tests covering: numeric/string/float/scientific-notation/negative literal
  normalization, escaped quotes, `IN`-list collapsing, table extraction,
  duplicate detection (+ toggle), N+1 detection (+ threshold, + toggle,
  + non-parameterized exclusion), disabled-by-default, configuration, per-thread
  isolation, the memory cap, real event-driven duration capture, reporting, and
  `analyze` isolation from a surrounding request.
* Result (via the Active Record test harness against SQLite):
  **29 runs, 70 assertions, 0 failures, 0 errors, 0 skips.**
* Regression canaries confirmed unaffected: `query_cache_test` (66),
  `log_subscriber_test` (50), `explain_test` (16), `relation_test` (59),
  `finder_test` (280) — all 0 failures.

## Known limitations

* **Heuristic N+1 detection.** It flags repeated parameterized single-table
  lookups; it can produce false positives (legitimately repeated lookups) and
  false negatives (N+1s masked by the query cache, or spread across tables). The
  threshold is configurable to tune sensitivity.
* **Regexp normalization is not a full SQL parser.** Exotic literals or vendor
  syntax may normalize imperfectly. This is a deliberate trade-off for hot-path
  performance and cross-adapter simplicity.
* **`table_name` picks the first `FROM` table**, so for complex JOIN/subquery
  SQL the reported table (used only for the eager-loading hint) may be the
  driving table rather than the associated one.
* **No formal benchmark suite** is included in this PR (see future work).

## Future enhancements

* Pluggable detectors/reporters (e.g. JSON output, a middleware panel).
* Association-aware N+1 detection using reflection to reduce false positives.
* Cross-database CI integration tests and a performance benchmark.

## Backward compatibility

Fully backward compatible: disabled by default, no changes to query execution,
no new required configuration. Enabling it is purely additive.
