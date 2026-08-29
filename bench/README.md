# Benchmark harness

Implements PRD section 9's comparison of `feoxdb_ex` (memory and
persistent modes) against CubDB, Cachex, and raw `:ets`, using
[Benchee](https://github.com/bencheeorg/benchee).

## Running it

```
MIX_ENV=bench mix deps.get
MIX_ENV=bench mix run bench/run.exs
```

HTML + console reports land in `bench/output/` (gitignored). Tune the run
with environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `BENCH_DATASET_SIZE` | `5000` | number of keys preloaded before each read/mixed scenario |
| `BENCH_VALUE_SIZE` | `64` | value size in bytes |
| `BENCH_CONCURRENCY` | `1,8` | comma-separated list of `parallel:` levels to run each scenario at |
| `BENCH_TIME_S` | `2.0` | Benchee measurement time per job, in seconds |
| `BENCH_WARMUP_S` | `1.0` | Benchee warmup time per job, in seconds |

For something closer to the PRD's full matrix (1M keys, value sizes of
64B/1KB/64KB, concurrency levels 1/2/4/8/16):

```
BENCH_DATASET_SIZE=1000000 \
BENCH_VALUE_SIZE=1024 \
BENCH_CONCURRENCY=1,2,4,8,16 \
BENCH_TIME_S=10 \
BENCH_WARMUP_S=3 \
MIX_ENV=bench mix run bench/run.exs
```

Note this rebuilds the dataset (and reruns preload) for every concurrency
level for every scenario, so a full matrix run across all three value
sizes takes a while; run one value size at a time.

## What's covered vs. the PRD

This harness currently implements 4 of the PRD's 8 workloads: random
read (2), write-only (4), mixed 80/20 (6), and delete (8). Sequential
read (1), the hot-subset read (3), range scans (7), and the overwrite
variant of write-only (5) are not yet implemented — the adapter layer
(`bench/support/systems.ex`) and the scenario-running helpers in
`bench/run.exs` are written so adding them is mostly copy-and-adjust, not
a redesign.

The delete workload (8) is a bounded, one-shot operation in the PRD
("remove all preloaded keys"), which doesn't fit Benchee's steady-state
iteration model directly. Each iteration instead uses a `before_each`
hook to insert a fresh key and then deletes exactly that key, so every
measured delete removes a key that actually exists, without ever running
out of keys mid-benchmark.

## Fairness rules applied (PRD section 9.7)

- CubDB is opened with `auto_compact: false, auto_file_sync: true` — an
  explicit, stated durability setting, not silently left at a default
  that may or may not match FeoxDB's persistent mode.
- `feox_persistent` calls `FeoxDB.flush/1` after preload so the
  background write time is captured rather than given away for free
  (there's no "flush variant" toggle yet; every persistent-mode preload
  flushes).
- All systems are preloaded from the same generated key list and the
  same random value bytes.
- Benchee's own warmup phase (`BENCH_WARMUP_S`) serves as the "discard
  first run" rule; each system+scenario combination is warmed up before
  it's measured.

## What this harness does not do

Per PRD section 9.6, a scheduler-health run (a background process
sleeping 1ms in a loop, measuring overshoot under load) and a controlled
multi-host environment (dedicated Linux + Apple Silicon boxes, disabled
CPU frequency scaling, recorded kernel/filesystem versions) are both out
of scope for this harness as committed. `bench/REPORT.md` records what
environment a given run actually used; treat any numbers from a shared
CI runner or a sandboxed container as indicative, not authoritative.
