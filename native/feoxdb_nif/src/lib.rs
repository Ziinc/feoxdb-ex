mod atoms;
mod error;
mod store;

fn load(env: rustler::Env, _info: rustler::Term) -> bool {
    env.register::<store::StoreResource>().is_ok()
}

rustler::init!("Elixir.FeoxDB.Native", load = load);
