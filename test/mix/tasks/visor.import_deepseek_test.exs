defmodule Mix.Tasks.Visor.ImportDeepseekTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias Mix.Tasks.Visor.ImportDeepseek
  alias Visor.Model.DeepSeek

  @moduletag :tmp_dir
  @names ~w(DEEPSEEK_API_KEY DEEPSEEK_BASE_URL DEEPSEEK_MODEL DEEPSEEK_MAX_TOKENS
             DEEPSEEK_CONTEXT_WINDOW)

  setup %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:visor, :workspace)
    Application.put_env(:visor, :workspace, tmp_dir)
    Mix.shell(Mix.Shell.Process)

    # Settings in this shell's environment would win over .env.
    saved = for name <- @names, do: {name, System.get_env(name)}
    Enum.each(@names, &System.delete_env/1)

    on_exit(fn ->
      Application.put_env(:visor, :workspace, previous)
      Mix.shell(Mix.Shell.IO)

      for {name, value} <- saved do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end
    end)

    :ok
  end

  # The test's folder stands in for ~, where the tools keep their files.
  defp write(dir, path, contents) do
    path = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, if(is_binary(contents), do: contents, else: Jason.encode!(contents)))
  end

  defp import_deepseek(dir, args \\ []), do: ImportDeepseek.run(["--home", dir | args])

  defp env(dir), do: File.read!(Path.join(dir, ".env"))

  test "copies opencode's provider, default model and output limit, and never prints the key",
       %{tmp_dir: dir} do
    File.write!(
      Path.join(dir, ".env"),
      "# local settings\n\nPORT=4001\nDEEPSEEK_API_KEY=old\nexport DEEPSEEK_MODEL=old\n" <>
        "DEEPSEEK_MAX_TOKENS=1\n"
    )

    write(dir, ".config/opencode/opencode.jsonc", ~S"""
    {
      // The model opencode uses by default.
      "model": "ds/deepseek-v4.1-flash",
      "provider": {
        "ds": {
          "npm": "@ai-sdk/openai-compatible",
          "options": {"baseURL": "https://api.deepseek.com/v1/", "apiKey": "sk-test-1234",},
          "models": {
            "deepseek-v4.1-flash": {
              "name": "DeepSeek V4.1 Flash",
              "limit": {"context": 1048000, "output": 65536}
            },
            "deepseek-v4.1-pro": {},
          },
        },
        /* Not DeepSeek, so not a match. */
        "anthropic": {"options": {"apiKey": "sk-ant"}}
      }
    }
    """)

    import_deepseek(dir)

    assert env(dir) == """
           # local settings

           PORT=4001
           DEEPSEEK_API_KEY=sk-test-1234
           DEEPSEEK_BASE_URL=https://api.deepseek.com/v1/
           DEEPSEEK_MODEL=deepseek-v4.1-flash
           DEEPSEEK_MAX_TOKENS=65536
           DEEPSEEK_CONTEXT_WINDOW=1048000
           """

    assert (File.stat!(Path.join(dir, ".env")).mode &&& 0o777) == 0o600

    assert_received {:mix_shell, :info, [message]}

    assert message == """
           Copied DeepSeek from opencode:ds into #{dir}/.env:
             DEEPSEEK_API_KEY         copied, not shown
             DEEPSEEK_BASE_URL        https://api.deepseek.com/v1/
             DEEPSEEK_MODEL           deepseek-v4.1-flash (DeepSeek V4.1 Flash)
             DEEPSEEK_MAX_TOKENS      65536
             DEEPSEEK_CONTEXT_WINDOW  1048000
           Visor reads .env on every request, so the next message uses these.\
           """

    assert DeepSeek.api_key() == "sk-test-1234"

    assert %{
             model: "deepseek-v4.1-flash",
             endpoint: "https://api.deepseek.com/v1",
             max_tokens: 65536,
             context_window: 1_048_000,
             key: :dotenv
           } = DeepSeek.info()

    # The environment still wins over .env.
    System.put_env("DEEPSEEK_MODEL", "from-env")
    assert DeepSeek.info().model == "from-env"
  end

  test "copies pi's default model, with its own endpoint and the key pi would use",
       %{tmp_dir: dir} do
    System.put_env("VISOR_TEST_PI_KEY", "sk-pi")
    on_exit(fn -> System.delete_env("VISOR_TEST_PI_KEY") end)

    write(dir, ".pi/agent/models.json", %{
      "providers" => %{
        "deepseek" => %{
          "baseUrl" => "https://api.deepseek.com",
          "api" => "openai-completions",
          "apiKey" => "${VISOR_TEST_PI_KEY}",
          "models" => [
            %{"id" => "deepseek-v4.1-pro", "maxTokens" => 32768},
            %{
              "id" => "deepseek-v4.1-flash",
              "maxTokens" => 65536,
              "contextWindow" => 1_048_000,
              "baseUrl" => "https://flash.deepseek.test/v1"
            }
          ]
        }
      }
    })

    write(dir, ".pi/agent/settings.json", %{
      "defaultProvider" => "deepseek",
      "defaultModel" => "deepseek-v4.1-flash"
    })

    import_deepseek(dir)

    assert env(dir) ==
             "DEEPSEEK_API_KEY=sk-pi\nDEEPSEEK_BASE_URL=https://flash.deepseek.test/v1\n" <>
               "DEEPSEEK_MODEL=deepseek-v4.1-flash\nDEEPSEEK_MAX_TOKENS=65536\n" <>
               "DEEPSEEK_CONTEXT_WINDOW=1048000\n"

    assert_received {:mix_shell, :info, ["Copied DeepSeek from pi:deepseek into " <> _]}

    # As in pi, a key saved by /login wins over the one in models.json.
    write(dir, ".pi/agent/auth.json", %{
      "deepseek" => %{"type" => "api_key", "key" => "sk-saved"}
    })

    import_deepseek(dir, ["--model", "pro"])

    assert env(dir) ==
             "DEEPSEEK_API_KEY=sk-saved\nDEEPSEEK_BASE_URL=https://api.deepseek.com\n" <>
               "DEEPSEEK_MODEL=deepseek-v4.1-pro\nDEEPSEEK_MAX_TOKENS=32768\n"
  end

  test "reads pi's keys as pi does, and doesn't run key commands", %{tmp_dir: dir} do
    pi = fn key ->
      write(dir, ".pi/agent/models.json", %{
        "providers" => %{
          "deepseek" => %{"apiKey" => key, "models" => [%{"id" => "deepseek-v4.1-flash"}]}
        }
      })
    end

    pi.("sk-a$$b$!c")
    import_deepseek(dir)

    assert env(dir) ==
             "DEEPSEEK_API_KEY=sk-a$b!c\nDEEPSEEK_BASE_URL=https://api.deepseek.com\n" <>
               "DEEPSEEK_MODEL=deepseek-v4.1-flash\n"

    pi.("!echo sk-from-command")

    assert_raise Mix.Error,
                 ~r/at api.deepseek.com: pi runs a command for its key, so add DEEPSEEK_API_KEY/,
                 fn -> import_deepseek(dir) end

    pi.("$VISOR_NO_SUCH_VAR")
    assert_raise Mix.Error, ~r/: no API key$/, fn -> import_deepseek(dir) end
    assert env(dir) =~ "DEEPSEEK_API_KEY=sk-a$b!c\n"
  end

  test "uses a key from opencode auth login, and fills in {env:} and {file:}", %{tmp_dir: dir} do
    write(dir, ".config/opencode/opencode.json", ~S|{"model": "anthropic/claude"}|)

    write(dir, ".local/share/opencode/auth.json", %{
      "deepseek" => %{"type" => "api", "key" => "sk-saved"},
      "anthropic" => %{"type" => "oauth", "refresh" => "token"}
    })

    import_deepseek(dir)

    assert env(dir) == "DEEPSEEK_API_KEY=sk-saved\nDEEPSEEK_BASE_URL=https://api.deepseek.com\n"
    assert_received {:mix_shell, :info, [message]}
    assert message =~ "DEEPSEEK_MODEL           not set, so Visor uses its configured model\n"
    assert message =~ "DEEPSEEK_MAX_TOKENS      not set, so DeepSeek's default applies\n"
    assert message =~ "DEEPSEEK_CONTEXT_WINDOW  not set\n"

    write(dir, ".config/opencode/key.txt", "sk-from-file\n")
    System.put_env("VISOR_TEST_GATEWAY", "gateway.test")
    on_exit(fn -> System.delete_env("VISOR_TEST_GATEWAY") end)

    write(dir, ".config/opencode/opencode.json", ~S"""
    {"provider": {"gw": {
      "name": "DeepSeek through a gateway",
      "npm": "@ai-sdk/anthropic",
      "options": {"baseURL": "https://{env:VISOR_TEST_GATEWAY}/v1", "apiKey": "{file:key.txt}"},
      "models": {"flash": {"id": "deepseek-v4.1-flash"}, "pro": {"id": "deepseek-v4.1-pro"}}
    }}}
    """)

    import_deepseek(dir, ["--from", "opencode:gw", "--model", "flash"])

    assert env(dir) ==
             "DEEPSEEK_API_KEY=sk-from-file\nDEEPSEEK_BASE_URL=https://gateway.test/v1\n" <>
               "DEEPSEEK_MODEL=deepseek-v4.1-flash\n"

    assert_received {:mix_shell, :error, [warning]}
    assert warning =~ "opencode:gw uses the @ai-sdk/anthropic API"
  end

  test "asks which setup to copy, and writes nothing until it knows", %{tmp_dir: dir} do
    write(dir, ".config/opencode/opencode.json", ~S"""
    {"provider": {
      "deepseek": {"options": {"apiKey": "sk-1"}},
      "deepseek-proxy": {"options": {"baseURL": "https://proxy.test", "apiKey": "sk-2"},
                         "models": {"b": {}, "a": {}}}
    }}
    """)

    setups =
      "  opencode:deepseek at api.deepseek.com\n  opencode:deepseek-proxy a at proxy.test\n" <>
        "  opencode:deepseek-proxy b at proxy.test"

    assert_raise Mix.Error,
                 "Found several DeepSeek setups:\n#{setups}\n" <>
                   "Pick one with --from or --model, such as --model flash.",
                 fn -> import_deepseek(dir) end

    assert_raise Mix.Error, "No model matches --model c. Found:\n#{setups}", fn ->
      import_deepseek(dir, ["--model", "c"])
    end

    assert_raise Mix.Error,
                 "Nothing matches --from pi. pi and opencode have opencode:deepseek, " <>
                   "opencode:deepseek-proxy.",
                 fn -> import_deepseek(dir, ["--from", "pi"]) end

    nobody = Path.join(dir, "nobody")

    assert_raise Mix.Error,
                 "Found no pi or opencode settings in #{nobody}/.pi/agent, " <>
                   "#{nobody}/.config/opencode or #{nobody}/.local/share/opencode/auth.json. " <>
                   "Use --home if they live under another folder.",
                 fn -> ImportDeepseek.run(["--home", nobody]) end

    write(
      dir,
      ".config/opencode/opencode.json",
      ~S|{"provider": {"deepseek": {"options": {"apiKey": "{env:VISOR_NO_SUCH_VAR}"}}}}|
    )

    assert_raise Mix.Error,
                 "Found DeepSeek, but no setup with both an API key this shell can see and " <>
                   "an endpoint:\n  opencode:deepseek at api.deepseek.com: no API key",
                 fn -> import_deepseek(dir) end

    # A provider that never says DeepSeek can still be named.
    write(
      dir,
      ".config/opencode/opencode.json",
      ~S|{"provider": {"ds41": {"options": {"baseURL": "https://gw.test", "apiKey": "sk-3"}}}}|
    )

    assert_raise Mix.Error,
                 "Found no DeepSeek provider. pi and opencode have opencode:ds41. " <>
                   "Name the one to copy, such as --from opencode:ds41",
                 fn -> import_deepseek(dir) end

    refute File.exists?(Path.join(dir, ".env"))

    import_deepseek(dir, ["--from", "opencode:ds41"])
    assert env(dir) == "DEEPSEEK_API_KEY=sk-3\nDEEPSEEK_BASE_URL=https://gw.test\n"
  end
end
