defmodule Visor.Agent.Event do
  @moduledoc """
  The events a console session publishes, as `{:agent, event}` on the
  session's topic. The console (`VisorWeb.HarnessLive`) shows them and
  `Visor.SessionLog` writes them, under the same names, for
  `mix visor.log` to read back; their maps' keys become the log line's
  JSON keys, so a key changed here changes what old logs mean.

  From `Visor.Agent`, for each prompt:

    * `{:user, text}`: a prompt the user sent
    * `{:wake, text}`: a prompt of the agent's own, `text` being the
      notices of background jobs that ended while it was idle (see
      `Visor.Jobs`); its steps follow as a user prompt's do
    * `{:steer, text}`: a message the user sent while a prompt ran. It
      reaches the model as a user message after the running tool calls'
      results, or, when the model answers first, comes back as the next
      prompt's `{:user, text}`; a stopped prompt drops it
    * `{:turn_start, %{turn, step, max_steps, provider, effort, thinking,
      messages, pid}}`: a model call started, in task `pid`
    * `{:request, turn, preview}`: the request, shortened for the console,
      as a map the console turns into JSON
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
      call and the result the model saw. A batch's calls run one at a
      time; one cancelled before its turn starts with a nil `pid` and
      ends straight away
    * `{:prompt_end, %{reason, steps}}`: the prompt ended and why
    * `{:compaction, %{turn, reason, summarized, kept, tokens_before,
      tokens_after, summary_bytes, messages_before, messages_after}}`: the
      first `summarized` messages became a summary (see
      `Visor.Compaction`), because the context passed its threshold
      (`:threshold`), the user asked (`:manual`) or the provider rejected a
      request as too long (`:overflow`). Tokens are estimates
    * `{:repeat, %{id, count, blocked}}`: tool call `id` runs the same
      script as the `count - 1` before it, back to back. From
      `Visor.Limits.repeat_warn/0` in a row its result says so; at
      `repeat_block/0` it isn't run (`blocked: true`)
    * `{:repair, %{reason, answered, dropped}}`: tool calls without
      results were answered and results without calls dropped (see
      `Visor.Agent.Repair`), when the agent restarted mid-batch
      (`:restart`) or before a request (`:request`)
    * `{:status, :idle | :streaming | :tools}`, `{:note, :info | :error, text}`,
      `{:settings, settings}` and `{:context, message_count}`

  From `Visor.Jobs`, for each background job, as `Visor.Jobs.public/1`
  gives it (`id`, `kind`, `label`, `status`, `exit`, `ms`, `timeout_ms`,
  `log`, `tail`, `os_pid`, `acknowledged`):

    * `{:job_start, job}` and `{:job_end, job}`: a job started, and ended
      with `status` `:exited`, `:failed`, `:killed` or `:timed_out`

  From `Visor.Code`, for each `elixir` script, keyed by its tool call id:

    * `{:code_call, call_id, call}`: a `V` call, first `status: :running`,
      then `:ok` with what it `returned` or `:error` with its `error`
      (see `V`)
    * `{:script_end, call_id, %{status, stdio, ...}}`: the script's whole
      output and value, before they were cut for the model
  """

  @type call_id :: String.t()
  @type turn :: pos_integer()

  @typedoc "Why a prompt ended."
  @type reason ::
          :answered
          | :max_tokens
          | :interrupted
          | :model_crashed
          | :model_error
          | :step_limit
          | :unfinished

  @typedoc "A tool call, as `tool_start` and `tool_end` carry it."
  @type tool_call :: %{
          required(:id) => call_id(),
          required(:name) => String.t(),
          required(:arguments) => String.t(),
          required(:status) => :running | :ok | :error,
          optional(:pid) => pid() | nil,
          optional(:result) => String.t(),
          optional(:ms) => non_neg_integer() | nil
        }

  @type t ::
          {:user, String.t()}
          | {:wake, String.t()}
          | {:steer, String.t()}
          | {:turn_start, map()}
          | {:request, turn(), map()}
          | {:wire_request, turn(), %{url: String.t(), body: term()}}
          | {:wire_response, turn(), map()}
          | {:stream, turn(), Visor.Model.snapshot()}
          | {:turn_end,
             %{
               required(:turn) => turn(),
               required(:finish_reason) => String.t() | nil,
               optional(atom()) => term()
             }}
          | {:tool_start, tool_call()}
          | {:tool_end, tool_call()}
          | {:prompt_end, %{reason: reason(), steps: non_neg_integer()}}
          | {:compaction,
             %{required(:reason) => :threshold | :manual | :overflow, optional(atom()) => term()}}
          | {:repeat, %{id: call_id(), count: pos_integer(), blocked: boolean()}}
          | {:repair,
             %{
               reason: :restart | :request,
               answered: non_neg_integer(),
               dropped: non_neg_integer()
             }}
          | {:status, :idle | :streaming | :tools}
          | {:note, :info | :error, String.t()}
          | {:settings, map()}
          | {:context, non_neg_integer()}
          | {:code_call, call_id(),
             %{required(:status) => :running | :ok | :error, optional(atom()) => term()}}
          | {:script_end, call_id(), map()}
          | {:job_start, map()}
          | {:job_end, map()}

  @doc "Subscribes the caller to session `id`'s events."
  @spec subscribe(term()) :: :ok | {:error, term()}
  def subscribe(id), do: Phoenix.PubSub.subscribe(Visor.PubSub, topic(id))

  @doc "Publishes an event of session `id`."
  @spec broadcast(term(), t()) :: :ok | {:error, term()}
  def broadcast(id, event), do: Phoenix.PubSub.broadcast(Visor.PubSub, topic(id), {:agent, event})

  defp topic(id), do: "agent:#{id}"
end
