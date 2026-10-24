defmodule Visor.ReplayTest do
  # A session's recorded replies played against the harness, after
  # BeamWeaver's replay transports: a run against the real model, once,
  # becomes a test that runs without it.
  use ExUnit.Case, async: false

  alias Visor.Agent
  alias Visor.Model.Replay

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    workspace = Application.get_env(:visor, :workspace)
    provider = Application.get_env(:visor, :model_provider)
    Application.put_env(:visor, :workspace, dir)
    Application.put_env(:visor, :model_provider, Replay)

    on_exit(fn ->
      Application.put_env(:visor, :workspace, workspace)
      Application.put_env(:visor, :model_provider, provider)
    end)

    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join(dir, "lib/greet.ex"), "defmodule Greet do\nend\n")
    id = "replay#{System.unique_integer([:positive])}"
    start_supervised!({Visor.Harness.Session, id: id, owner: self()})
    Agent.subscribe(id)
    %{id: id}
  end

  defp log(dir, replies) do
    path = Path.join(dir, "session.jsonl")

    lines = [
      %{event: "start", session: "old"} | Enum.map(replies, &Map.put(&1, :event, "turn_end"))
    ]

    File.write!(path, Enum.map_join(lines, "\n", &Jason.encode!/1) <> "\n")
    path
  end

  defp write_call(code),
    do: %{id: "c1", name: "elixir", arguments: Jason.encode!(%{code: code})}

  test "plays a logged session's replies, and runs their scripts for real", %{
    id: id,
    tmp_dir: dir
  } do
    code = ~S|V.write("lib/greet.ex", "defmodule Greet do\n  def hello, do: :hi\nend\n")|

    :ok =
      Replay.load(
        log(dir, [
          %{finish_reason: "tool_calls", tool_calls: [write_call(code)]},
          %{finish_reason: "stop", content: "Added Greet.hello/0."}
        ])
      )

    assert :ok = Agent.prompt(id, "Add Greet.hello.")
    assert_receive {:agent, {:prompt_end, %{reason: :answered, steps: 2}}}, 5_000
    assert File.read!(Path.join(dir, "lib/greet.ex")) =~ "def hello"
    assert Replay.left() == 0
  end

  # A harness that asks for more than the session did has diverged.
  test "fails when the harness asks for more replies than the log has", %{id: id, tmp_dir: dir} do
    :ok =
      Replay.load(log(dir, [%{finish_reason: "tool_calls", tool_calls: [write_call("1 + 1")]}]))

    assert :ok = Agent.prompt(id, "Add up.")
    assert_receive {:agent, {:note, :error, "The replay has no more replies" <> _}}, 5_000
    assert_receive {:agent, {:prompt_end, %{reason: :model_error}}}, 5_000
  end
end
