use feoxdb::FeoxError;

rustler::atoms! {
    // lifecycle / generic
    unsupported,
    not_implemented,
    timeout,

    // PRD section 6.3 error mapping
    not_found,
    out_of_memory,
    out_of_space,
    older_timestamp,
    invalid_json,

    // additional feoxdb errors surfaced as-is
    invalid_key_size,
    invalid_value_size,
    database_full,
    invalid_range,
    ttl_not_enabled,
    invalid_argument,
    corrupted_data,
    duplicate_key,
    size_mismatch,
    stale_extent,
    io_error,
    unknown_error,
}

/// Maps a `feoxdb::FeoxError` to the atom the Elixir layer expects in a
/// `{:error, atom}` tuple. See PRD section 6.3.
pub fn to_atom(error: &FeoxError) -> rustler::Atom {
    match error {
        FeoxError::KeyNotFound => not_found(),
        FeoxError::OutOfMemory | FeoxError::AllocationFailed => out_of_memory(),
        FeoxError::OutOfSpace | FeoxError::DatabaseFull => out_of_space(),
        FeoxError::OlderTimestamp => older_timestamp(),
        FeoxError::JsonPatchError(_) => invalid_json(),
        FeoxError::InvalidKeySize => invalid_key_size(),
        FeoxError::InvalidValueSize => invalid_value_size(),
        FeoxError::InvalidRange => invalid_range(),
        FeoxError::TtlNotEnabled => ttl_not_enabled(),
        FeoxError::InvalidArgument => invalid_argument(),
        FeoxError::CorruptedData | FeoxError::CorruptedRecord | FeoxError::InvalidRecord => {
            corrupted_data()
        }
        FeoxError::DuplicateKey => duplicate_key(),
        FeoxError::SizeMismatch { .. } => size_mismatch(),
        FeoxError::StaleExtent => stale_extent(),
        FeoxError::Timeout => timeout(),
        FeoxError::NotImplemented => not_implemented(),
        FeoxError::Unsupported => unsupported(),
        FeoxError::IoError(_) | FeoxError::IndeterminateWrite(_) => io_error(),
        _ => unknown_error(),
    }
}

/// Maps a `feoxdb::FeoxError` to a `rustler::Error` that encodes as
/// `{:error, atom}` when returned from a NIF.
pub fn to_nif_error(error: FeoxError) -> rustler::Error {
    rustler::Error::Term(Box::new(to_atom(&error)))
}

/// A `rustler::Error` encoding `{:error, :out_of_memory}`, for use when a
/// native allocation (e.g. `OwnedBinary::new`) fails outside of any
/// `feoxdb::FeoxError` path.
pub fn out_of_memory_error() -> rustler::Error {
    rustler::Error::Term(Box::new(out_of_memory()))
}
