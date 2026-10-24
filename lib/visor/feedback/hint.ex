defmodule Visor.Feedback.Hint do
  @moduledoc """
  One line of advice under a script's error, for the mistakes models make
  with `V` and the sandbox: a `V` function that doesn't exist or was
  called with the wrong arguments, and a restricted function that has a
  `V` counterpart.

      failed after 0 calls:
        ** (DuneRestrictedError) function File.read!/1 is restricted
      hint: scripts reach the project through V: use V.read(path).

  `V`'s functions and their signatures come from the module and its docs,
  so the advice always matches what scripts can call.
  """

  # Restricted functions with a V counterpart, by module and name.
  @counterparts %{
    {"File", "read"} => "V.read(path)",
    {"File", "read!"} => "V.read(path)",
    {"File", "write"} => "V.write(path, contents)",
    {"File", "write!"} => "V.write(path, contents)",
    {"File", "ls"} => "V.ls(path)",
    {"File", "ls!"} => "V.ls(path)",
    {"File", "exists?"} => "V.exists?(path)",
    {"File", "regular?"} => "V.exists?(path)",
    {"File", "dir?"} => "V.exists?(path) or V.ls(path)",
    {"Path", "wildcard"} => "V.glob(pattern)",
    {"System", "cmd"} => "V.sh(command)",
    {"System", "shell"} => "V.sh(command)",
    {":os", "cmd"} => "V.sh(command)"
  }

  @doc "The hint for a failed script's error message, or nil."
  @spec for_error(String.t()) :: String.t() | nil
  def for_error(message) do
    cond do
      match = Regex.run(~r/function V\.([\w?!]+)\/(\d+) is undefined/, message) ->
        [_, name, arity] = match
        undefined(name, String.to_integer(arity))

      match = Regex.run(~r/no function clause matching in V\.([\w?!]+)\/\d+/, message) ->
        [_, name] = match

        "the arguments don't fit #{signatures(name)}: paths, patterns, commands and " <>
          "contents are strings."

      match = Regex.run(~r/undefined variable "(\w+)"/, message) ->
        [_, name] = match

        "#{name} isn't set: a script keeps the variables of the scripts before it only " <>
          "within one prompt (the last result's footer lists them). Set it again."

      match = Regex.run(~r/function ([\w.:]+)\.([\w?!]+)\/\d+ is restricted/, message) ->
        [_, module, name] = match
        restricted(module, name)

      match = Regex.run(~r/function (\w+)\/\d+ is restricted/, message) ->
        [_, name] = match
        restricted(name)

      true ->
        nil
    end
  end

  @doc """
  The hint for a script that failed before its first V call, from its
  failure's `type` and `message` and its code, or nil. These are the ways
  models got a file's text into a script wrong in live runs (the 3D
  watch's session lost 5 of its 24 calls to them):

    * text right after a heredoc's opening `\"""`, as in Python
    * a heredoc whose text holds a line that starts with `\"""` (a Python
      docstring in a shell command), which ends the heredoc there
    * the whole script sent as a quoted string, its quotes escaped
    * a sigil whose text holds its closing delimiter, so `~s|a |> b|`
      or `~s(f(x))` ends early (the first live run's model, and this
      hint's own tests, wrote both)
  """
  @spec for_script(atom(), String.t(), String.t()) :: String.t() | nil
  def for_script(type, message, code) do
    cond do
      type == :parsing and message =~ "heredoc allows only whitespace characters" ->
        delim = if String.ends_with?(message, "'''"), do: "'''", else: ~s(""")

        "a heredoc's text starts on the line after its opening #{delim} (or ~S#{delim}): " <>
          "put a newline right after it and the closing #{delim} on a line of its own. " <>
          "For one line of text, use ~S[...] or ~S{...}, a delimiter it doesn't hold."

      type == :parsing and code =~ ~r/^[ \t]*"""[ \t]*[A-Za-z_\[{']/m ->
        ~s|a heredoc ends at the first line that starts with """, so text that holds such | <>
          ~s|a line (a Python docstring, another heredoc) ends it early: put that text in | <>
          ~s|~S''' and ''' instead.|

      quoted?(code) ->
        ~s|the script came as one quoted string, its quotes escaped (\\"): send the code | <>
          "itself, with its quotes as they are."

      # A heredoc sigil (~S\"""...) can't end on its delimiter's character.
      type == :parsing and code =~ ~r/~[a-zA-Z]+(?:[|\/(\[{<]|"(?!"")|'(?!''))/ ->
        "if a sigil's text holds its closing delimiter (| in ~s|...|, ) in ~s(...)), the " <>
          "sigil ends there: give it a delimiter its text doesn't use, such as ~s[...] or " <>
          ~s|~s{...}, or a heredoc (~S""" on a line of its own).|

      true ->
        nil
    end
  end

  defp quoted?(code) do
    trimmed = String.trim_leading(code)
    String.starts_with?(trimmed, ~s|"\n|) and length(String.split(trimmed, ~S|\"|)) > 3
  end

  defp undefined(name, arity) do
    known = functions()

    cond do
      Map.has_key?(known, name) ->
        "V.#{name} has no #{arity}-argument form, and no keyword options: " <>
          "#{signatures(name)}."

      closest = closest(name, known) ->
        "V has no #{name}; did you mean #{signatures(closest)}? V has #{names(known)}."

      true ->
        "V has no #{name}. V has #{names(known)}."
    end
  end

  defp restricted(module, name) do
    case Map.get(@counterparts, {module, name}) do
      nil when module in ["File", "Path", "System", ":os", ":file"] ->
        "scripts reach the project only through V, which has #{names(functions())}."

      nil ->
        nil

      counterpart ->
        "scripts reach the project through V: use #{counterpart}."
    end
  end

  defp restricted(name) when name in ["import", "alias", "require"],
    do: "#{name} isn't available; write a module's full name, such as Enum.map/2."

  defp restricted("try"),
    do:
      "try isn't available, and a failing V call stops the script: check first, such as " <>
        "V.exists?(path) before V.read(path)."

  defp restricted(name) when name in ["spawn", "spawn_link", "send", "receive"],
    do: "a script runs in one process; make its V calls one after another."

  defp restricted(_name), do: nil

  defp signatures(name) do
    functions() |> Map.fetch!(name) |> Enum.map_join(" or ", &("V." <> &1))
  end

  defp closest(name, known) do
    {best, score} =
      known
      |> Map.keys()
      |> Enum.map(&{&1, String.jaro_distance(name, &1)})
      |> Enum.max_by(&elem(&1, 1), fn -> {nil, 0.0} end)

    if score >= 0.7, do: best
  end

  defp names(known), do: known |> Map.keys() |> Enum.sort() |> Enum.join(", ")

  # V's functions a script may call, by name, each with its signatures.
  # A signature with defaults covers its shorter forms; without docs in
  # the build, it is name/arity.
  defp functions do
    docs =
      case Code.fetch_docs(V) do
        {:docs_v1, _, _, _, _, _, docs} ->
          for {{:function, name, arity}, _, [sig | _], _, _} <- docs, do: {name, arity, sig}

        _no_docs ->
          []
      end

    allowed =
      for {name, arity} <- V.__info__(:functions),
          Visor.Code.Allowlist.fun_status(V, name, arity) == :allowed,
          not String.starts_with?(Atom.to_string(name), "__"),
          do: {name, arity}

    allowed
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {name, arities} ->
      sigs = for {^name, _arity, sig} <- docs, do: sig
      sigs = if sigs == [], do: Enum.map(arities, &"#{name}/#{&1}"), else: Enum.uniq(sigs)
      {Atom.to_string(name), sigs}
    end)
  end
end
