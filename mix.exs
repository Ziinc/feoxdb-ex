defmodule FeoxDB.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/ziinc/feoxdb-ex"

  def project do
    [
      app: :feox_db,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Elixir bindings for FeOxDB, an embedded key-value store",
      package: package(),
      docs: docs(),
      dialyzer: [
        plt_add_apps: [:mix],
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
      ],
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # `credo_checks/` holds our custom Credo checks (see `.credo.exs`). They
  # depend on `Credo.Check`, which is only available in `:dev`/`:test`
  # (where `mix credo` actually runs), so they're excluded from the default
  # (`:prod`) compilation path.
  defp elixirc_paths(env) when env in [:dev, :test], do: ["lib", "credo_checks"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:rustler, ">= 0.0.0", optional: true},
      {:rustler_precompiled, "~> 0.9"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1", only: [:dev, :test]},

      # PRD section 9: benchmark comparison targets. Only needed to run
      # `mix run bench/run.exs`, so they stay out of the default build.
      {:benchee, "~> 1.3", only: :bench},
      {:benchee_html, "~> 1.0", only: :bench},
      {:cubdb, "~> 2.0", only: :bench},
      {:cachex, "~> 4.0", only: :bench}
    ]
  end

  defp package do
    [
      name: "feox_db",
      files: [
        "lib",
        "native/feoxdb_nif/src",
        "native/feoxdb_nif/Cargo.toml",
        "native/feoxdb_nif/Cargo.lock",
        "checksum-Elixir.FeoxDB.Native.exs",
        "mix.exs",
        "README.md",
        "CHANGELOG.md",
        "LICENSE"
      ],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md", "docs/PRD.md"]
    ]
  end
end
