defmodule DevIDE.Terminals.Activity do
  @moduledoc """
  tmux `monitor-silence` analog for agent windows.

  A window is "quiet" when its active pane runs an interactive coding agent
  (per `Boundary.interactive_command_ids/0`) and its last output is older
  than the silence threshold but still inside the attention window — the
  signal that an agent finished or is blocked waiting for input.

  Quantizing the volatile activity timestamp into this boolean is what lets
  `SessionDirectory` store it in the stable window metadata: the flip (and
  only the flip) re-broadcasts the tab list, so quiet-agent notifications
  reach LiveViews without per-poll churn from raw timestamps.
  """

  alias DevIDE.Terminals.Boundary

  @silence_after_seconds 60
  @attention_window_seconds 1_800

  @doc """
  True when the window's active pane runs an agent command that has been
  silent long enough to need attention, but not so long it is stale.

  Accepts the window maps produced by `Tmux.list_session_windows/1` and by
  topology snapshots (atom or string keys; integer or string timestamps).
  """
  @spec agent_window_quiet?(map(), integer()) :: boolean()
  def agent_window_quiet?(window, now \\ now_unix()) when is_map(window) do
    command = Map.get(window, :current_command) || Map.get(window, "current_command")
    activity = Map.get(window, :activity) || Map.get(window, "activity")

    with true <- agent_command?(command),
         {:ok, timestamp} when timestamp > 0 <- parse_timestamp(activity) do
      age = now - timestamp
      age >= @silence_after_seconds and age <= @attention_window_seconds
    else
      _ -> false
    end
  end

  @doc "True for commands that launch an interactive coding agent."
  @spec agent_command?(term()) :: boolean()
  def agent_command?(command) when is_binary(command),
    do: command in Boundary.interactive_command_ids()

  def agent_command?(_command), do: false

  defp parse_timestamp(value) when is_integer(value), do: {:ok, value}

  defp parse_timestamp(value) when is_binary(value) do
    case Integer.parse(value) do
      {timestamp, ""} -> {:ok, timestamp}
      _ -> :error
    end
  end

  defp parse_timestamp(_value), do: :error

  defp now_unix, do: DateTime.utc_now() |> DateTime.to_unix()
end
