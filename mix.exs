defmodule FeoxDB.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/ziinc/feoxdb-ex"

  def project do
    [
      app: :feox_db,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Elixir bindings for FeOxDB, an embedded key-value store",
      package: package(),
      docs: docs(),
      dialyzer: [plt_add_apps: [:mix]],
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:rustler, ">= 0.0.0", optional: true},
      {:rustler_precompiled, "~> 0.9"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
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
