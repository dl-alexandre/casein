defmodule DevIDE.Previews.Recordings do
  @moduledoc """
  Assembles client-streamed screen recordings and hands the finished file to
  `DevIDE.Previews.Storage`.

  The browser records the preview with `MediaRecorder` and POSTs the webm in
  ordered chunks. A webm is one continuous stream, so chunks must be concatenated
  in capture order or the file is unplayable. Each chunk is written to its own
  `{seq}.part` file under a per-recording temp dir; `finalize/2` concatenates them
  in numeric order into a single webm and stores it. Per-chunk files (rather than
  appending to one file) tolerate out-of-order arrival and retries.
  """

  alias DevIDE.Previews.Storage

  @default_max_bytes 200 * 1024 * 1024
  @id_pattern ~r/\A[A-Za-z0-9_-]{1,64}\z/

  @doc "Append one ordered chunk to a recording's temp dir."
  @spec append_chunk(String.t(), String.t(), non_neg_integer(), binary()) ::
          :ok | {:error, term()}
  def append_chunk(workspace_id, recording_id, seq, bytes)
      when is_binary(workspace_id) and is_binary(recording_id) and is_integer(seq) and seq >= 0 and
             is_binary(bytes) do
    with :ok <- validate_id(workspace_id),
         :ok <- validate_id(recording_id),
         dir <- recording_dir(workspace_id, recording_id),
         :ok <- File.mkdir_p(dir),
         :ok <- check_size(dir, byte_size(bytes)) do
      File.write(Path.join(dir, "#{seq}.part"), bytes)
    end
  end

  @doc """
  Concatenate a recording's chunks in order, store the webm, and clean up.

  Returns the browser-servable reference on success.
  """
  @spec finalize(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def finalize(workspace_id, recording_id)
      when is_binary(workspace_id) and is_binary(recording_id) do
    with :ok <- validate_id(workspace_id),
         :ok <- validate_id(recording_id),
         dir <- recording_dir(workspace_id, recording_id),
         {:ok, parts} <- ordered_parts(dir),
         {:ok, assembled} <- concat_parts(dir, parts),
         {:ok, ref} <- Storage.put(workspace_id, recording_id, "webm", {:file, assembled}) do
      _ = File.rm(assembled)
      cleanup(workspace_id, recording_id)
      {:ok, ref}
    else
      {:error, reason} ->
        cleanup(workspace_id, recording_id)
        {:error, reason}
    end
  end

  @doc "Best-effort removal of a recording's temp dir (e.g. on abort)."
  @spec cleanup(String.t(), String.t()) :: :ok
  def cleanup(workspace_id, recording_id) do
    with :ok <- validate_id(workspace_id), :ok <- validate_id(recording_id) do
      _ = File.rm_rf(recording_dir(workspace_id, recording_id))
      :ok
    else
      _ -> :ok
    end
  end

  defp ordered_parts(dir) do
    case File.ls(dir) do
      {:ok, []} ->
        {:error, :no_chunks}

      {:ok, entries} ->
        parts =
          entries
          |> Enum.filter(&String.ends_with?(&1, ".part"))
          |> Enum.map(&{part_seq(&1), Path.join(dir, &1)})
          |> Enum.reject(fn {seq, _} -> is_nil(seq) end)
          |> Enum.sort_by(fn {seq, _} -> seq end)
          |> Enum.map(fn {_seq, path} -> path end)

        if parts == [], do: {:error, :no_chunks}, else: {:ok, parts}

      {:error, _} ->
        {:error, :no_chunks}
    end
  end

  defp part_seq(filename) do
    case Integer.parse(Path.rootname(filename)) do
      {seq, ""} -> seq
      _ -> nil
    end
  end

  defp concat_parts(dir, parts) do
    target = Path.join(dir, "assembled.webm")

    try do
      File.open!(target, [:write, :binary], fn out ->
        Enum.each(parts, fn part -> IO.binwrite(out, File.read!(part)) end)
      end)

      {:ok, target}
    rescue
      error -> {:error, error}
    end
  end

  defp check_size(dir, incoming) do
    if current_size(dir) + incoming > max_bytes() do
      {:error, :recording_too_large}
    else
      :ok
    end
  end

  defp current_size(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.map(fn entry ->
          case File.stat(Path.join(dir, entry)) do
            {:ok, %File.Stat{size: size}} -> size
            _ -> 0
          end
        end)
        |> Enum.sum()

      _ ->
        0
    end
  end

  defp recording_dir(workspace_id, recording_id) do
    Path.join([root(), workspace_id, recording_id])
  end

  defp root do
    Application.get_env(:dev_ide, :preview_recordings_root) ||
      Path.join([System.tmp_dir!(), "devide_recordings"])
  end

  defp max_bytes do
    Application.get_env(:dev_ide, :preview_recording_max_bytes, @default_max_bytes)
  end

  defp validate_id(id) when is_binary(id) do
    if Regex.match?(@id_pattern, id), do: :ok, else: {:error, :invalid_id}
  end

  defp validate_id(_), do: {:error, :invalid_id}
end
