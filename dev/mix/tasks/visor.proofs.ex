defmodule Mix.Tasks.Visor.Proofs do
  @shortdoc "Proves the rules in proofs/ with gdp-wired (needs bun)"

  @moduledoc """
  Runs the gdp-wired proofs in `proofs/` (wakes, budget, repeat guard)
  with bun, installing their packages first if they aren't:

      $ mix visor.proofs [--strict]

  It fails when a law that should hold isn't proven, or a broken variant
  kept beside it is no longer refused.

  Without bun on the PATH it says so and does nothing, unless `--strict`
  (as `mix precommit` runs it) or `VISOR_PROOFS_STRICT=1`, which fail:
  a gate that passes without running isn't one.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [strict: :boolean])
    strict? = Keyword.get(opts, :strict, false) or System.get_env("VISOR_PROOFS_STRICT") == "1"
    dir = Path.expand("proofs", File.cwd!())

    case System.find_executable("bun") do
      nil when strict? ->
        Mix.raise("visor.proofs: bun isn't installed, so the proofs in proofs/ can't run.")

      nil ->
        Mix.shell().info(
          "visor.proofs: bun isn't installed, so the proofs in proofs/ weren't run."
        )

      bun ->
        unless File.dir?(Path.join(dir, "node_modules")),
          do: bun!(bun, ["install", "--frozen-lockfile"], dir)

        bun!(bun, ["run", "prove"], dir)
    end
  end

  defp bun!(bun, args, dir) do
    case System.cmd(bun, args, cd: dir, stderr_to_stdout: true, into: IO.stream()) do
      {_out, 0} ->
        :ok

      {_out, status} ->
        Mix.raise("visor.proofs: bun #{Enum.join(args, " ")} exited with #{status}")
    end
  end
end
