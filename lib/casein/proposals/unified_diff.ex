defmodule Casein.Proposals.UnifiedDiff do
  @moduledoc """
  Tiny unified-diff header parser.

  Goals (M9):
    * Extract the set of changed paths from `--- a/<path>` / `+++ b/<path>`
      header pairs.
    * Treat `/dev/null` as a create/delete marker, never a path.
    * Reject any header path that would escape the workspace root when
      interpreted as a target.

  Non-goals: hunk semantic validation, three-way merge, binary patch sections.

  Public API returns a list of changes plus an `:invalid` flag if any header
  path escaped the root or was malformed.
  """

  alias Casein.Files.PathSafety

  @type range :: {non_neg_integer(), non_neg_integer()}
  @type hunk :: %{old_range: range(), new_range: range()}
  @type change :: %{path: String.t(), kind: :add | :delete | :modify}
  @type change_with_hunks :: %{path: String.t(), kind: :add | :delete | :modify, hunks: [hunk()]}

  @spec parse(binary(), String.t()) ::
          {:ok, [change()]} | {:error, :invalid_path | :no_headers}
  def parse(diff, root) when is_binary(diff) and is_binary(root) do
    pairs =
      diff
      |> String.split("\n")
      |> Enum.reduce({nil, []}, fn line, {pending, acc} ->
        case header(line) do
          {:minus, path} ->
            {{:minus, path}, acc}

          {:plus, plus_path} ->
            case pending do
              {:minus, minus_path} -> {nil, [{minus_path, plus_path} | acc]}
              _ -> {nil, acc}
            end

          :other ->
            {pending, acc}
        end
      end)
      |> elem(1)
      |> Enum.reverse()

    if pairs == [] do
      {:error, :no_headers}
    else
      classify(pairs, root)
    end
  end

  @doc """
  Like `parse/2` but also extracts hunk ranges per file. Each entry is
  `%{path, kind, hunks: [%{old_range: {start, count}, new_range: {start, count}}]}`.
  """
  @spec parse_with_hunks(binary(), String.t()) ::
          {:ok, [change_with_hunks()]} | {:error, :invalid_path | :no_headers}
  def parse_with_hunks(diff, root) when is_binary(diff) and is_binary(root) do
    files = collect_files(diff)

    if files == [] do
      {:error, :no_headers}
    else
      classify_with_hunks(files, root)
    end
  end

  defp collect_files(diff) do
    diff
    |> String.split("\n")
    |> Enum.reduce({nil, nil, []}, fn line, {pending, current, acc} ->
      case header(line) do
        {:minus, path} ->
          {{:minus, path}, current, append_current(current, acc)}

        {:plus, plus_path} ->
          case pending do
            {:minus, minus_path} ->
              {nil, %{minus: minus_path, plus: plus_path, hunks: []}, acc}

            _ ->
              {nil, current, acc}
          end

        :other ->
          case hunk_header(line) do
            {:ok, hunk} when not is_nil(current) ->
              {pending, %{current | hunks: [hunk | current.hunks]}, acc}

            _ ->
              {pending, current, acc}
          end
      end
    end)
    |> finalize_files()
  end

  defp append_current(nil, acc), do: acc
  defp append_current(file, acc), do: [%{file | hunks: Enum.reverse(file.hunks)} | acc]

  defp finalize_files({_, current, acc}) do
    current
    |> append_current(acc)
    |> Enum.reverse()
  end

  defp hunk_header("@@ " <> rest) do
    case Regex.run(~r/^-(\d+)(?:,(\d+))?\s+\+(\d+)(?:,(\d+))?\s+@@/, rest) do
      [_, old_s, old_c, new_s, new_c] ->
        {:ok, hunk_from(old_s, default(old_c, "1"), new_s, default(new_c, "1"))}

      [_, old_s, old_c, new_s] ->
        {:ok, hunk_from(old_s, default(old_c, "1"), new_s, "1")}

      [_, old_s, new_s] ->
        {:ok, hunk_from(old_s, "1", new_s, "1")}

      _ ->
        :error
    end
  end

  defp hunk_header(_), do: :error

  defp default("", d), do: d
  defp default(nil, d), do: d
  defp default(v, _), do: v

  defp hunk_from(os, oc, ns, nc) do
    %{
      old_range: {String.to_integer(os), String.to_integer(oc)},
      new_range: {String.to_integer(ns), String.to_integer(nc)}
    }
  end

  defp classify_with_hunks(files, root) do
    Enum.reduce_while(files, {:ok, []}, fn %{minus: minus, plus: plus, hunks: hunks},
                                           {:ok, acc} ->
      case kind_and_path(minus, plus) do
        {:invalid, _} ->
          {:halt, {:error, :invalid_path}}

        {kind, path} ->
          case Casein.Files.PathSafety.resolve(root, path) do
            {:ok, _} -> {:cont, {:ok, [%{path: path, kind: kind, hunks: hunks} | acc]}}
            {:error, _} -> {:halt, {:error, :invalid_path}}
          end
      end
    end)
    |> case do
      {:ok, list} -> {:ok, list |> Enum.reverse() |> Enum.uniq_by(& &1.path)}
      err -> err
    end
  end

  defp header("--- " <> rest), do: {:minus, strip_prefix(rest)}
  defp header("+++ " <> rest), do: {:plus, strip_prefix(rest)}
  defp header(_), do: :other

  defp strip_prefix(line) do
    line
    |> String.split("\t", parts: 2)
    |> List.first()
    |> String.trim()
    |> case do
      "a/" <> p -> p
      "b/" <> p -> p
      other -> other
    end
  end

  defp classify(pairs, root) do
    Enum.reduce_while(pairs, {:ok, []}, fn {minus, plus}, {:ok, acc} ->
      case kind_and_path(minus, plus) do
        {:invalid, _} ->
          {:halt, {:error, :invalid_path}}

        {kind, path} ->
          case PathSafety.resolve(root, path) do
            {:ok, _abs} -> {:cont, {:ok, [%{path: path, kind: kind} | acc]}}
            {:error, _} -> {:halt, {:error, :invalid_path}}
          end
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list) |> Enum.uniq_by(& &1.path)}
      err -> err
    end
  end

  defp kind_and_path("/dev/null", plus) when plus != "/dev/null", do: {:add, plus}
  defp kind_and_path(minus, "/dev/null") when minus != "/dev/null", do: {:delete, minus}
  defp kind_and_path("/dev/null", "/dev/null"), do: {:invalid, "/dev/null"}
  defp kind_and_path(_minus, plus) when is_binary(plus) and plus != "", do: {:modify, plus}
  defp kind_and_path(_, _), do: {:invalid, "?"}
end
