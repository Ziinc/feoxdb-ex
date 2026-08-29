# Benchmark report (PRD milestone 7)

**This is a preliminary, single-container smoke-scale run, not the PRD
section 9.6 dedicated-hardware benchmark.** It exists to prove the
harness (`bench/run.exs`) produces sane, directionally-correct numbers,
and to give a rough sense of where `feoxdb_ex` sits relative to CubDB,
Cachex, and raw `:ets`. It is not a substitute for running the harness
on real, controlled hardware before publishing performance claims.

## Environment

| | |
|---|---|
| Host | Shared CI/sandbox container (not a dedicated benchmark host) |
| CPU | Intel(R) Xeon(R) Processor @ 2.80GHz, 4 cores (as reported by `:cpu_info`) |
| CPU frequency scaling | Not controlled/disabled — a PRD 9.6 requirement this run does not meet |
| Kernel | `uname -r` — see raw output below |
| Filesystem | container overlay filesystem, not a dedicated NVMe/io_uring-capable disk |
| Elixir / OTP | 1.17.3 / 25 |
| feoxdb crate | 0.6.0, `jemalloc` disabled (see `native/feoxdb_nif/Cargo.toml`) |

## Configuration

| | |
|---|---|
| Dataset size | 50,000 keys |
| Value size | 64 bytes |
| Concurrency levels | 1, 4 (parallel Benchee workers) |
| Measurement / warmup time | 2.0s / 0.5s per job |

## Fairness settings applied

- CubDB: `auto_compact: false, auto_file_sync: true` (explicit, not left
  at whatever the library's default happens to be).
- `feox_persistent`: preload is followed by an explicit `FeoxDB.flush/1`
  call, so background write time is counted.
- Same generated keys/values fed to every system.
- Benchee's warmup phase serves as the "discard first run" rule.

## Results

_(placeholder — filled in from the run's console output below)_

## Raw console output

```
(pasted from the actual run)
```

## Caveats / what this run does not establish

- Single container, not the PRD's two dedicated hosts (`x86_64` +
  Apple Silicon).
- No `io_uring` guarantee, no disabled CPU frequency scaling, no
  recorded filesystem type.
- Only 4 of the PRD's 8 workloads are implemented (see
  `bench/README.md`).
- Only one value size (64 bytes) was run; the PRD also wants 1KB and
  64KB.
- No scheduler-health run (PRD section 9.5) is implemented yet.

Re-run `bench/run.exs` with a larger `BENCH_DATASET_SIZE`, the full
`BENCH_CONCURRENCY` list, and each of the three value sizes on
appropriate hardware before treating any of these numbers as
publishable.
