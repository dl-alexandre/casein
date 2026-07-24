defmodule Casein.Terminals.ScrollbackArchive do
  @moduledoc """
  Out-of-band scrollback spill for Casein-managed tmux sessions.

  tmux is still the live source of truth while the server is up. This module
  persists a bounded tail of each session's output so a **tmux server death**
  (segfault, kill-server, host reboot) does not wipe every transcript.

  On a fresh session create (when `has-session` is false), `Session` reseeds
  its in-memory buffer from the archive when present so reconnect replay can
  show recent history even though the new pane is empty.

  Default on-disk location is durable under `~/.devide/tmux-scrollback` (not
  `/tmp`). Override with `:tmux_scrollback_archive_dir` or
  `DEV_IDE_TMUX_SCROLLBACK_DIR`. Call `delete/1` on intentional session kill
  so reopening a sid does not false-positive as a crash recovery.
  """

  @default_max_bytes 256 * 1024
  @table :dev_ide_scrollback_archive

  @doc "Ensure the ETS spill table exists (idempotent)."
  def ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        access = Application.get_env(:dev_ide, :ets_table_access, :protected)
        :ets.new(@table, [:named_table, access, :set])
        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Directory for durable on-disk spill.

  Precedence: app config → `DEV_IDE_TMUX_SCROLLBACK_DIR` →
  `$HOME/.devide/tmux-scrollback` → tmp fallback.
  """
  def archive_dir do
    Application.get_env(:dev_ide, :tmux_scrollback_archive_dir) ||
      System.get_env("DEV_IDE_TMUX_SCROLLBACK_DIR") ||
      default_archive_dir()
  end

  defp default_archive_dir do
    home = System.get_env("HOME") || System.tmp_dir!()
    Path.join([home, ".devide", "tmux-scrollback"])
  end

  @doc "Max bytes retained per session (default 256 KiB)."
  def max_bytes do
    Application.get_env(:dev_ide, :tmux_scrollback_archive_bytes, @default_max_bytes)
  end

  @doc """
  Persist `data` as the latest known scrollback tail for `session`.

  Soft-fails on I/O errors so the terminal path never crashes on archive issues.
  """
  @spec put(String.t(), binary()) :: :ok
  def put(session, data) when is_binary(session) and is_binary(data) do
    ensure_table!()
    trimmed = trim_to(data, max_bytes())
    true = :ets.insert(@table, {session, trimmed})
    _ = maybe_write_disk(session, trimmed)
    :ok
  rescue
    _ -> :ok
  end

  def put(_session, _data), do: :ok

  @doc "Load the archived tail for `session`, or `<<>>` when missing."
  @spec get(String.t()) :: binary()
  def get(session) when is_binary(session) do
    ensure_table!()

    case :ets.lookup(@table, session) do
      [{^session, data}] when is_binary(data) ->
        data

      _ ->
        case read_disk(session) do
          {:ok, data} ->
            true = :ets.insert(@table, {session, data})
            data

          _ ->
            <<>>
        end
    end
  rescue
    _ -> <<>>
  end

  def get(_), do: <<>>

  @doc "True when an archive entry exists for `session` (ETS or disk)."
  @spec present?(String.t()) :: boolean()
  def present?(session) when is_binary(session), do: get(session) != <<>>
  def present?(_), do: false

  @doc "Delete archive for `session` (idle GC / explicit kill)."
  @spec delete(String.t()) :: :ok
  # path is Path.join(archive_dir(), safe_session_name) — session is regex-sanitized.
  # sobelow_skip ["Traversal.FileModule"]
  def delete(session) when is_binary(session) do
    ensure_table!()
    :ets.delete(@table, session)
    path = disk_path(session)
    _ = File.rm(path)
    :ok
  rescue
    _ -> :ok
  end

  def delete(_), do: :ok

  # path is Path.join(archive_dir(), safe_session_name) — session is regex-sanitized.
  # sobelow_skip ["Traversal.FileModule"]
  defp maybe_write_disk(session, data) do
    dir = archive_dir()
    File.mkdir_p!(dir)
    File.write!(disk_path(session), data)
  end

  # path is Path.join(archive_dir(), safe_session_name) — session is regex-sanitized.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_disk(session) do
    path = disk_path(session)

    case File.read(path) do
      {:ok, data} -> {:ok, trim_to(data, max_bytes())}
      error -> error
    end
  end

  defp disk_path(session) do
    # Session names are already constrained to [a-zA-Z0-9_-] style by Casein.
    safe =
      session
      |> String.replace(~r/[^A-Za-z0-9._-]+/, "_")
      |> String.slice(0, 200)

    Path.join(archive_dir(), safe <> ".scrollback")
  end

  defp trim_to(bin, max) when byte_size(bin) <= max, do: bin

  defp trim_to(bin, max) do
    # Keep the tail as raw bytes (may split a multi-byte UTF-8 sequence).
    start = byte_size(bin) - max
    binary_part(bin, start, max)
  end
end
