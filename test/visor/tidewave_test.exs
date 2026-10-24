defmodule Visor.TidewaveTest do
  # V.tidewave calls the running app's Tidewave tools, which run in the
  # app, not in Visor.
  use ExUnit.Case, async: false

  alias Visor.Code

  setup do
    server =
      start_supervised!(
        {Bandit, plug: Visor.TidewavePlug, ip: :loopback, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    Application.put_env(:visor, :tidewave_url, "http://127.0.0.1:#{port}/tidewave/mcp")
    on_exit(fn -> Application.delete_env(:visor, :tidewave_url) end)
    %{port: port}
  end

  test "lists the app's tools and calls one, with what it answered" do
    assert {:ok, text} = Code.run(~S[V.tidewave() |> Enum.map(& &1.name)], %{})
    assert text =~ ~s(=> ["project_eval", "get_logs"])

    assert {:ok, text} = Code.run(~S|V.tidewave("project_eval", %{code: "1 + 1"})|, %{})
    assert text =~ ~s(=> "evaluated: 1 + 1")

    assert {:error, text} = Code.run(~S|V.tidewave("nope")|, %{})
    assert text =~ "Tidewave's nope failed: Unknown tool nope"
  end

  test "says where it looked when no app answers" do
    Application.put_env(:visor, :tidewave_url, "http://127.0.0.1:1/tidewave/mcp")
    assert {:error, text} = Code.run(~S|V.tidewave()|, %{})
    assert text =~ "No Tidewave at http://127.0.0.1:1/tidewave/mcp"
    assert text =~ "Set VISOR_TIDEWAVE_URL"
  end
end
