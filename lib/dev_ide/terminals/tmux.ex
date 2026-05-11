defmodule DevIDE.Terminals.Tmux do
  @moduledoc """
  tmux adapter for workspace terminals.

  Sessions are named `devide:{workspace}:{sid}` and rooted at the workspace's
  host path. Sessions persist across browser disconnects; LiveViews attach via
  `pipe-pane` ports.

  TEMPORARY: shells out to the host `tmux` binary. Replace with a structured
  adapter once we have a clear story for SSH/remote hosts.
  """

  @session_prefix "devide"

  def session_name(workspace_name, sid) do
    "#{@session_prefix}:#{sanitize(workspace_name)}:#{sanitize(sid)}"
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

  defp sanitize(s) do
    s
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_\-]/, "_")
    |> String.slice(0, 64)
  end
end
