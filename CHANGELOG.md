# Changelog

## v0.2.0

- Added `FeoxDB.Term` to store Erlang terms as keys and values. It supports
  reads, writes, deletes, membership checks, and streaming. It splits large
  encoded values into records.
- Added `FeoxDB.max_key_size/0` and `FeoxDB.max_value_size/0`.
- Raised the minimum Elixir version to 1.15 for Rustler 0.38.
- Added property tests and tests for concurrent access to a shared store.
  The optional soak test accepts a duration in milliseconds through
  `FEOXDB_SOAK_DURATION_MS`.
- Added CI checks for formatting, compilation, tests, Dialyzer, and docs.
  Release automation builds native libraries and generates their checksums.
- Published the [design document](docs/PRD.md) and the
  [benchmark report](bench/REPORT.md). The benchmark harness measures
  random reads, writes, mixed reads and writes, and deletes.

## 0.1.0

- Added Elixir bindings for FeOxDB 0.6. The API supports in-memory and
  persistent stores, key lookup, inserts, deletes, range scans, key expiry,
  atomic updates, JSON patches, and store statistics.
- Mapped FeOxDB errors to Elixir atoms and added 25 API tests.
