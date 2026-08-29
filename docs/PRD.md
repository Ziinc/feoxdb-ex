# PRD: `feoxdb_ex` — Elixir bindings for FeOxDB

Status: Draft for handoff
Owner: TBD
Reviewers: TBD

---

## 1. Summary

FeOxDB is an embedded key-value store written in Rust. It keeps hot data in memory and writes to disk in the background. The published numbers are roughly 200ns for a read and 600-970ns for a write in memory-only mode.

This project wraps FeOxDB so that Elixir code can use it. The wrapper uses Rustler, which is the standard way to call Rust from the BEAM. It also uses RustlerPrecompiled, which ships prebuilt binaries so that users do not need a Rust toolchain installed.

The second half of the project is a benchmark suite. It compares `feoxdb_ex` against CubDB (a pure-Elixir persistent store) and Cachex (an in-memory ETS cache). The benchmarks tell us whether the native call overhead eats the performance advantage.

## 2. Problem

Elixir developers have two common choices for embedded storage, and each has a gap:

- **ETS / Cachex** is fast but does not survive a node restart. DETS is the persistent sibling and it is slow.
- **CubDB** persists to disk and is written in pure Elixir. It is easy to deploy, but writes go through the BEAM scheduler and an append-only log, so throughput is limited.

There is no option that is both persistent and near-memory speed. FeOxDB fills that gap, but only if the cost of crossing from the BEAM into Rust stays small.

## 3. Goals

1. Publish a Hex package that exposes the FeOxDB API to Elixir with an idiomatic interface.
2. Ship precompiled binaries so `mix deps.get` works without Rust installed.
3. Never block a BEAM scheduler thread for longer than roughly 1 millisecond.
4. Produce a benchmark report that compares `feoxdb_ex`, CubDB, and Cachex on the same hardware and the same workloads.

## 4. Non-goals

- Distribution, replication, or clustering. FeOxDB is a single-node store.
- A Redis-protocol server. That is a separate upstream project (`feox-server`).
- Full ACID durability. FeOxDB buffers writes and can lose the last window of data on a hard crash. We document this; we do not fix it.
- An Ecto adapter.

## 5. Background: what a scheduler is, and why it matters here

The BEAM runs Elixir processes on a small pool of operating system threads called schedulers. The runtime assumes it can interrupt any process quickly and give the thread to another process. That assumption is how the BEAM stays responsive under load.

A NIF (Native Implemented Function) is Rust code that runs directly on the scheduler thread. The scheduler cannot interrupt it. If a NIF runs for a long time, every other process on that thread waits. The published guidance is that a NIF should finish in under 1 millisecond.

This gives us three tools, and the design must pick the right one for each function:

| Tool | When to use it | Cost |
|---|---|---|
| Plain NIF | Operation always finishes in well under 1ms | None |
| Dirty NIF (`schedule: "DirtyIo"`) | Operation may block on disk | ~2-3 microseconds of extra dispatch |
| Chunked NIF | Operation is long but can be split | Complex |

Single-key reads and writes to FeOxDB take nanoseconds, so they are plain NIFs. `flush/1` waits for `fsync` on the disk and must be a dirty NIF. Range queries depend on the result count, so they need a hard limit and a measurement before we decide.

## 6. Architecture

```
Elixir application
  |
  v
FeoxDB module            <- public API, validates arguments
  |
  v
FeoxDB.Native module     <- Rustler NIF stubs
  |
  v
native/feoxdb_nif        <- Rust crate
  |
  v
feoxdb crate 0.6         <- upstream store
```

### 6.1 The resource handle

The Rust side wraps `Arc<FeoxStore>` in a `ResourceArc`. A `ResourceArc` is a reference-counted pointer that the BEAM garbage collector understands. When the Elixir term that holds the handle becomes garbage, the collector drops the Rust value.

`FeoxStore` is `Send + Sync`, so many Elixir processes can call into the same handle at the same time. No GenServer is needed to serialise access, and adding one would create a bottleneck.

There is one open question. FeOxDB starts background writer threads. We must confirm that the destructor shuts them down cleanly, and that a hot code reload does not leave threads running against freed memory. See section 11.

### 6.2 Binary handling

Elixir binaries larger than 64 bytes live on a shared heap and are reference-counted. Rustler exposes them as `Binary`, which borrows the bytes without copying. Keys and values should use `Binary` on the way in.

On the way out, allocate an `OwnedBinary` and copy the value into it once. FeOxDB returns `Bytes`, which is its own reference-counted buffer; we cannot hand that pointer to the BEAM directly, so one copy is unavoidable.

### 6.3 Error mapping

`FeoxError` becomes an atom. The Elixir layer returns tagged tuples.

| Rust error | Elixir return |
|---|---|
| `KeyNotFound` | `{:error, :not_found}` |
| `OutOfMemory` | `{:error, :out_of_memory}` |
| `OutOfSpace` | `{:error, :out_of_space}` |
| `OlderTimestamp` | `{:error, :older_timestamp}` |
| `InvalidJson` | `{:error, :invalid_json}` |

