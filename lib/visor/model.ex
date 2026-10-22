defmodule Visor.Model do
  @moduledoc """
  A chat model the agent streams from.

  A provider receives the conversation and calls `emit` with a snapshot of
  the partial response (reasoning, content and tool calls so far) as it
  streams in, then returns the finished assistant message.

  For the session log, a provider that talks to an API also emits
  `{:request, %{url: url, body: body}}` with the body exactly as it sends
  it, before sending, and `{:response, info}` once the response is in:
  its `:status` and `:headers`, an error response's `:body`, or the
  `:error` when the request failed.
  """

  @type request :: %{
          system: String.t(),
          messages: [map()],
          tools: [map()],
          tool_choice: String.t(),
          effort: String.t(),
          thinking: boolean()
        }

  @type snapshot :: %{
          reasoning: String.t(),
          content: String.t(),
          tool_calls: [map()],
          chunks: non_neg_integer()
        }

  @type result :: %{
          message: map(),
          tool_calls: [map()],
          finish_reason: String.t() | nil,
          usage: map() | nil,
          model: String.t() | nil,
          chunks: non_neg_integer(),
          ttft_ms: non_neg_integer() | nil,
          ms: non_neg_integer()
        }

  @callback info() :: %{
              provider: String.t(),
              model: String.t(),
              endpoint: String.t() | nil,
              max_tokens: pos_integer() | nil,
              context_window: pos_integer() | nil,
              key: atom()
            }
  @type emitted :: snapshot() | {:request, map()} | {:response, map()}

  @callback stream(request(), emit :: (emitted() -> any())) ::
              {:ok, result()} | {:error, String.t()}

  @doc """
  The provider to use: DeepSeek, unless the config names another one, as
  the tests do with their scripted model.
  """
  def current, do: Application.get_env(:visor, :model_provider, Visor.Model.DeepSeek)
end
