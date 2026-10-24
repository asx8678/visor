defmodule Visor.Calls do
  @moduledoc """
  Where a function is called, for `V.calls/2`: found in the parsed code,
  after Vibe's structural (AST) search, rather than by text, so an
  alias, an import, a pipe or a capture still counts and a comment or a
  string doesn't. No dependency: `Code.string_to_quoted/2` and a walk.

  A reference is `"Mod.fun/2"`, `"Mod.fun"` (any arity) or
  `":ets.lookup/2"`. Within the file, `alias` (with `as:` and the
  `alias Mod.{A, B}` form) and `import` (with `only:`) are followed, and
  so are local calls in the function's own module. What a macro expands
  to, or a module put in a variable, can't be told from the source.
  """

  alias Visor.{Limits, Tools}

  @doc "The calls of `ref` in the Elixir files under `path`, as `%{file, line, text}`."
  def find(ref, path) do
    with {:ok, target} <- parse(ref),
         {:ok, files} <- files(path) do
      calls =
        files
        |> Enum.flat_map(&in_file(&1, target))
        |> Enum.take(Limits.grep_matches())

      {:ok, calls}
    end
  end

  defp parse(ref) do
    case Regex.run(~r{\A(:?[A-Za-z_][\w.]*?)\.([a-z_][\w]*[?!]?)(?:/(\d+))?\z}, ref) do
      [_, module, fun] ->
        {:ok, %{module: module, fun: fun, arity: nil}}

      [_, module, fun, arity] ->
        {:ok, %{module: module, fun: fun, arity: String.to_integer(arity)}}

      nil ->
        {:error,
         ~s|#{inspect(ref)} isn't a function: give Module.function/arity, such as "Enum.map/2".|}
    end
  end

  defp files(path) do
    pattern =
      if String.ends_with?(path, [".ex", ".exs"]),
        do: path,
        else: Path.join(path, "**/*.{ex,exs}")

    Tools.glob(pattern)
  end

  defp in_file(path, target) do
    with {:ok, source} <- Tools.read(path, Limits.grep_file_bytes()),
         {:ok, ast} <- Code.string_to_quoted(source, columns: true) do
      lines = String.split(source, "\n")

      ast
      |> walk(%{module: nil, aliases: %{}, imports: []}, target, [])
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(fn line ->
        %{file: path, line: line, text: String.trim(Enum.at(lines, line - 1, ""))}
      end)
    else
      _unreadable -> []
    end
  end

  ## The walk: each node with the module, aliases and imports in force

  # A module inside another is named under it, and aliased in it.
  defp walk({:defmodule, _, [name, [do: body]]}, scope, target, found) do
    module =
      case {scope.module, name} do
        {nil, _} ->
          qualify(name, scope)

        {outer, {:__aliases__, _, parts}} ->
          Enum.join([outer | Enum.map(parts, &Atom.to_string/1)], ".")

        {_outer, other} ->
          qualify(other, scope)
      end

    scope =
      if scope.module,
        do: put_alias(scope, module |> String.split(".") |> List.last(), module),
        else: scope

    walk(body, %{scope | module: module, imports: []}, target, found)
  end

  # A definition's head isn't a call; its guards and body may hold some.
  defp walk({kind, _, [head | body]}, scope, target, found)
       when kind in [:def, :defp, :defmacro, :defmacrop] do
    found =
      case head do
        {:when, _, [_call | guards]} -> walk(guards, scope, target, found)
        _call -> found
      end

    walk(body, scope, target, found)
  end

  defp walk({:__block__, _, exprs}, scope, target, found) do
    {_scope, found} =
      Enum.reduce(exprs, {scope, found}, fn expr, {scope, found} ->
        {directive(expr, scope), walk(expr, scope, target, found)}
      end)

    found
  end

  # x |> Mod.fun(a) calls Mod.fun/2.
  defp walk({:|>, _, [left, right]}, scope, target, found) do
    found = walk(left, scope, target, found)

    case right do
      {call, meta, args} when is_list(args) ->
        found = if match?(call, args, 1, scope, target), do: [meta[:line] | found], else: found
        walk_args(args, scope, target, found)

      other ->
        walk(other, scope, target, found)
    end
  end

  # &Mod.fun/2
  defp walk({:&, meta, [{:/, _, [{call, _, []}, arity]}]} = node, scope, target, found)
       when is_integer(arity) do
    if capture?(call, arity, scope, target),
      do: [meta[:line] | found],
      else: walk_children(node, scope, target, found)
  end

  defp walk({call, meta, args} = node, scope, target, found) when is_list(args) do
    found = if match?(call, args, 0, scope, target), do: [meta[:line] | found], else: found
    walk_children(node, scope, target, found)
  end

  defp walk(list, scope, target, found) when is_list(list),
    do: Enum.reduce(list, found, &walk(&1, scope, target, &2))

  defp walk({left, right}, scope, target, found),
    do: walk(right, scope, target, walk(left, scope, target, found))

  defp walk(_leaf, _scope, _target, found), do: found

  defp walk_children({call, _meta, args}, scope, target, found) do
    found = if is_tuple(call), do: walk(call, scope, target, found), else: found
    walk_args(args, scope, target, found)
  end

  defp walk_args(args, scope, target, found), do: walk(args, scope, target, found)

  ## Directives

  defp directive({:alias, _, [{:__aliases__, _, _} = name]}, scope) do
    full = qualify(name, scope)
    put_alias(scope, full |> String.split(".") |> List.last(), full)
  end

  defp directive(
         {:alias, _, [{:__aliases__, _, _} = name, [as: {:__aliases__, _, [as]}]]},
         scope
       ),
       do: put_alias(scope, Atom.to_string(as), qualify(name, scope))

  defp directive({:alias, _, [{{:., _, [base, :{}]}, _, names}]}, scope) do
    base = qualify(base, scope)

    Enum.reduce(names, scope, fn {:__aliases__, _, parts}, scope ->
      full = base <> "." <> Enum.map_join(parts, ".", &Atom.to_string/1)
      put_alias(scope, Atom.to_string(List.last(parts)), full)
    end)
  end

  defp directive({:import, _, [module | opts]}, scope) do
    only =
      case opts do
        [[only: list]] when is_list(list) ->
          Enum.map(list, fn {name, arity} -> {Atom.to_string(name), arity} end)

        _ ->
          :all
      end

    %{scope | imports: [{qualify(module, scope), only} | scope.imports]}
  end

  # A module defined inside another is an alias for the rest of it.
  defp directive(
         {:defmodule, _, [{:__aliases__, _, [_ | _] = parts}, _body]},
         %{module: outer} = scope
       )
       when is_binary(outer) do
    full = Enum.join([outer | Enum.map(parts, &Atom.to_string/1)], ".")
    put_alias(scope, Atom.to_string(List.last(parts)), full)
  end

  defp directive(_expr, scope), do: scope

  defp put_alias(scope, short, full), do: %{scope | aliases: Map.put(scope.aliases, short, full)}

  ## Matching

  defp match?({:., _, [module, fun]}, args, extra, scope, target) when is_atom(fun),
    do: remote?(module, fun, length(args) + extra, scope, target)

  defp match?(fun, args, extra, scope, target) when is_atom(fun),
    do: local?(fun, length(args) + extra, scope, target)

  defp match?(_call, _args, _extra, _scope, _target), do: false

  defp capture?({:., _, [module, fun]}, arity, scope, target) when is_atom(fun),
    do: remote?(module, fun, arity, scope, target)

  defp capture?(fun, arity, scope, target) when is_atom(fun),
    do: local?(fun, arity, scope, target)

  defp capture?(_call, _arity, _scope, _target), do: false

  defp remote?(module, fun, arity, scope, target) do
    Atom.to_string(fun) == target.fun and arity?(arity, target) and
      qualify(module, scope) == target.module
  end

  # A call without a module: the module's own function, or an import's.
  defp local?(fun, arity, scope, target) do
    name = Atom.to_string(fun)

    name == target.fun and arity?(arity, target) and
      (scope.module == target.module or
         Enum.any?(scope.imports, fn {module, only} ->
           module == target.module and (only == :all or {name, arity} in only)
         end))
  end

  defp arity?(_arity, %{arity: nil}), do: true
  defp arity?(arity, %{arity: arity}), do: true
  defp arity?(_arity, _target), do: false

  # A module's name as written, with the file's aliases and __MODULE__
  # resolved: "Mod.Name", or ":ets" for an Erlang module.
  defp qualify({:__aliases__, _, [:__MODULE__ | rest]}, scope),
    do: Enum.join([scope.module | Enum.map(rest, &Atom.to_string/1)], ".")

  defp qualify({:__aliases__, _, [first | rest]}, scope) when is_atom(first) do
    first = Atom.to_string(first)
    head = Map.get(scope.aliases, first, first)
    Enum.join([head | Enum.map(rest, &Atom.to_string/1)], ".")
  end

  defp qualify({:__MODULE__, _, _}, scope), do: scope.module
  defp qualify(module, _scope) when is_atom(module), do: inspect(module)
  defp qualify(_other, _scope), do: nil
end
