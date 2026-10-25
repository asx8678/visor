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

  @typedoc """
  `compact_tokens` is the context size that compacts the conversation,
  when the provider sets one (see `Visor.Compaction`).
  """
  @type info :: %{
          required(:provider) => String.t(),
          required(:model) => String.t(),
          required(:endpoint) => String.t() | nil,
          required(:max_tokens) => pos_integer() | nil,
          required(:context_window) => pos_integer() | nil,
          optional(:compact_tokens) => pos_integer() | nil,
          required(:key) => atom()
        }

  @callback info() :: info()
  @type emitted :: snapshot() | {:request, map()} | {:response, map()}

  @doc """
  `{:error, :context_overflow, message}` is a request the provider
  rejected as too large: longer than the model's window, or (HTTP 413)
  over the size it takes; the agent compacts the conversation and tries
  once more. `{:error, :rejected, message}` is one it refused as
  malformed (HTTP 400 or 422), which fails the prompt but not the
  provider's health (`Visor.ModelHealth`).
  """
  @callback stream(request(), emit :: (emitted() -> any())) ::
              {:ok, result()}
              | {:error, String.t()}
              | {:error, :context_overflow | :rejected, String.t()}

  @doc """
  The provider to use: DeepSeek, unless the config names another one, as
  the tests do with their scripted model.
  """
  def current, do: Application.get_env(:visor, :model_provider, Visor.Model.DeepSeek)
end
