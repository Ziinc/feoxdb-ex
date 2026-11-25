# FeOxDB binding design

## 1. Summary

The `feox_db` Hex package gives Elixir applications access to FeOxDB, an
embedded Rust key-value store. Applications can keep data in memory or
use a file for persistence. The [benchmark report](../bench/REPORT.md)
covers the measurements to date. Section 9 describes the full benchmark plan.

## 2. Problem

ETS and Cachex keep data in memory. DETS and CubDB can keep it across
node restarts. The project measures how FeOxDB compares with these stores
when an Elixir process pays the cost of a native call and a value copy.

## 3. Goals

- Expose FeOxDB operations through an Elixir API.
- Ship precompiled native libraries for the supported targets.
- Keep calls on normal BEAM schedulers under one millisecond.
- Compare the stores on the same hardware with the same workloads.

## 4. Scope

The binding runs on one node. Replication, clustering, a Redis protocol
server, and an Ecto adapter are outside its scope. FeOxDB buffers writes.
A crash can lose data that the store has yet to flush.

## 5. Scheduler choices

A BEAM scheduler cannot interrupt a running native implemented function
(NIF). A long call delays other processes on that scheduler.

| Scheduler | Native calls | Reason |
|---|---|---|
| Normal | Membership, size, memory usage, TTL lookup, statistics | These calls read in-memory metadata. |
| Dirty I/O | Open, close, flush, get, insert, delete, range, TTL updates, counter updates, compare-and-swap, JSON patch | These calls can wait for I/O or locks, or scan multiple records. |

## 6. Architecture

The public `FeoxDB` module validates inputs and calls its internal native module.
Rustler binds these calls to the `feoxdb_nif` crate, which uses FeOxDB 0.6.

### 6.1 Store handles

Elixir processes can share a store handle. Rustler holds the handle in
a `ResourceArc`. Each native operation takes a reference to the store.
Closing the handle prevents new operations. The store releases its
workers and file handles when the last active operation drops its reference.

### 6.2 Binaries

Rustler borrows input keys and values as byte slices. For a read, the
binding copies the result into an `OwnedBinary` that the BEAM can manage.

### 6.3 Errors

The binding maps Rust errors to Elixir atoms. For example, a missing key
returns `{:error, :not_found}`, and an allocation failure returns
`{:error, :out_of_memory}`. Bang functions such as `FeoxDB.get!/2` raise
`FeoxDB.Error`. See `t:FeoxDB.error_reason/0` for the error atoms.

## 7. Public API

Use `FeoxDB` for binary keys and values. It supports range scans, key
expiry, atomic counters, compare-and-swap, and JSON patches.
Use `FeoxDB.Term` to store Erlang terms in a separate store.

Two limits affect how callers read and update records.

- `FeoxDB.range/4` requires a positive limit of at most 10,000 pairs.
  This bounds the size of the result.
- `FeoxDB.increment/3` takes an Elixir integer for the change. The stored
  counter uses an 8-byte signed little-endian integer.

## 8. Build and distribution

### 8.1 Source layout

The public modules live in `lib/`. The Rust crate lives in
`native/feoxdb_nif/`. Its `src/store.rs` implements the store operations,
and `src/error.rs` maps errors to Elixir terms.

### 8.2 Native libraries

RustlerPrecompiled selects a library by operating system, architecture,
and NIF version. It verifies the download against
`checksum-Elixir.FeoxDB.Native.exs`. See the [README](../README.md) for
source build instructions.

### 8.3 Targets

The package targets NIF 2.15.

| Operating system | Architectures | Runtime |
|---|---|---|
| Linux | x86-64, AArch64 | glibc or musl |
| macOS | x86-64, Apple Silicon | Darwin |

The release workflow also attempts an x86-64 Windows MSVC build. Windows
is outside the package's list of precompiled download targets.

### 8.4 Releases

A version tag starts the release workflow. It builds the native libraries,
attaches them to the GitHub release, and generates the checksum file.
The publish job checks that the tag matches the package version, downloads
the checksums, and publishes the package and docs to Hex.

## 9. Benchmark plan

### 9.1 Stores

Compare in-memory FeOxDB with ETS and Cachex. Compare persistent FeOxDB
with CubDB, DETS, and Mnesia. Record the durability settings for each
persistent store.

### 9.2 Tools

Use Benchee to record latency, throughput, memory allocations, and
reductions. Save the results as HTML.

### 9.3 Workloads

Run each workload with 1, 2, 4, 8, and 16 concurrent processes. Test
64-byte, 1 KiB, and 64 KiB values.

| Workload | Operation |
|---|---|
| Sequential read | Preload one million keys and read each key once. |
| Random read | Select keys uniformly from the preloaded set. |
| Hot keys | Direct 90% of reads to 10% of keys. |
| Write | Insert one million new keys. |
| Overwrite | Write new values to existing keys. |
| Mixed | Run 80% reads and 20% writes. |
| Range scan | Request 100 pairs per scan, then 10,000. |
| Delete | Delete each preloaded key. |

### 9.4 Measurements

Report median, 99th percentile, and 99.9th percentile latency, operations
per second, BEAM allocations, and reductions per operation. After preload,
record BEAM memory and the operating system's resident set size for the
node. The latter includes the native store.

### 9.5 Scheduler delays

Run a process that sleeps for one millisecond during the write workload.
Record how late it wakes. Sample scheduler utilization during each run
and compare the delays with ETS.

### 9.6 Hosts

Use a dedicated x86-64 Linux host with NVMe and `io_uring`, and a second
host with Apple Silicon. Disable CPU frequency scaling where possible.
Record the CPU settings, kernel, filesystem, OTP version, and Elixir version.
Start each persistent scenario with fresh store files.

### 9.7 Run settings

Use the same data and key distribution for each store. Warm up each
scenario before measuring it. Record CubDB's compaction and sync
settings. Include a persistent FeOxDB run that times the final flush.

## 10. Milestones

| Deliverable | Acceptance criterion |
|---|---|
| Basic binding | Open, read, insert, and delete pass on the development host. |
| Public API | Publish the API docs and pass Dialyzer. |
| Concurrency tests | Complete a 24-hour soak without a crash or memory leak. |
| Cross-builds | Produce a native library for each supported target. |
| Precompiled package | Install on a clean host without Rust. |
| Benchmark harness | Run all planned scenarios. |
| Report | Review and publish the measurements. |

## 11. Open questions

- How do background workers behave during hot code reload and module purge?
- Which upstream dependencies limit Windows support?
- What bounds should the binding enforce for `hash_bits` and `file_size`?
- Should callers be able to set the background flush interval?

## 12. Acceptance targets

The performance targets are a threefold improvement over CubDB for random
reads of 64-byte values and scheduler delays comparable to ETS. Evaluate
both on the hosts specified in section 9.6. The report must include the
durability settings and enough detail to reproduce the run.
