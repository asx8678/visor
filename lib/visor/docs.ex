defmodule Visor.Docs do
  @moduledoc """
  Documentation and source locations for `V.docs/1` and `V.source/1`,
  after Tidewave's `get_docs` and `get_source_location`: read from the
  project's compiled `.beam` files, so they are the versions the project
  depends on, and never loaded or run in Visor's VM. Elixir's and
  Erlang's own modules come from this VM.

  A reference is a module (`"Req"`, `":ets"`), a function in one
  (`"Req.get"`, `"Req.get/2"`), or `"dep:req"` for a dependency's folder.
  """

  alias Visor.{Tools, Workspace}

  @max_bytes 16_000

  @doc "The docs for `ref`, as text: signatures, then the doc."
  def docs(ref) do
    with {:ok, parsed} <- parse(ref),
         {:ok, beam} <- beam(parsed.module) do
      case Code.fetch_docs(beam) do
        {:docs_v1, _anno, _lang, _format, moduledoc, _meta, entries} ->
          {:ok, render(parsed, moduledoc, entries) |> cut()}

        _none ->
          {:error, "#{parsed.module} was compiled without docs."}
      end
    end
  end

  @doc """
  Where `ref` is defined: `%{file: path, line: n}`, the path relative to
  the project when it is in it. A dependency's folder for `"dep:name"`.
  """
  def source("dep:" <> name) do
    path = Path.join("deps", name)

    case Tools.exists(path) do
      {:ok, true} -> {:ok, %{file: path}}
      _ -> {:error, "There is no dependency #{name} in deps/."}
    end
  end

  def source(ref) do
    with {:ok, parsed} <- parse(ref),
         {:ok, beam} <- beam(parsed.module),
         {:ok, file} <- source_file(beam) do
      # A doc's line is its @doc's; the definition follows it.
      line =
        case Code.fetch_docs(beam) do
          {:docs_v1, anno, _, _, _, _, entries} ->
            if parsed.fun do
              from = entry_line(entries, parsed) || 1
              def_line(file, parsed.fun, from) || (from > 1 && from) || nil
            else
              :erl_anno.line(anno)
            end

          _none ->
            parsed.fun && def_line(file, parsed.fun, 1)
        end

      if parsed.fun && line == nil,
        do: {:error, "#{ref} isn't defined in #{relative(file)}."},
        else: {:ok, %{file: relative(file), line: line}}
    end
  end

  ## References

  # "Mod.Name.fun/2" -> the module's words, the function from the first
  # lowercase word on. No atoms are made from what the model wrote.
  defp parse(ref) do
    case Regex.run(~r{\A(:?[A-Za-z_][\w.]*?)(?:\.([a-z_][\w]*[?!]?))?(?:/(\d+))?\z}, ref) do
      [_, module | rest] ->
        {fun, arity} =
          case rest do
            [] -> {nil, nil}
            [fun] -> {fun, nil}
            ["", arity] -> {nil, String.to_integer(arity)}
            [fun, arity] -> {fun, String.to_integer(arity)}
          end

        {:ok, %{module: module, fun: fun, arity: arity}}

      nil ->
        {:error,
         "#{inspect(ref)} isn't a reference: give a module, Module.function or " <>
           ~s|Module.function/arity, such as "Enum.map/2" or ":ets.lookup".|}
    end
  end

  # The project's compiled module first, then this VM's own (Elixir and
  # Erlang), by file name.
  defp beam(module) do
    file =
      if String.starts_with?(module, ":"),
        do: String.trim_leading(module, ":"),
        else: "Elixir." <> module

    root = Workspace.root()

    found =
      Enum.find_value(["dev", "test", "prod"], fn env ->
        root
        |> Path.join("_build/#{env}/lib/*/ebin/#{file}.beam")
        |> Path.wildcard()
        |> List.first()
      end) || own_beam(file)

    if found,
      do: {:ok, found},
      else:
        {:error,
         "There is no compiled module #{module} in the project, Elixir or Erlang. If it is " <>
           "the project's, compile it first (V.check)."}
  end

  # Only Elixir's and Erlang's own: this VM's copies of other libraries
  # may be other versions than the project's.
  defp own_beam(file) do
    with path when is_list(path) <- :code.where_is_file(String.to_charlist(file <> ".beam")),
         path = List.to_string(path),
         true <- String.starts_with?(path, [to_string(:code.root_dir()), elixir_lib()]) do
      path
    else
      _ -> nil
    end
  end

  defp elixir_lib, do: :elixir |> :code.lib_dir() |> to_string() |> Path.dirname()

  defp source_file(beam) do
    case :beam_lib.chunks(String.to_charlist(beam), [:compile_info]) do
      {:ok, {_module, [compile_info: info]}} when is_list(info) ->
        case info[:source] do
          nil -> {:error, "#{Path.basename(beam)} doesn't say where its source is."}
          source -> {:ok, to_string(source)}
        end

      _ ->
        {:error, "#{Path.basename(beam)} can't be read."}
    end
  end

  defp relative(file) do
    root = Workspace.root()
    if String.starts_with?(file, root <> "/"), do: Path.relative_to(file, root), else: file
  end

  ## Docs

  defp render(%{fun: nil} = parsed, moduledoc, entries) do
    functions =
      for {{kind, name, arity}, _anno, signatures, doc, _meta} <- entries,
          kind in [:function, :macro],
          doc != :hidden do
        line = signatures |> List.first() |> Kernel.||("#{name}/#{arity}")
        summary = doc |> text() |> first_sentence()
        if summary == "", do: "  #{line}", else: "  #{line}: #{summary}"
      end

    [parsed.module, text(moduledoc), "Functions and macros:\n" <> Enum.join(functions, "\n")]
    |> Enum.reject(&(&1 == "" or &1 == "Functions and macros:\n"))
    |> Enum.join("\n\n")
  end

  defp render(parsed, _moduledoc, entries) do
    case matching(entries, parsed) do
      [] ->
        "#{parsed.module} has no documented #{label(parsed)}."

      found ->
        Enum.map_join(found, "\n\n---\n\n", fn {{kind, name, arity}, _anno, signatures, doc, _} ->
          head = "#{parsed.module}.#{name}/#{arity}#{if kind == :macro, do: " (macro)", else: ""}"
          body = if doc == :hidden, do: "(hidden from the docs)", else: text(doc)
          Enum.join([head, Enum.join(signatures, "\n"), body] |> Enum.reject(&(&1 == "")), "\n\n")
        end)
    end
  end

  defp matching(entries, parsed) do
    for {{kind, name, arity}, _, _, _, _} = entry <- entries,
        kind in [:function, :macro],
        Atom.to_string(name) == parsed.fun,
        parsed.arity == nil or arity == parsed.arity or covers?(entry, parsed.arity),
        do: entry
  end

  # A function with default arguments documents its longest arity only.
  defp covers?({{_kind, _name, arity}, _, _, _, meta}, asked) do
    defaults = Map.get(meta, :defaults, 0)
    asked >= arity - defaults and asked <= arity
  end

  defp label(%{fun: fun, arity: nil}), do: "function #{fun}"
  defp label(%{fun: fun, arity: arity}), do: "function #{fun}/#{arity}"

  defp entry_line(entries, parsed) do
    case matching(entries, parsed) do
      [{_key, anno, _, _, _} | _] -> :erl_anno.line(anno)
      [] -> nil
    end
  end

  # The first clause of `fun` in the source from line `from` on; a private
  # function isn't in the docs, so it is found from the top.
  defp def_line(file, fun, from) do
    case File.read(file) do
      {:ok, source} ->
        pattern = ~r/^\s*(?:def|defp|defmacro|defmacrop)\s+#{Regex.escape(fun)}[\s(,]/

        source
        |> String.split("\n")
        |> Enum.drop(from - 1)
        |> Enum.find_index(&Regex.match?(pattern, &1))
        |> then(&(&1 && &1 + from))

      {:error, _} ->
        nil
    end
  end

  defp text(%{"en" => text}), do: String.trim(text)
  defp text(_none), do: ""

  defp first_sentence(text) do
    text |> String.split(~r/\.(\s|$)/, parts: 2) |> hd() |> String.replace("\n", " ")
  end

  defp cut(text) when byte_size(text) <= @max_bytes, do: text

  defp cut(text) do
    Tools.truncate(text, @max_bytes) <>
      "\n\n[Visor: the docs go on; ask for one function, as Module.function/arity.]"
  end
end
