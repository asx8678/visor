defmodule Mix.Tasks.Visor.ImportDeepseek do
  @shortdoc "Copies the DeepSeek key, endpoint and model from pi or opencode into .env"

  @moduledoc """
  Copies the DeepSeek setup that pi or opencode uses into the workspace's
  `.env` file, so Visor calls the same endpoint with the same key, model
  and output limit:

      $ mix visor.import_deepseek
      $ mix visor.import_deepseek --model flash --from pi

  It reads pi's `models.json`, `settings.json` and `auth.json` in
  `~/.pi/agent`, opencode's global config in `~/.config/opencode` and the
  keys `opencode auth login` saved in `~/.local/share/opencode`, which
  `PI_CODING_AGENT_DIR`, `XDG_CONFIG_HOME`, `XDG_DATA_HOME` and
  `OPENCODE_CONFIG` move as they do for the tools. Of the providers whose
  ID, name, endpoint or models mention DeepSeek, it takes the tool's
  default model, or a provider's only model, and writes:

    * `DEEPSEEK_API_KEY`, which it never prints
    * `DEEPSEEK_BASE_URL`
    * `DEEPSEEK_MODEL`
    * `DEEPSEEK_MAX_TOKENS`, when the model's settings give an output limit

  Earlier values of these are replaced, and the rest of `.env` is kept.
  It doesn't run the commands pi can get a key from, so a key that comes
  from one has to be added to `.env` by hand.

  ## Options

    * `--model` - the model: its ID, or part of its ID or name, such as `flash`
    * `--from` - `pi` or `opencode`, or one provider, such as `pi:deepseek`,
      which then doesn't need to mention DeepSeek
    * `--home` - read the tools' files under this folder instead of `~`,
      ignoring the variables that move them
  """
  use Mix.Task

  @requirements ["app.config"]

  # Formats that speak OpenAI's chat completions, like Visor's client:
  # pi's API names and the AI SDK packages opencode uses.
  @chat_format ~w(openai-completions @ai-sdk/openai-compatible @ai-sdk/openai @ai-sdk/deepseek)

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args, strict: [model: :string, from: :string, home: :string])

    paths = paths(opts[:home])
    found = pi(paths) ++ opencode(paths)

    choice =
      found
      |> candidates(opts[:from], paths)
      |> options()
      |> pick_model(opts[:model])
      |> choose()

    if choice.api && choice.api not in @chat_format do
      Mix.shell().error(
        "#{label(choice)} uses the #{choice.api} API, but Visor only speaks OpenAI's " <>
          "chat completions format, so requests may fail."
      )
    end

    model = choice.model
    max_tokens = if model && is_integer(model.output) && model.output > 0, do: model.output
    path = Path.join(Visor.Tools.workspace(), ".env")

    write_env(path, [
      {"DEEPSEEK_API_KEY", choice.key},
      {"DEEPSEEK_BASE_URL", choice.base_url},
      {"DEEPSEEK_MODEL", model && model.id},
      {"DEEPSEEK_MAX_TOKENS", max_tokens}
    ])

    Mix.shell().info("""
    Copied DeepSeek from #{label(choice)} into #{path}:
      DEEPSEEK_API_KEY     copied, not shown
      DEEPSEEK_BASE_URL    #{shown(choice.base_url)}
      DEEPSEEK_MODEL       #{model_text(model)}
      DEEPSEEK_MAX_TOKENS  #{max_tokens || "not set, so DeepSeek's default applies"}
    Visor reads .env on every request, so the next message uses these.\
    """)
  end

  # Where the tools keep their files. --home stands in for ~, and then the
  # environment variables that point elsewhere are ignored.
  defp paths(nil), do: paths(System.user_home!(), System.get_env())
  defp paths(home), do: paths(Path.expand(home), %{})

  defp paths(home, env) do
    config = present(env["XDG_CONFIG_HOME"]) || Path.join(home, ".config")
    data = present(env["XDG_DATA_HOME"]) || Path.join(home, ".local/share")
    opencode = Path.join(config, "opencode")

    %{
      pi: Path.expand(present(env["PI_CODING_AGENT_DIR"]) || Path.join(home, ".pi/agent")),
      opencode_config:
        Enum.map(~w(config.json opencode.json opencode.jsonc), &Path.join(opencode, &1)) ++
          List.wrap(present(env["OPENCODE_CONFIG"])),
      opencode_auth: Path.join([data, "opencode", "auth.json"])
    }
  end

  defp pi(paths) do
    models = read_json(Path.join(paths.pi, "models.json"))
    settings = read_json(Path.join(paths.pi, "settings.json"))
    auth = read_json(Path.join(paths.pi, "auth.json"))
    configured = models["providers"] || %{}

    for id <- ids(configured, auth) do
      provider = configured[id] || %{}
      # pi prefers a key saved by /login to the one in models.json.
      keys = [saved_key(auth[id]), provider["apiKey"]]

      %{
        tool: "pi",
        id: id,
        name: provider["name"],
        base_url: text(provider["baseUrl"]) || default_url(id),
        key: Enum.find_value(keys, &pi_value/1),
        key_command?: Enum.any?(keys, &match?("!" <> _, &1)),
        api: provider["api"],
        # modelOverrides change the built-in models, which have no list here.
        models:
          Enum.uniq_by(models(provider["models"]) ++ models(provider["modelOverrides"]), & &1.id),
        default_model: if(settings["defaultProvider"] == id, do: settings["defaultModel"])
      }
    end
  end

  defp opencode(paths) do
    files = Enum.filter(paths.opencode_config, &File.regular?/1)
    config = files |> Enum.map(&read_json/1) |> Enum.reduce(%{}, &deep_merge(&2, &1))
    auth = read_json(paths.opencode_auth)
    dir = files |> Enum.map(&Path.dirname/1) |> List.last(File.cwd!())
    configured = config["provider"] || %{}
    default = String.split(config["model"] || "", "/", parts: 2)

    for id <- ids(configured, auth) do
      provider = configured[id] || %{}
      option = &substitute(get_in(provider, ["options", &1]), dir)

      # The config's own key wins over a saved one, then the provider's
      # environment variables.
      key =
        option.("apiKey") || saved_key(auth[id]) ||
          Enum.find_value(
            List.wrap(provider["env"]),
            &(is_binary(&1) && text(System.get_env(&1)))
          )

      %{
        tool: "opencode",
        id: id,
        name: provider["name"],
        base_url: option.("baseURL") || text(provider["api"]) || default_url(id),
        key: key,
        key_command?: false,
        api: provider["npm"],
        models: models(provider["models"]),
        default_model: if(match?([^id, _], default), do: List.last(default))
      }
    end
  end

  defp ids(configured, auth),
    do: (Map.keys(configured) ++ Map.keys(auth)) |> Enum.uniq() |> Enum.sort()

  # opencode lists models as a map, whose keys can stand for other IDs, and
  # pi as a list with "id" fields.
  defp models(%{} = models) do
    for({key, settings} <- models, is_map(settings), do: model(key, settings))
    |> Enum.sort_by(& &1.key)
  end

  defp models(models) when is_list(models),
    do: for(%{"id" => id} = settings <- models, is_binary(id), do: model(id, settings))

  defp models(_models), do: []

  # A pi model can have its own endpoint and API.
  defp model(key, settings) do
    %{
      key: key,
      id: text(settings["id"]) || key,
      name: settings["name"],
      base_url: text(settings["baseUrl"]),
      api: settings["api"],
      output: settings["maxTokens"] || get_in(settings, ["limit", "output"])
    }
  end

  # The built-in DeepSeek providers have no endpoint in the config.
  defp default_url("deepseek"), do: "https://api.deepseek.com"
  defp default_url(_id), do: nil

  # pi fills in "$NAME" and "${NAME}" from the environment and drops a value
  # whose variable isn't set; "$$" and "$!" stand for "$" and "!". It runs
  # "!command" for its output, which this task leaves to pi. A bare name
  # such as DEEPSEEK_API_KEY is looked up too, since no real key looks like
  # one.
  defp pi_value("!" <> _command), do: nil

  defp pi_value(value) when is_binary(value) do
    if value =~ ~r/^[A-Z][A-Z0-9_]*$/ do
      text(System.get_env(value))
    else
      ~r/\$(?:([$!])|\{(\w+)\}|(\w+))/
      |> Regex.replace(value, fn
        _, "", braced, bare -> present(System.get_env(braced <> bare)) || throw(:unset)
        _, escaped, _, _ -> escaped
      end)
      |> text()
    end
  catch
    :unset -> nil
  end

  defp pi_value(_value), do: nil

  # opencode fills in {env:NAME} and {file:path} in config values.
  defp substitute(value, dir) when is_binary(value) do
    value = Regex.replace(~r/\{env:([^}]+)\}/, value, fn _, name -> System.get_env(name, "") end)
    text(Regex.replace(~r/\{file:([^}]+)\}/, value, fn _, file -> read_text(file, dir) end))
  end

  defp substitute(_value, _dir), do: nil

  defp read_text(file, dir) do
    case File.read(Path.expand(file, dir)) do
      {:ok, text} -> String.trim(text)
      {:error, _} -> ""
    end
  end

  defp saved_key(%{"type" => "oauth"}), do: nil
  defp saved_key(%{} = saved), do: text(saved["key"] || saved["apiKey"])
  defp saved_key(saved), do: text(saved)

  defp deepseek?(provider) do
    names = Enum.flat_map(provider.models, &[&1.key, &1.id, &1.name, &1.base_url])

    Enum.any?(
      [provider.id, provider.name, provider.base_url, provider.default_model | names],
      &(is_binary(&1) and &1 =~ ~r/deepseek/i)
    )
  end

  defp candidates(found, nil, paths) do
    case Enum.filter(found, &deepseek?/1) do
      [] when found != [] ->
        Mix.raise(
          "Found no DeepSeek provider. pi and opencode have #{labels(found)}. " <>
            "Name the one to copy, such as --from #{label(hd(found))}"
        )

      [] ->
        Mix.raise(
          "Found no pi or opencode settings in #{paths.pi}, " <>
            "#{paths.opencode_config |> hd() |> Path.dirname()} or #{paths.opencode_auth}. " <>
            "Use --home if they live under another folder."
        )

      deepseek ->
        deepseek
    end
  end

  defp candidates(found, from, _paths) do
    matching =
      case String.split(from, ":", parts: 2) do
        [tool] -> Enum.filter(found, &(&1.tool == tool and deepseek?(&1)))
        _provider -> Enum.filter(found, &(label(&1) == from))
      end

    if matching == [],
      do: Mix.raise("Nothing matches --from #{from}. pi and opencode have #{labels(found)}."),
      else: matching
  end

  # One option for each model a provider lists, or for its default model.
  defp options(providers) do
    for provider <- providers, model <- choices(provider) do
      Map.merge(provider, %{
        model: model,
        base_url: (model && model.base_url) || provider.base_url,
        api: (model && model.api) || provider.api
      })
    end
  end

  defp choices(%{models: [_ | _] = models}), do: models
  defp choices(%{default_model: id}) when is_binary(id), do: [model(id, %{})]
  defp choices(_provider), do: [nil]

  defp pick_model(options, nil) do
    case Enum.filter(options, &(&1.model && &1.model.key == &1.default_model)) do
      [] -> options
      defaults -> defaults
    end
  end

  defp pick_model(options, wanted) do
    listed = Enum.filter(options, & &1.model)
    exact = Enum.filter(listed, &(wanted in [&1.model.key, &1.model.id]))
    partial = Enum.filter(listed, &mentions?(&1.model, wanted))

    cond do
      exact != [] -> exact
      partial != [] -> partial
      true -> Mix.raise("No model matches --model #{wanted}. Found:\n" <> list(options))
    end
  end

  defp mentions?(model, wanted) do
    Enum.any?([model.key, model.id, model.name], fn text ->
      is_binary(text) and String.contains?(String.downcase(text), String.downcase(wanted))
    end)
  end

  defp choose(options) do
    usable = Enum.filter(options, &(&1.key && &1.base_url))

    case Enum.uniq_by(usable, &{&1.base_url, &1.key, &1.model && &1.model.id}) do
      [choice] ->
        choice

      [] ->
        Mix.raise(
          "Found DeepSeek, but no setup with both an API key this shell can see and " <>
            "an endpoint:\n" <>
            (options
             |> Enum.map(&(describe(&1) <> ": " <> lacks(&1)))
             |> Enum.uniq()
             |> Enum.join("\n"))
        )

      several ->
        Mix.raise(
          "Found several DeepSeek setups:\n" <>
            list(several) <> "\nPick one with --from or --model, such as --model flash."
        )
    end
  end

  defp lacks(option) do
    key =
      cond do
        option.key -> nil
        option.key_command? -> "pi runs a command for its key, so add DEEPSEEK_API_KEY to .env"
        true -> "no API key"
      end

    [key, if(!option.base_url, do: "no endpoint")]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" and ")
  end

  defp list(options), do: options |> Enum.map(&describe/1) |> Enum.uniq() |> Enum.join("\n")

  defp describe(option) do
    model = if option.model, do: " #{option.model.id}", else: ""
    host = if option.base_url, do: " at #{URI.parse(option.base_url).host}", else: ""
    "  #{label(option)}#{model}#{host}"
  end

  defp label(provider), do: "#{provider.tool}:#{provider.id}"
  defp labels([]), do: "no providers"
  defp labels(found), do: found |> Enum.map(&label/1) |> Enum.join(", ")

  defp model_text(nil), do: "not set, so Visor uses its configured model"
  defp model_text(%{id: id, name: nil}), do: id
  defp model_text(%{id: id, name: name}), do: "#{id} (#{name})"

  # Replaces the DeepSeek lines in .env and keeps the rest. The file holds
  # the key, so only its owner can read it.
  defp write_env(path, values) do
    kept =
      case File.read(path) do
        {:ok, contents} ->
          ~r/^[ \t]*(?:export[ \t]+)?DEEPSEEK_(?:API_KEY|BASE_URL|MODEL|MAX_TOKENS)[ \t]*=.*\n?/m
          |> Regex.replace(contents, "")
          |> String.trim_trailing()

        {:error, :enoent} ->
          ""
      end

    added = for {name, value} <- values, value, into: "", do: "#{name}=#{value}\n"
    File.touch!(path)
    File.chmod!(path, 0o600)
    File.write!(path, if(kept == "", do: added, else: kept <> "\n" <> added))
  end

  # The endpoint without the parts of a URL that can carry a secret.
  defp shown(url), do: URI.to_string(%{URI.parse(url) | userinfo: nil, query: nil, fragment: nil})

  defp read_json(path) do
    case File.read(path) do
      {:ok, text} ->
        case text |> without_comments() |> Jason.decode() do
          {:ok, %{} = json} -> json
          _ -> Mix.raise("#{path} isn't valid JSON.")
        end

      {:error, :enoent} ->
        %{}

      {:error, reason} ->
        Mix.raise("Couldn't read #{path}: #{:file.format_error(reason)}")
    end
  end

  # The tools allow comments and trailing commas in their JSON. Strings
  # match first, so a "//" inside a URL stays.
  defp without_comments(text) do
    text
    |> outside_strings(~S"//[^\n]*|/\*.*?\*/")
    |> outside_strings(~S",(?=\s*[}\]])")
  end

  defp outside_strings(text, pattern) do
    (~S/"(?:[^"\\]|\\.)*"|/ <> pattern)
    |> Regex.compile!("s")
    |> Regex.replace(text, fn
      "\"" <> _ = string -> string
      _ -> ""
    end)
  end

  defp deep_merge(base, overrides) do
    Map.merge(base, overrides, fn
      _key, %{} = left, %{} = right -> deep_merge(left, right)
      _key, _left, right -> right
    end)
  end

  defp text(value) when is_binary(value), do: present(String.trim(value))
  defp text(_value), do: nil

  defp present(""), do: nil
  defp present(value), do: value
end
