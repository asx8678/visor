defmodule Visor.Agent.Event do
  @moduledoc """
  The events a console session publishes, as `{:agent, event}` on the
  session's topic. The console (`VisorWeb.HarnessLive`) shows them and
  `Visor.SessionLog` writes them, under the same names, for
  `mix visor.log` to read back; their maps' keys become the log line's
  JSON keys, so a key changed here changes what old logs mean.

  From `Visor.Agent`, for each prompt:

    * `{:user, text}`: a prompt the user sent
    * `{:turn_start, %{turn, step, max_steps, provider, effort, thinking,
      messages, pid}}`: a model call started, in task `pid`
    * `{:request, turn, json}`: the request, shortened for the console
    * `{:wire_request, turn, %{url, body}}` and `{:wire_response, turn,
      %{status, headers} | %{error}}`: the request as sent and what came
      back, for the session log
    * `{:stream, turn, snapshot}`: the response so far (`t:Visor.Model.snapshot/0`)
    * `{:turn_end, %{turn, finish_reason}}`: the model call ended; when it
      answered, also `usage` (the provider's map, read with
      `Visor.Usage.from/1`), `model`, `chunks`, `ttft_ms`, `ms` and `final`
      (its `reasoning`, `content` and `tool_calls`)
    * `{:tool_start, %{id, name, arguments, status: :running, pid}}` and
      `{:tool_end, %{id, name, arguments, status, result, ms}}`: a tool
      call and the result the model saw
    * `{:prompt_end, %{reason, steps}}`: the prompt ended and why
    * `{:status, :idle | :streaming | :tools}`, `{:note, :info | :error, text}`,
      `{:settings, settings}` and `{:context, message_count}`

  From `Visor.Code`, for each `elixir` script, keyed by its tool call id:

    * `{:code_call, call_id, call}`: a `V` call, first `status: :running`,
      then `:ok` with what it `returned` or `:error` with its `error`
      (see `V`)
    * `{:script_end, call_id, %{status, stdio, ...}}`: the script's whole
      output and value, before they were cut for the model
  """

  @type t :: tuple()

  @doc "Subscribes the caller to session `id`'s events."
  def subscribe(id), do: Phoenix.PubSub.subscribe(Visor.PubSub, topic(id))

  @doc "Publishes an event of session `id`."
  def broadcast(id, event), do: Phoenix.PubSub.broadcast(Visor.PubSub, topic(id), {:agent, event})

  defp topic(id), do: "agent:#{id}"
end
