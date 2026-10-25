defmodule Visor.MixProject do
  use Mix.Project

  def project do
    [
      app: :visor,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Visor.Application, []},
      extra_applications: [:logger, :runtime_tools, :sasl] ++ os_mon(Mix.env())
    ]
  end

  # The machine's memory and disk alarms (Visor.Alarms), raised through
  # sasl's alarm handler; the tests don't read the machine they run on.
  defp os_mon(:test), do: []
  defp os_mon(_env), do: [:os_mon]

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # dev/ holds the tooling, mix visor.example and visor.proofs: built in
  # dev and test (where mix precommit runs), kept out of a release.
  defp elixirc_paths(env) when env in [:dev, :test], do: ["lib", "dev"]
  defp elixirc_paths(_env), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.16"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:req, "~> 0.5"},
      {:jason, "~> 1.2"},
      {:bandit, "~> 1.5"},
      {:dune, github: "asx8678/dune", ref: "59dccd0613efb2416c86b93cf5c1508ce5424d86"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind visor", "esbuild visor"],
      "assets.deploy": [
        "tailwind visor --minify",
        "esbuild visor --minify",
        "phx.digest"
      ],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "visor.proofs --strict",
        "visor.example --offline"
      ]
    ]
  end
end
