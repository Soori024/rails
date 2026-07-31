# Query Analyzer: Architecture and Design

Design notes for the optional Active Record query analyzer, which reports
duplicate, N+1, and slow query patterns in development and test.

## 1. Active Record integration points

Four places in Active Record can observe query execution. Each was evaluated
against the same requirement: see every statement and its duration, without
changing how queries execute.

### 1.1 `sql.active_record` notifications

Emitted from `ConnectionAdapters::AbstractAdapter#log`
(`abstract_adapter.rb:1266`) for real queries, and from
`ConnectionAdapters::QueryCache` (`query_cache.rb:297`, `:319`) for cache hits.

The payload carries `sql`, `name`, `binds`, `type_casted_binds`, `cached`,
`async`, `connection`, `transaction`, `row_count`, and `affected_rows`.
`ActiveSupport::Notifications.monotonic_subscribe` supplies monotonic start and
finish times, which is what timing should be derived from — wall clock can jump.

Existing consumers: `RuntimeRegistry` (`runtime_registry.rb:67`),
`LogSubscriber`, `ExplainRegistry`, and `assert_queries_count` in
`testing/query_assertions.rb`. Instrumentation is the established way to watch
queries in this codebase.

### 1.2 `ActiveRecord.query_transformers`

Invoked in `ConnectionAdapters::QueryIntent` (`query_intent.rb:283`):

```ruby
ActiveRecord.query_transformers&.each do |transformer|
  sql = transformer.call(sql, adapter)
end
```

The return value *replaces* the SQL. This is how `QueryLogs` injects comments.
It is a mutation hook, not an observation hook, and it runs before execution so
it has no duration. Unsuitable.

### 1.3 Adapter subclassing or prepending

Wrapping `execute`/`exec_query` per adapter would give full control, but
requires separate code for each adapter, competes with anything else that
prepends those methods, and puts the analyzer directly in the execution path
where a bug becomes a broken query rather than a bad report.

### 1.4 Executor hooks

`ActiveSupport::Executor.register_hook` (`execution_wrapper.rb:58`) wraps each
unit of execution — a request, a job, a test. `QueryCache`,
`AsynchronousQueriesTracker`, and `ConnectionPool` all use it
(`railtie.rb:314-317`). This defines *when a request begins and ends*, which is
the boundary a per-request report needs. It is complementary to 1.1 rather than
an alternative: notifications say what ran, executor hooks say when to start and
report.

## 2. Approaches considered

### Approach A — Notification subscriber with per-request aggregation (chosen)

Subscribe to `sql.active_record`; keep a collector per unit of execution in
`ActiveSupport::IsolatedExecutionState`; start and report it from executor
hooks.

- Query execution is untouched; a bug produces a wrong report, not a wrong query.
- One implementation covers every adapter, including future ones.
- Uses the same mechanism as `RuntimeRegistry`, so it is familiar in review.
- Cost: a subscriber runs on every query while enabled. Mitigated by attaching
  the subscriber only when enabled, so a disabled analyzer costs nothing beyond
  a boolean check at boot.

### Approach B — Adapter instrumentation via prepended modules

Prepend a module to each adapter's execution methods.

- More payload access than the notification exposes, and no dependency on the
  notification remaining stable.
- Per-adapter code for PostgreSQL, MySQL, Trilogy, SQLite, plus anything
  third-party — the analyzer would silently miss unsupported adapters.
- Sits in the execution path, where a failure breaks the application rather than
  the diagnostics.
- Fragile against other libraries prepending the same methods.

**Why A.** The decisive factor is blast radius. This is a development tool whose
worst outcome should be a misleading report, never a failed query. B also fails
the "supports all officially approved adapters" requirement without per-adapter
work.

### Retaining statements vs. aggregating

A second decision, independent of the above: keep every observed statement, or
fold each into a per-shape counter.

Retaining gives exact per-query detail and precise ordering, but memory grows
linearly with query count — and the pathological request this tool exists to
find is exactly the one issuing thousands of queries. Aggregating bounds memory
by the number of *distinct shapes*, which is small even in a bad request. Chosen:
aggregate, with a `max_tracked_queries` cap as a backstop against SQL that
resists normalization.

## 3. Component architecture

```
sql.active_record ──> Subscriber ──> QueryAnalyzer.record
                                          │
                                          v
                                     Collector  (one per unit of execution,
                                          │      held in IsolatedExecutionState)
                        ┌─────────────────┼──────────────────┐
                        v                 v                  v
                  SqlNormalizer      QueryStat map      Detectors
                  (shape key)        (aggregates)       (Duplicates,
                                          │              NPlusOne,
                                          v              SlowQueries)
                                       Report ──> logger or custom reporter
                                          ^
Executor hooks ───────────────────────────┘  (start on run, report on complete)
```

| Component | Responsibility |
| --- | --- |
| `QueryAnalyzer` | Configuration, subscription, per-request lifecycle, public API |
| `SqlNormalizer` | Reduce a statement to a stable shape; extract table name |
| `Collector` | Aggregate per shape for one unit of execution |
| `Detectors` | Stateless heuristics over the collected stats |
| `Report` | Immutable snapshot; human-readable and structured output |

### Design decisions

**Per-request state in `IsolatedExecutionState`.** Scoped per thread or fiber
depending on `ActiveSupport.isolation_level`. Because a collector is reachable
only from its own unit of execution, the recording path needs no locking, and
concurrent requests cannot corrupt each other's metrics.

**Normalization is lexical, not a parser.** A real parser needs a per-adapter
grammar and is far slower. The output is only ever a grouping key for
diagnostics — never used to build or execute SQL — so an approximate but fast
and predictable normalization is the right trade-off.

**One left-to-right token pass.** Quotes and comments must be recognized in each
other's context. Successive substitutions are *not* equivalent: stripping
comments before string literals deletes from a `--` inside a literal to end of
line, discarding the rest of the predicate and collapsing unrelated queries onto
one shape.

**N+1 requires a repeated parameterized SELECT.** Demanding a bind placeholder
distinguishes a per-record lookup from a legitimately repeated constant query,
which is what keeps false positives down.

**Slow queries compare the worst execution, not the average.** A shape that is
usually fast but occasionally slow still matters. Cached queries are excluded,
since a cache hit does no database work.

**Disabled by default, and dev/test oriented.** The subscriber attaches only
when enabled. Enabling it outside development or test logs a warning.
