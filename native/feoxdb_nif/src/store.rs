use std::sync::{Arc, RwLock};

use feoxdb::FeoxStore;
use rustler::{Atom, Binary, Env, Error, NifResult, OwnedBinary, ResourceArc, Term};

use crate::error::{out_of_memory_error, to_nif_error};

/// Wraps `Arc<FeoxStore>` so the resource itself is cheap to clone/share across
/// processes (PRD section 6.1) while `FeoxStore`'s own `Drop` impl stops the
/// background writer / TTL sweeper threads when the last reference goes away.
///
/// The `Arc` is held behind an `RwLock<Option<_>>` rather than directly so
/// that `close/1` can deterministically `take()` it out (dropping the store's
/// reference right away instead of waiting on the GC to collect the
/// `ResourceArc`), while every other NIF takes a read lock and gets a clean
/// `{:error, :closed}` instead of panicking if the store has already been
/// closed. The common (not-closed) path only ever contends on the read lock,
/// which is cheap and allows concurrent readers.
pub struct StoreResource(RwLock<Option<Arc<FeoxStore>>>);

// `FeoxStore` uses interior mutability (locks, atomics) internally and handles
// its own synchronization; a Rust panic unwinding through a NIF call does not
// leave it in an observably inconsistent state from Elixir's point of view.
impl std::panic::RefUnwindSafe for StoreResource {}

#[rustler::resource_impl]
impl rustler::Resource for StoreResource {}

impl StoreResource {
    fn new(store: Arc<FeoxStore>) -> Self {
        Self(RwLock::new(Some(store)))
    }

    /// Returns a clone of the underlying store, or a `{:error, :closed}` NIF
    /// error if `close/1` has already released it.
    fn get(&self) -> Result<Arc<FeoxStore>, Error> {
        let guard = self
            .0
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        guard
            .clone()
            .ok_or_else(|| Error::Term(Box::new(crate::error::closed())))
    }
}

/// Copies `bytes` into a freshly allocated `OwnedBinary` handed off to the
/// BEAM. `OwnedBinary::new` returns `None` (not a `Result`) when the
/// allocation fails, so we surface that as `{:error, :out_of_memory}`
/// instead of panicking the whole NIF call via `.expect(...)`.
fn owned_binary<'a>(env: Env<'a>, bytes: &[u8]) -> Result<Binary<'a>, Error> {
    let mut owned = OwnedBinary::new(bytes.len()).ok_or_else(out_of_memory_error)?;
    owned.as_mut_slice().copy_from_slice(bytes);
    Ok(Binary::from_owned(owned, env))
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn open(
    path: Option<String>,
    file_size: Option<u64>,
    max_memory: Option<u64>,
    hash_bits: Option<u32>,
    enable_ttl: bool,
) -> Result<ResourceArc<StoreResource>, Error> {
    let mut builder = FeoxStore::builder();

    if let Some(path) = path {
        builder = builder.device_path(path);
    }
    if let Some(file_size) = file_size {
        builder = builder.file_size(file_size);
    }
    match max_memory {
        Some(limit) => builder = builder.max_memory(limit as usize),
        None => builder = builder.no_memory_limit(),
    }
    if let Some(hash_bits) = hash_bits {
        builder = builder.hash_bits(hash_bits);
    }
    if enable_ttl {
        builder = builder.enable_ttl(true);
    }

    let store = builder.build().map_err(to_nif_error)?;
    let store = Arc::new(store);
    if enable_ttl {
        store.start_ttl_sweeper(None);
    }

    Ok(ResourceArc::new(StoreResource::new(store)))
}

