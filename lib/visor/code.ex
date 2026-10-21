defmodule Visor.Code do
  @moduledoc """
  Code mode. The model writes one Elixir script that calls the tools as
  functions on `V`, and the whole script runs in a single process, so a
  step with many reads, searches and commands is one process and one model
  round trip instead of one per tool call.

  Scripts run in a Dune sandbox, which blocks File, System, processes,
  `apply` and other dynamic calls, leaving pure modules and `V`. Dune's
  own docs call the sandbox best-effort, so it guards against mistakes,
  not against a determined escape.

  Dune runs the script in a process of its own:

      tool elixir      the tool task, which holds the context
      └── sandbox      Dune's runner
          └── elixir script
  """

  alias Visor.{Agent, Feedback}

  @opts [
    allowlist: Visor.Code.Allowlist,
    timeout: 120_000,
    # Reductions include the work V does for the script (reading and
    # searching files), so this is high; the timeout is the real bound.
    max_reductions: 2_000_000_000,
    # In words, about 100 MB.
    max_heap_size: 12_500_000,
    max_length: 20_000,
    pretty: true,
    # Maps print in key order, so the same value always reads the same.
    inspect_sort_maps: true
  ]

  @doc """
  Runs a script for the `elixir` tool and sums it up for the model (see
  `Visor.Feedback.Script`). `context` (`:session` and `:call_id`) routes
  the script's calls to the console and its long outputs to the session's
  feedback collector.
  """
  def run(code, context) do
    # V.__begin__/0 finds this context and names the script's processes.
    Process.put(__MODULE__, Map.put(context, :runner, self()))
    result = Dune.eval_string("V.__begin__(); " <> code, @opts)
    Feedback.Script.render(result, calls(), &Feedback.keep(context[:session], &1))
  end

  # The script's V calls, each as its last report. The script sent them
  # before it ended, so they are all here once Dune returns.
  defp calls(calls \\ %{}) do
    receive do
      {__MODULE__, :call, call} -> calls(Map.put(calls, call.n, call))
    after
      0 -> calls |> Map.values() |> Enum.sort_by(& &1.n)
    end
  end

  @doc false
  # The context a runner stored, read by its script through `$ancestors`.
  def context(pid) do
    with {:dictionary, dictionary} <- Process.info(pid, :dictionary),
         {_key, context} <- List.keyfind(dictionary, __MODULE__, 0) do
      context
    else
      _ -> nil
    end
  end

  @doc false
  # Sends one of a script's V calls to its runner and the console.
  def report(context, call) do
    with %{runner: runner} <- context, do: send(runner, {__MODULE__, :call, call})

    with %{session: session, call_id: call_id} <- context do
      Phoenix.PubSub.broadcast(
        Visor.PubSub,
        Agent.topic(session),
        {:agent, {:code_call, call_id, call}}
      )
    end

    :ok
  end
end

defmodule Visor.Code.Allowlist do
  @moduledoc false
  use Dune.Allowlist, extend: Dune.Allowlist.Default

  allow V,
    only: [:__begin__, :ls, :glob, :read, :grep, :write, :edit, :sh, :check, :output, :beam_stats]

  allow Path, only: [:join, :basename, :dirname, :extname, :rootname, :split]
end
