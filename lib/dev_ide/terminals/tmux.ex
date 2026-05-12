defmodule DevIDE.Terminals.Tmux do
  @moduledoc """
  tmux adapter for workspace terminals.

  Sessions are named `devide_<workspace>_<sid>` and rooted at the workspace's
  host path. Sessions persist across browser disconnects; LiveViews attach via
  `pipe-pane` ports.

  TEMPORARY: shells out to the host `tmux` binary. Replace with a structured
  adapter once we have a clear story for SSH/remote hosts.
  """

  @session_prefix "devide"

  def session_name(workspace_name, sid) do
    "#{@session_prefix}_#{sanitize(workspace_name)}_#{sanitize(sid)}"
  end

  def ensure_session(session, cwd) do
    case System.cmd("tmux", ["has-session", "-t", session], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      _ ->
        case System.cmd("tmux", ["new-session", "-d", "-s", session, "-c", cwd],
               stderr_to_stdout: true
             ) do
          {_, 0} -> :ok
          {out, code} -> {:error, {code, out}}
        end
    end
  end

  @doc """
  Opens a Port that streams session output to the calling process and accepts
  keystrokes via `Port.command/2`. Returns `{:ok, port}`.
  """
  def attach(session) do
    args = ["attach-session", "-t", session]

    port =
      Port.open({:spawn_executable, System.find_executable("tmux")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args
      ])

    {:ok, port}
  end

  def send_keys(session, keys) do
    System.cmd("tmux", ["send-keys", "-t", session, keys])
  end

  def kill(session) do
    System.cmd("tmux", ["kill-session", "-t", session], stderr_to_stdout: true)
  end

  @doc """
  Returns true if a tmux session by this name is currently registered with
  the tmux server. Used by Session.init to decide whether to capture
  scrollback before attaching.
  """
  def session_exists?(session) do
    case System.cmd("tmux", ["has-session", "-t", session], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  @doc """
  Capture the full scrollback of a tmux session's first window/pane, with
  escape sequences preserved (`-e`) and wrapped lines joined (`-J`).
  Returns an empty binary on failure or when the session does not exist —
  the caller seeds an output buffer with the result, so soft-fail is the
  right shape.

  Used to recover pane history when a Session GenServer is re-created
  against an existing tmux session (server restart, replay path).
  """
  def capture_scrollback(session) do
    case System.cmd(
           "tmux",
           ["capture-pane", "-p", "-e", "-J", "-S", "-", "-t", session],
           stderr_to_stdout: true
         ) do
      {output, 0} -> output
      _ -> <<>>
    end
  end

  defp sanitize(s) do
    s
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_\-]/, "_")
    |> String.slice(0, 64)
  end
end