/// Deterministically releases the store's native resources rather than
/// relying solely on GC of the resource reference. Idempotent: calling it
/// more than once, or from more than one process, simply returns `:ok`
/// without error.
#[rustler::nif(schedule = "DirtyIo")]
pub fn close(resource: ResourceArc<StoreResource>) -> Atom {
    let mut guard = resource
        .0
        .write()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    *guard = None;
    rustler::types::atom::ok()
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn flush(resource: ResourceArc<StoreResource>) -> Result<Atom, Error> {
    resource.get()?.flush().map_err(to_nif_error)?;
    Ok(rustler::types::atom::ok())
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn get<'a>(
    env: Env<'a>,
    resource: ResourceArc<StoreResource>,
    key: Binary<'a>,
) -> Result<Binary<'a>, Error> {
    let value = resource.get()?.get(key.as_slice()).map_err(to_nif_error)?;
    owned_binary(env, &value)
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn insert(
    resource: ResourceArc<StoreResource>,
    key: Binary,
    value: Binary,
    ttl: Option<u64>,
) -> Result<bool, Error> {
    let store = resource.get()?;
    let result = match ttl {
        Some(seconds) if seconds > 0 => {
            store.insert_with_ttl(key.as_slice(), value.as_slice(), seconds)
        }
        _ => store.insert(key.as_slice(), value.as_slice()),
    };

    result.map_err(to_nif_error)
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn delete(resource: ResourceArc<StoreResource>, key: Binary) -> Result<Atom, Error> {
    resource
        .get()?
        .delete(key.as_slice())
        .map_err(to_nif_error)?;
    Ok(rustler::types::atom::ok())
}

#[rustler::nif(schedule = "Normal")]
pub fn member(resource: ResourceArc<StoreResource>, key: Binary) -> Result<bool, Error> {
    Ok(resource.get()?.contains_key(key.as_slice()))
}

#[rustler::nif(schedule = "Normal")]
pub fn size(resource: ResourceArc<StoreResource>) -> Result<usize, Error> {
    Ok(resource.get()?.len())
}

#[rustler::nif(schedule = "Normal")]
pub fn memory_usage(resource: ResourceArc<StoreResource>) -> Result<usize, Error> {
    Ok(resource.get()?.memory_usage())
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn range<'a>(
    env: Env<'a>,
    resource: ResourceArc<StoreResource>,
    start_key: Binary<'a>,
    end_key: Binary<'a>,
    limit: usize,
) -> Result<Vec<(Binary<'a>, Binary<'a>)>, Error> {
    let results = resource
        .get()?
        .range_query(start_key.as_slice(), end_key.as_slice(), limit)
        .map_err(to_nif_error)?;

    results
        .into_iter()
        .map(|(k, v)| Ok((owned_binary(env, &k)?, owned_binary(env, &v)?)))
        .collect()
}

#[rustler::nif(schedule = "Normal")]
pub fn ttl(resource: ResourceArc<StoreResource>, key: Binary) -> Result<Option<u64>, Error> {
    resource
        .get()?
        .get_ttl(key.as_slice())
        .map_err(to_nif_error)
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn update_ttl(
    resource: ResourceArc<StoreResource>,
    key: Binary,
    seconds: u64,
) -> Result<Atom, Error> {
    resource
        .get()?
        .update_ttl(key.as_slice(), seconds)
        .map_err(to_nif_error)?;
    Ok(rustler::types::atom::ok())
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn persist(resource: ResourceArc<StoreResource>, key: Binary) -> Result<Atom, Error> {
    resource
        .get()?
        .persist(key.as_slice())
        .map_err(to_nif_error)?;
    Ok(rustler::types::atom::ok())
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn increment(
    resource: ResourceArc<StoreResource>,
    key: Binary,
    delta: i64,
) -> Result<i64, Error> {
    resource
        .get()?
        .atomic_increment(key.as_slice(), delta)
        .map_err(to_nif_error)
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn compare_and_swap(
    resource: ResourceArc<StoreResource>,
    key: Binary,
    expected: Binary,
    new_value: Binary,
) -> Result<bool, Error> {
    resource
        .get()?
        .compare_and_swap(key.as_slice(), expected.as_slice(), new_value.as_slice())
        .map_err(to_nif_error)
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn json_patch(
    resource: ResourceArc<StoreResource>,
    key: Binary,
    patch: Binary,
) -> Result<Atom, Error> {
    resource
        .get()?
        .json_patch(key.as_slice(), patch.as_slice())
        .map_err(to_nif_error)?;
    Ok(rustler::types::atom::ok())
}

#[rustler::nif(schedule = "Normal")]
pub fn stats<'a>(env: Env<'a>, resource: ResourceArc<StoreResource>) -> NifResult<Term<'a>> {
    let snapshot = resource.get()?.stats();

    let pairs: Vec<(Atom, u64)> = vec![
        (crate::atoms::record_count(), snapshot.record_count as u64),
        (crate::atoms::memory_usage(), snapshot.memory_usage as u64),
        (crate::atoms::total_operations(), snapshot.total_operations),
        (crate::atoms::total_gets(), snapshot.total_gets),
        (crate::atoms::total_inserts(), snapshot.total_inserts),
        (crate::atoms::total_updates(), snapshot.total_updates),
        (crate::atoms::total_deletes(), snapshot.total_deletes),
        (
            crate::atoms::total_range_queries(),
            snapshot.total_range_queries,
        ),
        (
            crate::atoms::avg_get_latency_ns(),
            snapshot.avg_get_latency_ns,
        ),
        (
            crate::atoms::avg_insert_latency_ns(),
            snapshot.avg_insert_latency_ns,
        ),
        (
            crate::atoms::avg_delete_latency_ns(),
            snapshot.avg_delete_latency_ns,
        ),
        (crate::atoms::cache_hits(), snapshot.cache_hits),
        (crate::atoms::cache_misses(), snapshot.cache_misses),
        (crate::atoms::cache_evictions(), snapshot.cache_evictions),
        (crate::atoms::cache_memory(), snapshot.cache_memory as u64),
        (crate::atoms::writes_buffered(), snapshot.writes_buffered),
        (crate::atoms::writes_flushed(), snapshot.writes_flushed),
        (crate::atoms::write_failures(), snapshot.write_failures),
    ];

    let map = Term::map_from_pairs(env, &pairs)?;
    map.map_put(crate::atoms::cache_hit_rate(), snapshot.cache_hit_rate)
}
