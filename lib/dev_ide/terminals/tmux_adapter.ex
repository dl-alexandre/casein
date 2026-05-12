defmodule DevIDE.Terminals.TmuxAdapter do
  @moduledoc """
  Narrow infrastructure adapter for tmux session lifecycle.

  ## Scope

    * Create tmux sessions for executions
    * Check session liveness
    * Attach/reconnect operators to sessions
    * Kill sessions on cleanup

  ## Non-scope

    * Not orchestration truth — tmux is infrastructure
    * Not a source of execution state — that remains in assignments
    * Not responsible for workspace/worktree — that's WorkspaceContext

  ## Naming convention

  Session name: `devide_{execution_id}` for easy identification and
  bulk cleanup.
  """

  require Logger

  @session_prefix "devide_"

  @doc "Create a tmux session for an execution."
  @spec create_session(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :tmux_not_found | term()}
  def create_session(execution_id, opts \\ []) do
    unless tmux_available?(), do: {:error, :tmux_not_found}

    session_name = "#{@session_prefix}#{execution_id}"
    worktree = Keyword.get(opts, :worktree_path, ".")
    cmd = Keyword.get(opts, :command, "bash")

    # Create detached session with working directory
    result =
      System.cmd("tmux", [
        "new-session",
        "-d",
        "-s",
        session_name,
        "-c",
        worktree,
        cmd
      ])

    case result do
      {_, 0} ->
        Logger.info("tmux session created: #{session_name}")
        {:ok, session_name}

      {err, _} ->
        Logger.error("tmux create failed: #{err}")
        {:error, :tmux_create_failed}
    end
  end

  @doc "Check if a tmux session is alive."
  @spec session_alive?(String.t()) :: boolean()
  def session_alive?(session_name) do
    if tmux_available?() do
      case System.cmd("tmux", ["has-session", "-t", session_name]) do
        {_, 0} -> true
        _ -> false
      end
    else
      false
    end
  end

  @doc "Send a command to a tmux session."
  @spec send_keys(String.t(), String.t()) :: :ok | {:error, term()}
  def send_keys(session_name, keys) do
    if session_alive?(session_name) do
      case System.cmd("tmux", ["send-keys", "-t", session_name, keys, "C-m"]) do
        {_, 0} -> :ok
        {err, _} -> {:error, {:tmux_send_failed, err}}
      end
    else
      {:error, :session_not_alive}
    end
  end

  @doc "Capture output from a tmux session."
  @spec capture(String.t()) :: {:ok, String.t()} | {:error, term()}
  def capture(session_name) do
    if session_alive?(session_name) do
      case System.cmd("tmux", ["capture-pane", "-p", "-t", session_name]) do
        {output, 0} -> {:ok, output}
        {err, _} -> {:error, {:tmux_capture_failed, err}}
      end
    else
      {:error, :session_not_alive}
    end
  end

  @doc "Kill a tmux session."
  @spec kill_session(String.t()) :: :ok | {:error, term()}
  def kill_session(session_name) do
    if session_alive?(session_name) do
      case System.cmd("tmux", ["kill-session", "-t", session_name]) do
        {_, 0} -> :ok
        {err, _} -> {:error, {:tmux_kill_failed, err}}
      end
    else
      :ok
    end
  end

  @doc "List all devide tmux sessions."
  @spec list_sessions() :: [String.t()]
  def list_sessions do
    if tmux_available?() do
      case System.cmd("tmux", ["list-sessions", "-F", "\#{#S}"]) do
        {output, 0} ->
          output
          |> String.split("\n")
          |> Enum.filter(&String.starts_with?(&1, @session_prefix))

        _ ->
          []
      end
    else
      []
    end
  end

  @doc "Attach command for operator reconnect."
  @spec attach_command(String.t()) :: String.t()
  def attach_command(session_name) do
    "tmux attach -t #{session_name}"
  end

  ## Internal

  defp tmux_available? do
    System.find_executable("tmux") != nil
  end
end