Bang variants (`get!/2`, `insert!/3`) raise a `FeoxDB.Error` exception instead.

## 7. Public API

```elixir
# lifecycle
FeoxDB.open()                              # memory-only
FeoxDB.open(path: "/var/lib/app.feox")
FeoxDB.open(path: p, file_size: n, max_memory: n, hash_bits: n, enable_ttl: bool)
FeoxDB.flush(store)                        # dirty NIF

# basic operations
FeoxDB.get(store, key)                     # {:ok, binary} | {:error, :not_found}
FeoxDB.insert(store, key, value)           # :ok | {:error, term}
FeoxDB.delete(store, key)
FeoxDB.member?(store, key)
FeoxDB.size(store)
FeoxDB.memory_usage(store)

# ranges
FeoxDB.range(store, start_key, end_key, limit)   # both bounds inclusive

# ttl (requires enable_ttl: true at open time)
FeoxDB.insert(store, key, value, ttl: 60)
FeoxDB.ttl(store, key)                     # {:ok, seconds} | {:ok, nil}
FeoxDB.update_ttl(store, key, seconds)
FeoxDB.persist(store, key)

# atomics
FeoxDB.increment(store, key, delta)        # value must be an 8-byte little-endian i64
FeoxDB.compare_and_swap(store, key, expected, new)   # {:ok, true | false}

# json
FeoxDB.json_patch(store, key, patch)       # RFC 6902

# stats
FeoxDB.stats(store)                        # map
```

Two notes on design choices:

- `range/4` requires an explicit limit. An unbounded range query could run for an unknown time on the scheduler, and could also build a very large term. Requiring the limit makes the cost visible to the caller.
- `increment/3` takes and returns an Elixir integer. The binding does the little-endian conversion, because forcing callers to write `<<n::signed-little-64>>` is an easy source of bugs.

## 8. Build and distribution

### 8.1 Crate layout

```
feoxdb_ex/
  lib/feox_db.ex
  lib/feox_db/native.ex
  native/feoxdb_nif/
    Cargo.toml
    src/lib.rs
    src/error.rs
    src/store.rs
  checksum-Elixir.FeoxDB.Native.exs   # generated, committed
  .github/workflows/release.yml
```

### 8.2 RustlerPrecompiled

RustlerPrecompiled downloads a `.so` or `.dll` that matches the user's operating system, CPU architecture, and NIF version. If no match exists, it falls back to building from source when the user sets `FEOXDB_BUILD=true`.

The download is verified against a checksum file. That file is generated by `mix rustler_precompiled.download FeoxDB.Native --all` after a release build, and it must be committed before publishing to Hex. A missing or stale checksum file is the most common cause of a broken release.

### 8.3 Target matrix

FeOxDB pulls in `io-uring`, `nix`, and `libc` on Linux, and optionally `tikv-jemallocator`. These constrain what we can cross-compile.

Tier 1, must work:

- `x86_64-unknown-linux-gnu`
- `aarch64-unknown-linux-gnu`
- `x86_64-unknown-linux-musl`
- `aarch64-unknown-linux-musl`
- `aarch64-apple-darwin`
- `x86_64-apple-darwin`

Tier 2, best effort:

- `x86_64-pc-windows-msvc`

Risks in this matrix:

- **musl.** `io_uring` and jemalloc under musl are the likeliest build failures. If musl fails, add a Cargo feature that disables `io_uring` and falls back to normal file I/O, and build the musl targets with that feature off.
- **Windows.** Upstream lists `io-uring`, `nix`, and `libc` as normal (non-optional) dependencies in the docs.rs listing for the Linux target. Confirm whether these are behind `cfg(target_os)` gates. If they are not, Windows support is blocked and should be dropped from scope for v1.
- **NIF version.** Target NIF 2.15, which covers OTP 24 and later. Building against a newer NIF version silently reduces the OTP range users can install on.

### 8.4 Release workflow

Tag push (`v*`) triggers a GitHub Actions matrix that runs `rustler-precompiled-action` for each target, attaches artifacts to the release, then a final job regenerates the checksum file. Publishing to Hex stays manual for v1.

## 9. Benchmark plan

### 9.1 What we are comparing

| System | Storage | Persistence | Written in |
|---|---|---|---|
| `feoxdb_ex` memory mode | Rust structures on the C heap | None | Rust |
| `feoxdb_ex` persistent mode | Rust structures plus disk | Buffered, bounded loss | Rust |
| CubDB | Append-only log plus B-tree | Yes | Elixir |
| Cachex | ETS | No | Elixir |
| `:ets` raw | ETS | No | C, in the runtime |

Raw ETS is included as a control. It is the cheapest possible operation on the BEAM, so it sets the floor. If `feoxdb_ex` is slower than ETS, the difference is the NIF call overhead plus the value copy, and we should be able to account for it.

Cachex is not persistent, so a comparison against persistent FeOxDB is not like-for-like. Report both FeOxDB modes so readers can make the correct comparison themselves.

### 9.2 Tooling

