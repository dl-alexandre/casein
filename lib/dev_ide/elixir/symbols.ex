defmodule DevIDE.Elixir.Symbols do
  @moduledoc """
  Regex-based symbol extractor for `.ex` / `.exs` source.

  Intentionally lightweight: a line-level scan, not an AST walk. It catches
  the shapes a developer actually uses for navigation — `defmodule`,
  `def`/`defp` (incl. `do:` shorthand), `defmacro`, `defdelegate`, `defguard`,
  and ExUnit `describe`/`test`. Anything more semantic belongs in M18+ once
  cross-file lookups become useful.

  HEEx is **not** supported yet — `.heex` files return `[]` so the UI can
  render a "HEEx symbols not supported yet" hint without errors.
  """

  alias DevIDE.Elixir.Symbol

  @ident "[A-Za-z_][A-Za-z0-9_!?]*"
  @module_path "[A-Z][A-Za-z0-9_.]*"

  @spec extract(content :: binary(), path :: String.t()) :: [Symbol.t()]
  def extract(content, path) when is_binary(content) and is_binary(path) do
    if elixir_source?(path) do
      content
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, lineno} ->
        match_line(String.trim_leading(line), lineno, path)
      end)
    else
      []
    end
  end

  def extract(_, _), do: []

  defp elixir_source?(path) do
    ext = path |> String.downcase() |> Path.extname()
    ext in [".ex", ".exs"]
  end

  ## Line matchers

  defp match_line(line, lineno, path) do
    cond do
      m = Regex.run(~r/^defmodule\s+(#{@module_path})\b/, line) ->
        [%Symbol{kind: :module, name: Enum.at(m, 1), line: lineno, visibility: :public}]

      m = match_def(line, "defp") ->
        [build_fun(:function, :private, m, lineno)]

      m = match_def(line, "def") ->
        [build_fun(:function, :public, m, lineno)]

      m = match_def(line, "defmacrop") ->
        [build_fun(:macro, :private, m, lineno)]

      m = match_def(line, "defmacro") ->
        [build_fun(:macro, :public, m, lineno)]

      m = match_def(line, "defguardp") ->
        [build_fun(:guard, :private, m, lineno)]

      m = match_def(line, "defguard") ->
        [build_fun(:guard, :public, m, lineno)]

      m = match_def(line, "defdelegate") ->
        [build_fun(:delegate, :public, m, lineno)]

      String.ends_with?(path, "_test.exs") ->
        match_test_line(line, lineno)

      true ->
        []
    end
  end

  defp match_test_line(line, lineno) do
    cond do
      name = match_string_block(line, "test") ->
        [%Symbol{kind: :test, name: name, line: lineno}]

      name = match_string_block(line, "describe") ->
        [%Symbol{kind: :describe, name: name, line: lineno}]

      true ->
        []
    end
  end

  defp match_def(line, kw) do
    re = ~r/^#{kw}\s+(?<name>#{@ident})(?:\((?<args>[^)]*)\))?/

    case Regex.named_captures(re, line) do
      %{"name" => name, "args" => args} -> {name, args}
      _ -> nil
    end
  end

  defp match_string_block(line, kw) do
    re = ~r/^#{kw}\s+"([^"]+)"/

    case Regex.run(re, line) do
      [_, name] -> name
      _ -> nil
    end
  end

  defp build_fun(kind, visibility, {name, args}, lineno) do
    arity = arity_of(args)
    full = "#{name}/#{arity}"
    %Symbol{kind: kind, visibility: visibility, name: full, arity: arity, line: lineno}
  end

  defp arity_of(nil), do: 0
  defp arity_of(""), do: 0

  defp arity_of(args) do
    args
    |> String.trim()
    |> case do
      "" -> 0
      s -> count_top_level_commas(s) + 1
    end
  end

  defp count_top_level_commas(s) do
    s
    |> String.to_charlist()
    |> Enum.reduce({0, 0, 0, 0}, fn ch, {parens, brackets, braces, commas} ->
      case ch do
        ?( ->
          {parens + 1, brackets, braces, commas}

        ?) ->
          {max(parens - 1, 0), brackets, braces, commas}

        ?[ ->
          {parens, brackets + 1, braces, commas}

        ?] ->
          {parens, max(brackets - 1, 0), braces, commas}

        ?{ ->
          {parens, brackets, braces + 1, commas}

        ?} ->
          {parens, brackets, max(braces - 1, 0), commas}

        ?, when parens == 0 and brackets == 0 and braces == 0 ->
          {parens, brackets, braces, commas + 1}

        _ ->
          {parens, brackets, braces, commas}
      end
    end)
    |> elem(3)
  end
end
