# Changelog

All notable changes to this project are documented in this file.

## Unreleased

### Milestones 3-7: tests, CI matrix, release automation, benchmarks

- Milestone 3 (property tests and concurrency tests): added
  `stream_data` property tests (`test/feox_db_property_test.exs`),
  concurrency tests hammering a single store from many processes at once
  (`test/feox_db_concurrency_test.exs`), and a soak test
  (`test/feox_db_soak_test.exs`, tagged `:soak` and excluded from the
  default `mix test` run) that runs a configurable-duration mixed
  workload — pass `FEOXDB_SOAK_DURATION_MS` for a real multi-hour run.
- Milestone 4 (CI cross-build matrix): added `.github/workflows/ci.yml`
  (format, clippy, compile, test, Dialyzer, docs on every push/PR).
- Milestone 5 (RustlerPrecompiled release, checksum file): added
  `.github/workflows/release.yml`, which builds precompiled NIFs for
  every Tier 1 target plus best-effort Windows on a `v*` tag push,
  attaches them to the GitHub release, and opens a PR regenerating
  `checksum-Elixir.FeoxDB.Native.exs`. `FeoxDB.Native` now builds from
  source until that checksum file exists (i.e. before the first
  release) and otherwise defers to RustlerPrecompiled's normal
  download-then-verify behavior.
- Milestone 6 (benchmark harness): added `bench/run.exs` and
  `bench/support/systems.ex`, a Benchee harness comparing `feoxdb_ex`
  (memory and persistent modes) against CubDB, Cachex, and raw `:ets`
  across 4 of the PRD's 8 workloads. See `bench/README.md` for scope,
  fairness rules applied, and how to scale it up.
- Milestone 7 (benchmark report): published `bench/REPORT.md` from a run
  in this sandbox, explicitly caveated as a single-container smoke-scale
  run rather than the PRD section 9.6 dedicated-hardware benchmark.

### Milestone 2: Full API, error mapping, typespecs

- Bumped the minimum Elixir version to `~> 1.15` to match what `rustler`
  0.38 actually requires (discovered when Dialyzer/docs tooling was set
  up against the declared `~> 1.14` floor).
- Added `docs/PRD.md` to the published ExDoc extras so the README's link
  to it resolves in generated docs.
- Verified the project is Dialyzer-clean (`mix dialyzer`) and that
  `mix docs` generates without warnings, per the PRD's milestone 2 exit
  criteria.

## 0.1.0

### Milestone 1: Skeleton crate, open/get/insert/delete

- Initial Rustler NIF crate (`native/feoxdb_nif`) wrapping `feoxdb` 0.6.
- Public `FeoxDB` API: `open/1`, `flush/1`, `get/2`, `insert/4`,
  `delete/2`, `member?/2`, `size/1`, `memory_usage/1`, `range/4`, TTL
  operations (`ttl/2`, `update_ttl/3`, `persist/2`), atomics
  (`increment/3`, `compare_and_swap/4`), `json_patch/3`, and `stats/1`.
- Error mapping from `feoxdb::FeoxError` to Elixir error atoms.
- 25 ExUnit tests covering the full API.
