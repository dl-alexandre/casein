defmodule Casein.Files.Janitor do
  @moduledoc """
  Removes stale `.devide.tmp.*` sidecar files left by aborted atomic writes.

  Conservative on purpose:
    * Only files matching `.devide.tmp.*`.
    * Only files older than `:max_age_seconds` (default 1 hour).
    * Only inside an allowed workspace root (`PathSafety.resolve/2`-checked).

  Pure function `clean/2` is what tests target. The `run_on_boot/0` helper is
  a thin wrapper called from `Casein.Application.start/2`; it iterates the
  configured `:workspaces_roots` and is best-effort (errors are logged, never
  raised).
  """

  alias Casein.Files.PathSafety
  require Logger

  @prefix ".devide.tmp."
  @default_max_age 3600

  @doc """
  Walk `root` and delete `.devide.tmp.*` files older than `max_age_seconds`.

  Returns `{:ok, removed_paths}` or `{:error, reason}`. Refuses to operate
  if `root` does not resolve safely against itself (which catches a missing
  or non-directory root early).
  """
  @spec clean(String.t(), pos_integer()) ::
          {:ok, [String.t()]} | {:error, term()}
  def clean(root, max_age_seconds \\ @default_max_age) when is_binary(root) do
    with {:ok, abs_root} <- PathSafety.resolve(root, ""),
         true <- File.dir?(abs_root) || {:error, :no_root} do
      now = System.os_time(:second)
      cutoff = now - max_age_seconds
      {:ok, do_walk(abs_root, abs_root, cutoff, [])}
    else
      {:error, _} = err -> err
    end
  end

  def run_on_boot do
    for root <-
          Application.get_env(:casein, :workspaces_roots, []) ++
            [Application.get_env(:casein, :workspaces_root, "/workspaces")],
        root,
        File.dir?(root) do
      case clean(root) do
        {:ok, []} ->
          :ok

        {:ok, removed} ->
          Logger.info("janitor removed #{length(removed)} stale temp files in #{root}")

        {:error, reason} ->
          Logger.warning("janitor skipped #{root}: #{inspect(reason)}")
      end
    end

    :ok
  end

  defp do_walk(root, dir, cutoff, acc) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.reduce(names, acc, fn name, acc ->
          path = Path.join(dir, name)

          case File.lstat(path) do
            {:ok, %File.Stat{type: :directory}} ->
              # Skip ignored dirs and symlinked dirs to avoid wandering outside.
              if PathSafety.ignored_dir?(name), do: acc, else: do_walk(root, path, cutoff, acc)

            {:ok, %File.Stat{type: :regular, mtime: mtime}} ->
              if String.starts_with?(name, @prefix) and stale?(mtime, cutoff) and
                   under?(path, root) do
                _ = File.rm(path)
                [path | acc]
              else
                acc
              end

            _ ->
              acc
          end
        end)

      _ ->
        acc
    end
  end

  defp stale?({{y, mo, d}, {h, mi, s}}, cutoff) do
    {:ok, dt} = NaiveDateTime.new(y, mo, d, h, mi, s)
    NaiveDateTime.diff(dt, ~N[1970-01-01 00:00:00]) < cutoff
  end

  defp stale?(_, _), do: false

  defp under?(path, root) do
    rel = Path.relative_to(Path.expand(path), root)
    rel != path and not String.starts_with?(rel, "..")
  end
end
