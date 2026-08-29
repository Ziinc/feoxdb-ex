# Changelog

All notable changes to this project are documented in this file.

## Unreleased

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
