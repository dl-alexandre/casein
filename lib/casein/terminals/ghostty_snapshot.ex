defmodule Casein.Terminals.GhosttySnapshot do
  @moduledoc """
  Captures `Ghostty.Terminal` cell grids in HTML / plain / VT formats and
  writes them to disk under a workspace- and timestamp-scoped basename.

  Extracted from `CaseinWeb.WorkspaceLive.Show` so the LiveView source stays
  write-free for the `Casein.ProposalsNoApplyTest` boundary guard. Snapshot
  writes are diagnostic artifacts (terminal state dumps), not workspace
  mutations, so they belong outside the LiveView.
  """

  @formats [{:html, ".html"}, {:plain, ".txt"}, {:vt, ".vt"}]
  @preview_bytes 400

  # Snapshots are diagnostic dumps consumed immediately by the caller; they were
  # never cleaned up and leaked into `/tmp` indefinitely (thousands of
  # `ghostty_snapshot_*` files observed on the devbox). Keep only the newest few
  # per workspace so the directory stays bounded regardless of capture volume.
  @keep_per_workspace 9

  @type capture :: %{
          required(String.t()) => term()
        }

  @type result :: %{
          base: String.t(),
          files: [capture()],
          preview: String.t()
        }

  @spec capture(pid(), String.t()) :: result()
  # sobelow_skip ["Traversal.FileModule"]
  def capture(term, workspace_id) when is_pid(term) and is_binary(workspace_id) do
    ts = System.system_time(:millisecond)
    base = Path.join(snapshot_dir(), "ghostty_snapshot_#{workspace_id}_#{ts}")

    File.mkdir_p!(snapshot_dir())

    captures =
      Enum.map(@formats, fn {format, ext} ->
        case Ghostty.Terminal.snapshot(term, format) do
          {:ok, data} ->
            path = base <> ext
            File.write!(path, data)

            {format,
             %{
               "format" => Atom.to_string(format),
               "path" => path,
               "bytes" => byte_size(data)
             }, data}

          other ->
            {format, %{"format" => Atom.to_string(format), "error" => inspect(other)}, ""}
        end
      end)

    prune_old_snapshots(workspace_id)

    files = Enum.map(captures, fn {_f, meta, _data} -> meta end)

    preview =
      Enum.find_value(captures, "", fn
        {:plain, _meta, data} when is_binary(data) and data != "" ->
          String.slice(data, 0, @preview_bytes)

        _ ->
          nil
      end)

    %{base: base, files: files, preview: preview}
  end

  defp snapshot_dir, do: Application.get_env(:casein, :ghostty_snapshot_dir, "/tmp")

  # Best-effort retention: keep only the newest @keep_per_workspace snapshot files
  # for this workspace and delete the rest, so repeated captures cannot accumulate
  # unbounded diagnostic dumps in the snapshot directory.
  # sobelow_skip ["Traversal.FileModule"]
  defp prune_old_snapshots(workspace_id) do
    snapshot_dir()
    |> Path.join("ghostty_snapshot_#{workspace_id}_*")
    |> Path.wildcard()
    |> Enum.sort_by(&file_mtime/1, :desc)
    |> Enum.drop(@keep_per_workspace)
    |> Enum.each(&File.rm/1)
  rescue
    _ -> :ok
  end

  defp file_mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime
      _ -> 0
    end
  end
end
