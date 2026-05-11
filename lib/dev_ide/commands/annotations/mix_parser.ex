defmodule DevIDE.Commands.Annotations.MixParser do
  @moduledoc """
  Cheap line-based parser for the Mix output shapes we surface today.

  Patterns:

    * `warning: <msg>` followed (eventually) by a `└─ file:line[:col]:` or
      a bare `  file:line[:col]:` reference.
    * `** (CompileError) file:line: msg` (and other `** (XxxError)` shapes).
    * ExUnit failure references like `test/foo_test.exs:27`.
    * Formatter output:
        mix format failed due to --check-formatted.
        The following files are not formatted:
          lib/foo.ex

  Anything matching is also run through `DevIDE.Files.PathSafety.resolve/2`.
  Annotations whose path escapes the workspace root are dropped — the UI
  must never invite the user to open an unsafe path.
  """

  alias DevIDE.Commands.Annotations.Annotation
  alias DevIDE.Files.PathSafety

  @file_line_re ~r{(?<file>[A-Za-z0-9_./-]+\.(?:ex|exs|eex|heex|leex|sface)):(?<line>\d+)(?::(?<col>\d+))?}

  @spec parse(binary() | nil, String.t() | nil, String.t() | nil) :: [Annotation.t()]
  def parse(output, command_id, root) when is_binary(output) and is_binary(root) do
    lines = String.split(output, "\n")

    {anns, _state} =
      Enum.reduce(lines, {[], :idle}, fn line, {acc, state} ->
        step(line, state, acc, command_id)
      end)

    anns
    |> Enum.reverse()
    |> resolve_paths(root)
    |> dedupe()
  end

  def parse(_, _, _), do: []

  ## State machine

  # Compile error inline form
  defp step("** (" <> _ = line, state, acc, command_id) do
    case Regex.run(~r/^\*\* \(([A-Za-z0-9_.]+Error)\)\s+(.*)$/, line) do
      [_, _name, rest] ->
        case Regex.named_captures(@file_line_re, rest) do
          %{"file" => file, "line" => l, "col" => col} ->
            msg = String.trim(String.replace(rest, ~r/^[^ ]+:\d+(?::\d+)?:?\s*/, ""))
            ann = build(:compile_error, :error, file, l, col, msg, command_id)
            {[ann | acc], state}

          _ ->
            {acc, state}
        end

      _ ->
        {acc, state}
    end
  end

  # Plain "warning: ..." line — stash the message until a file:line follows.
  defp step("warning: " <> msg, _state, acc, command_id),
    do: {acc, {:warning, String.trim(msg), command_id}}

  # New-style fenced reference: "└─ file:line:col: …"
  defp step(line, {:warning, msg, command_id} = state, acc, _) do
    case Regex.named_captures(@file_line_re, line) do
      %{"file" => file, "line" => l, "col" => col} ->
        ann = build(:compile_warning, :warning, file, l, col, msg, command_id)
        {[ann | acc], :idle}

      _ ->
        if String.trim(line) == "" do
          # blank line resets the warning context after a while
          {acc, state}
        else
          {acc, state}
        end
    end
  end

  # Formatter header
  defp step("The following files are not formatted:", _, acc, command_id),
    do: {acc, {:formatter, command_id}}

  defp step(line, {:formatter, command_id} = state, acc, _) do
    case String.trim(line) do
      "" ->
        {acc, :idle}

      file ->
        if Regex.match?(~r{^[A-Za-z0-9_./-]+\.(ex|exs|eex|heex|leex|sface)$}, file) do
          ann = build(:formatter, :warning, file, nil, nil, "needs formatting", command_id)
          {[ann | acc], state}
        else
          {acc, :idle}
        end
    end
  end

  # ExUnit-style "1) test ..." header — start watching for a `_test.exs:line`.
  defp step(line, state, acc, command_id) do
    cond do
      Regex.match?(~r/^\s*\d+\)\s+test\s/, line) ->
        {acc, {:test, command_id}}

      true ->
        maybe_test_failure(line, state, acc, command_id)
    end
  end

  defp maybe_test_failure(line, {:test, command_id} = _state, acc, _) do
    case Regex.named_captures(~r{(?<file>[A-Za-z0-9_./-]+_test\.exs):(?<line>\d+)}, line) do
      %{"file" => file, "line" => l} ->
        msg = String.trim(line)
        ann = build(:test_failure, :error, file, l, nil, msg, command_id)
        {[ann | acc], :idle}

      _ ->
        {acc, {:test, command_id}}
    end
  end

  defp maybe_test_failure(_line, state, acc, _command_id), do: {acc, state}

  ## Builder + filtering

  defp build(kind, severity, file, line, col, msg, command_id) do
    %Annotation{
      kind: kind,
      severity: severity,
      file: file,
      line: line && String.to_integer(line),
      column: col && to_int(col),
      message: msg,
      command_id: command_id
    }
  end

  defp to_int(nil), do: nil
  defp to_int(""), do: nil
  defp to_int(n) when is_integer(n), do: n
  defp to_int(s) when is_binary(s), do: String.to_integer(s)

  defp resolve_paths(anns, root) do
    Enum.flat_map(anns, fn %Annotation{file: f} = a ->
      case PathSafety.resolve(root, f) do
        {:ok, abs} ->
          [%{a | stale: not File.exists?(abs)}]

        _ ->
          []
      end
    end)
  end

  defp dedupe(anns) do
    Enum.uniq_by(anns, fn a -> {a.kind, a.file, a.line, a.column, a.message} end)
  end
end