Benchee, with `Benchee.Formatters.HTML` and the memory and reduction measurements switched on. Reductions matter here: a NIF returns very few reductions relative to the work it does, which is exactly the behaviour that starves other processes. A high time-to-reduction ratio is a warning sign.

### 9.3 Workloads

Each scenario runs at 1, 2, 4, 8, and 16 concurrent processes.

1. **Sequential read.** Preload 1M keys, read each once.
2. **Random read.** Preload 1M keys, read with a uniform random key.
3. **Random read, hot subset.** 90% of reads hit 10% of keys. This is where FeOxDB's CLOCK cache should show an advantage over CubDB.
4. **Write only.** Insert 1M new keys.
5. **Overwrite.** Insert over existing keys. FeOxDB coalesces repeated writes to the same key, so this should be faster than case 4.
6. **Mixed 80/20.** 80% reads, 20% writes.
7. **Range scan.** 100 keys per scan, then 10,000 keys per scan.
8. **Delete.** Remove all preloaded keys.

Value sizes: 64 bytes, 1 KB, 64 KB. The 64-byte case sits below the BEAM's reference-counted binary threshold, so it isolates per-call overhead. The 64 KB case is dominated by the copy, and should show FeOxDB's advantage shrinking.

### 9.4 Measurements to report

- Median, 99th percentile, and 99.9th percentile latency. Report percentiles, not just averages. An average hides the scheduler stalls we most care about finding.
- Throughput in operations per second.
- Memory allocated per operation on the BEAM heap.
- Reductions per operation.
- Resident set size of the whole node after preload, sampled from `:erlang.memory/0` and from the operating system. FeOxDB allocates outside the BEAM, so `:erlang.memory/0` alone will under-report it.

### 9.5 Scheduler health

Run a separate scenario that measures scheduler behaviour rather than raw speed.

Start a background process that sleeps for 1 millisecond in a loop and records the actual elapsed time. Run each store's write workload underneath it. Plot the sleep overshoot. If a NIF is blocking a scheduler, the overshoot appears here even when the throughput numbers look healthy.

Also sample `:scheduler.utilization/1` during each run.

### 9.6 Environment

- One dedicated Linux host, `x86_64`, NVMe disk, `io_uring` available.
- One Apple Silicon host, to confirm the results are not specific to `io_uring`.
- CPU frequency scaling disabled, or the results are not repeatable.
- Record OTP version, Elixir version, kernel version, and filesystem in the report.

Persistent-mode runs need a clean disk state between scenarios, because FeOxDB pre-allocates its file and free-space behaviour changes as the file fills.

### 9.7 Fairness rules

Benchmarks between a native library and a pure-Elixir library are easy to write unfairly. Fix these before publishing:

- Give CubDB an equivalent durability setting. CubDB has an auto-compaction and a sync setting; leaving it at the safe default while running FeOxDB in memory-only mode is not a fair comparison, and the report must say which settings were used.
- Do not count FeOxDB's background flush time as free. Run one variant with an explicit `flush/1` at the end and include that time.
- Use the same key distribution and the same generated data for every system.
- Discard the first run of each scenario as warm-up.

## 10. Milestones

| # | Deliverable | Exit criteria |
|---|---|---|
| 1 | Skeleton crate, `open`, `get`, `insert`, `delete` | Passes tests on the host machine |
| 2 | Full API, error mapping, typespecs | Dialyzer clean, docs published |
| 3 | Property tests and concurrency tests | 24-hour soak with no crash and no leak |
| 4 | CI cross-build matrix | All Tier 1 targets produce artifacts |
| 5 | RustlerPrecompiled release, checksum file | Fresh machine with no Rust installs the package |
| 6 | Benchmark harness | All scenarios run end to end |
| 7 | Benchmark report | Reviewed, published |

Milestones 1-3 and 6 can proceed in parallel with 4-5.

## 11. Open questions

1. Does dropping the `ResourceArc` shut down FeOxDB's background writer threads? If not, the destructor must call an explicit close, and we need to decide what happens to calls that arrive after close.
2. What happens on hot code reload or `:code.purge` while writer threads are running? Rustler's resource destructors run on the BEAM's side; a thread that outlives the module is a crash risk.
3. Are `io-uring`, `nix`, and `libc` gated by `cfg(target_os)` in the upstream crate? This decides whether Windows and macOS are buildable at all.
4. Is `range_query` bounded in time by the limit argument, or does it scan before it truncates? This decides plain NIF versus dirty NIF.
5. Does FeOxDB validate `hash_bits` and `file_size`? If not, the Elixir layer validates them, because an out-of-range value that reaches Rust may panic, and a panic inside a NIF brings down the whole node.
6. Should the package expose a `flush_interval` knob, or is the fixed 100ms window acceptable?

## 12. Success criteria

- The package installs on a machine with no Rust toolchain, on all Tier 1 targets.
- Random reads at 64-byte values are at least 3x faster than CubDB.
- Scheduler sleep overshoot under load stays within the same range as raw ETS.
- The benchmark report states the durability settings of every system it compares, and a reader can reproduce the numbers from the committed harness.
