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

  alias Visor.Feedback
  alias Visor.Agent.Event

  # V.__begin__/0 finds the script's context and names its processes.
  @begin "V.__begin__(); "

  @opts [
    allowlist: Visor.Code.Allowlist,
    timeout: Visor.Limits.script_timeout_ms(),
    # Reductions include the work V does for the script (reading and
    # searching files), so this is high; the timeout is the real bound.
    max_reductions: 2_000_000_000,
    # In words, about 100 MB.
    max_heap_size: 12_500_000,
    # @begin doesn't count against the script.
    max_length: Visor.Limits.script_chars() + byte_size(@begin),
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
    {status, text, _calls} = execute(code, context)
    {status, text}
  end

  @doc "Like `run/2`, and also returns the script's V calls (see `facts/1`)."
  def execute(code, context) do
    # The script records its V calls here rather than in this process's
    # mailbox, which Dune waits in: a script can make thousands.
    table = :ets.new(:visor_calls, [:public])
    Process.put(__MODULE__, Map.put(context, :calls, table))
    result = Dune.eval_string(@begin <> code, @opts)
    log_script(context, result)
    calls = calls(table)
    {status, text} = Feedback.Script.render(result, calls, &Feedback.keep(context[:session], &1))
    {status, text, calls}
  end

  @doc """
  What each of a script's V calls did, small enough to keep for the whole
  session: its call text, whether it worked, and the file, command or check
  it touched. `Visor.Compaction` sums up old steps from these.
  """
  def facts(calls), do: Enum.map(calls, &fact/1)

  defp fact(call) do
    %{
      name: call.name,
      text: call.text,
      status: call.status,
      path: path(call.name, call.args),
      error: call[:error] && first_line(call.error, 300),
      changed: call[:changed],
      ran: call[:ran] && first_line(call.ran, 200),
      exit: call[:exit],
      check: call[:value][:status],
      summary: call[:check] && first_line(call.check, 200)
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp path(name, [path | _]) when name in [:ls, :read, :exists?, :write, :edit, :glob, :check],
    do: path

  defp path(:grep, [_pattern, path]), do: path
  defp path(:grep, [_pattern]), do: "."
  defp path(_name, _args), do: nil

  defp first_line(text, max_bytes) do
    text |> String.split("\n", parts: 2) |> hd() |> Visor.Tools.truncate(max_bytes)
  end

  # The script's whole output and value, before the summary for the model
  # cuts them, for the session log.
  defp log_script(%{session: session, call_id: call_id}, result) do
    Event.broadcast(session, {:script_end, call_id, script_info(result)})
  end

  defp log_script(_context, _result), do: :ok

  defp script_info(%Dune.Success{} = success) do
    %{
      status: :ok,
      stdio: success.stdio,
      value: Feedback.Script.inspected(success, :infinity, :infinity)
    }
  end

  defp script_info(failure) do
    %{status: :error, type: failure.type, message: failure.message, stdio: failure.stdio}
  end

  # The script's V calls, each as its last report, including the one a
  # script stopped at its time limit was making.
  defp calls(table) do
    calls = table |> :ets.tab2list() |> Enum.map(&elem(&1, 1)) |> Enum.sort_by(& &1.n)
    :ets.delete(table)
    calls
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
  # Records one of a script's V calls for its runner, and sends it to the
  # console. A later report of the same call replaces the earlier.
  def report(context, call) do
    with %{calls: table} <- context, do: :ets.insert(table, {call.n, call})

    with %{session: session, call_id: call_id} <- context do
      Event.broadcast(session, {:code_call, call_id, call})
    end

    :ok
  end
end

defmodule Visor.Code.Allowlist do
  @moduledoc false
  use Dune.Allowlist, extend: Dune.Allowlist.Default

  allow V,
    only: [
      :__begin__,
      :ls,
      :glob,
      :exists?,
      :read,
      :grep,
      :write,
      :edit,
      :sh,
      :check,
      :output,
      :recall,
      :beam_stats
    ]

  allow Path, only: [:join, :basename, :dirname, :extname, :rootname, :split]
end
