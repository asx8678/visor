defmodule Visor.ServerLogTest do
  # The logger is global: these tests add handlers and change its filters.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  require Logger

  alias Visor.ServerLog

  @moduletag :tmp_dir

  # A GenServer as Erlang writes them, with no handle_info/2: like one of
  # ours while Mix recompiles it.
  defmodule NoHandleInfo do
    @behaviour :gen_server
    def init(state), do: {:ok, state}
    def handle_call(:ping, _from, state), do: {:reply, :pong, state}
    def handle_cast(_message, state), do: {:noreply, state}
  end

  defp lines(handler, path) do
    :ok = :logger_std_h.filesync(handler)
    path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  test "writes each line as JSON with where it came from", %{tmp_dir: dir} do
    path = Path.join(dir, "server.jsonl")
    :ok = ServerLog.add_handler(:server_log_test, path)
    on_exit(fn -> :logger.remove_handler(:server_log_test) end)

    capture_log(fn -> Logger.warning("disk is full\nsecond line", request_id: "r1") end)

    assert [line] = Enum.filter(lines(:server_log_test, path), &(&1["message"] =~ "disk is full"))

    assert %{
             "level" => "warning",
             "message" => "disk is full\nsecond line",
             "mfa" => "Visor.ServerLogTest." <> _,
             "domain" => ["elixir"],
             "metadata" => %{"request_id" => "r1"}
           } = line

    assert line["file"] =~ "server_log_test.exs"
    assert is_integer(line["line"])
    assert line["pid"] == inspect(self())
    assert line["at"] =~ ~r/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}$/
    assert File.read!(path) =~ ~r/^\{"at":"[^"]+","level":"warning","message":"disk is full/m
  end

  test "keeps the warning about a message a GenServer dropped" do
    pid =
      start_supervised!(%{
        id: NoHandleInfo,
        start: {:gen_server, :start_link, [NoHandleInfo, nil, []]}
      })

    log =
      capture_log(fn ->
        send(pid, {:tick, 1})
        assert :gen_server.call(pid, :ping) == :pong
      end)

    assert log =~
             "Visor.ServerLogTest.NoHandleInfo dropped a message because it had no " <>
               "handle_info/2 loaded: {:tick, 1}"
  end

  test "writes a file per start, with the supervisor reports Elixir leaves out",
       %{tmp_dir: dir} do
    on_exit(fn -> ServerLog.install(nil) end)
    assert {:ok, path} = ServerLog.install(dir)
    assert Path.dirname(path) == dir
    assert Path.basename(path) =~ ~r/^\d{4}-\d\d-\d\dT\d{6}\.jsonl$/

    bad = %{id: :bad, start: {Function, :identity, [{:error, :nope}]}}
    tree = %{id: :tree, start: {Supervisor, :start_link, [[bad], [strategy: :one_for_one]]}}
    capture_log(fn -> assert {:error, _} = start_supervised(tree) end)

    assert [report] =
             Enum.filter(
               lines(:visor_server_log, path),
               &(&1["domain"] == ~w(visor supervisor_report))
             )

    assert report["level"] == "error"
    assert report["message"] =~ "Child :bad of Supervisor"
    assert report["message"] =~ "failed to start"
    assert report["message"] =~ ":nope"

    # The console leaves them out, since the crash itself is there.
    {:ok, %{filters: filters}} = :logger.get_handler_config(:default)
    assert {_id, {console, arg}} = List.keyfind(filters, :visor_server_log, 0)
    event = %{level: :error, msg: {:string, ""}, meta: %{domain: ~w(visor supervisor_report)a}}
    assert console.(event, arg) == :stop

    # Installing again replaces the filter rather than adding a second one.
    assert :ok = ServerLog.install(nil)
    %{filters: filters} = :logger.get_primary_config()

    assert [{:visor_server_log, {_fun, %{supervisor_reports: false}}}] =
             Enum.filter(filters, &(elem(&1, 0) == :visor_server_log))

    assert {:error, _} = :logger.get_handler_config(:visor_server_log)
    {:ok, %{filters: filters}} = :logger.get_handler_config(:default)
    refute List.keymember?(filters, :visor_server_log, 0)
  end
end
