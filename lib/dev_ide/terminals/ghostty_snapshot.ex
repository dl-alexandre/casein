defmodule DevIDE.Terminals.GhosttySnapshot do
  @moduledoc """
  Captures `Ghostty.Terminal` cell grids in HTML / plain / VT formats and
  writes them to disk under a workspace- and timestamp-scoped basename.

  Extracted from `DevIdeWeb.WorkspaceLive.Show` so the LiveView source stays
  write-free for the `DevIDE.ProposalsNoApplyTest` boundary guard. Snapshot
  writes are diagnostic artifacts (terminal state dumps), not workspace
  mutations, so they belong outside the LiveView.
  """

  @formats [{:html, ".html"}, {:plain, ".txt"}, {:vt, ".vt"}]
  @preview_bytes 400

  @type capture :: %{
          required(String.t()) => term()
        }

  @type result :: %{
          base: String.t(),
          files: [capture()],
          preview: String.t()
        }

  @spec capture(pid(), String.t()) :: result()
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

  defp snapshot_dir, do: Application.get_env(:dev_ide, :ghostty_snapshot_dir, "/tmp")
end
