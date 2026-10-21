defmodule Visor.ServerLog do
  @moduledoc """
  Writes everything the server logs to `log/server/<start>.jsonl`, one
  file per server start, one JSON object per line. This catches what the
  session logs can't: crashes in the process tree or the web server,
  supervisor restarts and anything else logged outside a session.
  `mix visor.log server` reads it.

  Each line has `at` (local time to the millisecond, like the session
  logs), `level`, `message`, and where it came from when known: `pid`,
  `mfa`, `file`, `line`, `domain` and the rest of the `metadata`.

  Two kinds of report that Elixir's logger drops are kept:

    * a GenServer that got a message while it had no `handle_info/2`
      loaded. In dev that happens when the message arrives while Mix
      recompiles the module, and the message is lost. These show on the
      console too.
    * a supervisor's report of a child that crashed, failed to start or
      made it give up. These go to the file only, since the crash itself
      is already on the console.

  `config :visor, server_log_dir: path` sets the directory; `false` turns
  the file off.
  """

  require Logger

  @handler :visor_server_log
  @filter :visor_server_log

  @doc "The directory server logs go to, or `nil` when the file is off."
  def dir do
    case Application.get_env(:visor, :server_log_dir, "log/server") do
      dir when is_binary(dir) -> Path.expand(dir)
      _off -> nil
    end
  end

  @doc """
  Adds the filter that keeps the reports above and, unless the file is
  off, the handler that writes it. Safe to call again: what an earlier
  call added is replaced.
  """
  def install(dir \\ dir()) do
    %{filters: filters} = :logger.get_primary_config()

    # Ahead of Elixir's translator, which drops both kinds of report.
    ours = {&__MODULE__.filter/2, %{supervisor_reports: dir != nil}}

    :ok =
      :logger.update_primary_config(%{
        filters: [{@filter, ours} | List.keydelete(filters, @filter, 0)]
      })

    :logger.remove_handler(@handler)
    :logger.remove_handler_filter(:default, @filter)

    if dir do
      File.mkdir_p!(dir)
      path = Path.join(dir, Calendar.strftime(NaiveDateTime.local_now(), "%Y-%m-%dT%H%M%S.jsonl"))
      :ok = add_handler(@handler, path)
      :logger.add_handler_filter(:default, @filter, {&__MODULE__.console/2, []})
      Logger.info("Writing the server log to #{Path.relative_to_cwd(path)}")
      {:ok, path}
    else
      :ok
    end
  end

  @doc false
  # A handler that writes this log to `path`; tests add their own.
  def add_handler(id, path) do
    :logger.add_handler(id, :logger_std_h, %{
      level: :all,
      config: %{file: String.to_charlist(path)},
      formatter: {__MODULE__, %{}}
    })
  end

  @doc false
  def filter(
        %{msg: {:report, %{label: {:gen_server, :no_handle_info}} = report}, meta: meta} = event,
        _config
      ) do
    message = inspect(report.message, limit: 50, printable_limit: 4096)

    text =
      "#{inspect(report.module)} dropped a message because it had no handle_info/2 " <>
        "loaded: #{message}. In dev this happens when the message arrives while " <>
        "Mix recompiles the module."

    %{event | msg: {:string, text}, meta: Map.delete(meta, :report_cb)}
  end

  def filter(
        %{
          level: level,
          msg: {:report, %{label: {:supervisor, _} = label, report: report}},
          meta: %{domain: [:otp, :sasl | _]} = meta
        } = event,
        %{supervisor_reports: true}
      )
      when level in [:error, :critical, :alert, :emergency] do
    text =
      case Logger.Translator.translate(:debug, level, :report, {label, report}) do
        {:ok, text} -> text
        _skipped -> :logger_formatter.format(event, %{template: [:msg], single_line: false})
      end

    meta = meta |> Map.delete(:report_cb) |> Map.put(:domain, [:visor, :supervisor_report])
    %{event | msg: {:string, text}, meta: meta}
  rescue
    _error -> :ignore
  end

  def filter(_event, _config), do: :ignore

  @doc false
  # Keeps supervisor reports off the console.
  def console(%{meta: %{domain: [:visor, :supervisor_report]}}, _config), do: :stop
  def console(_event, _config), do: :ignore

  @doc false
  # The formatter `:logger_std_h` calls for each line.
  def check_config(_config), do: :ok

  @doc false
  def format(%{level: level, meta: meta} = event, _config) do
    {known, rest} = Map.split(meta, [:pid, :mfa, :file, :line, :domain])

    rest =
      Map.drop(rest, [
        :time,
        :gl,
        :report_cb,
        :error_logger,
        :logger_formatter,
        # The message has the crash, stacktrace included.
        :crash_reason
      ])

    fields =
      [
        {"at", at(meta)},
        {"level", Atom.to_string(level)},
        {"message", message(event)},
        {"pid", known[:pid] && inspect(known[:pid])},
        {"mfa", mfa(known[:mfa])},
        {"file", known[:file] && to_string(known[:file])},
        {"line", known[:line]},
        {"domain", known[:domain] && Visor.SessionLog.json(known[:domain])},
        {"metadata", if(rest != %{}, do: Visor.SessionLog.json(rest))}
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    [Jason.encode_to_iodata!(Jason.OrderedObject.new(fields)), ?\n]
  rescue
    error ->
      line = %{
        "at" => at(meta),
        "level" => to_string(level),
        "message" => inspect(event, limit: 50, printable_limit: 4096),
        "unformattable" => Exception.message(error)
      }

      [Jason.encode_to_iodata!(line), ?\n]
  end

  defp message(%{msg: {:string, text}}), do: text(text)

  defp message(event),
    do: text(:logger_formatter.format(event, %{template: [:msg], single_line: false}))

  defp text(chardata) do
    case :unicode.characters_to_binary(chardata) do
      text when is_binary(text) -> text
      _invalid -> inspect(chardata, limit: :infinity, printable_limit: :infinity)
    end
  end

  defp mfa({m, f, a}) when is_atom(m) and is_atom(f) and is_integer(a),
    do: Exception.format_mfa(m, f, a)

  defp mfa(_none), do: nil

  # Local time to the millisecond, to line up with the session logs.
  defp at(%{time: us}) do
    ms = div(us, 1000)

    ms
    |> div(1000)
    |> :calendar.system_time_to_local_time(:second)
    |> NaiveDateTime.from_erl!({rem(ms, 1000) * 1000, 3})
    |> NaiveDateTime.to_iso8601()
  end

  defp at(_meta), do: NaiveDateTime.to_iso8601(NaiveDateTime.local_now())
end
