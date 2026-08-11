defmodule CaseinWeb.WorkspaceLive.Show.AgentStateChrome do
  @moduledoc """
  Single presentation source for `Casein.Terminals.AgentState` in the cockpit.

  Detection stays in `AgentState` / `PaneState` / `AgentLiveness`. This module
  only answers "what does that resolved state look like?" for window dots,
  session chips, pane chrome, and task-summary tooltips.

  See `docs/design/agent-state-cockpit-legibility.md`.
  """

  @type state ::
          :working
          | :blocked
          | :done
          | :idle
          | :errored
          | :stalled
          | :awaiting_input
          | :unknown
          | nil
          | String.t()

  @type presentation :: %{
          state: atom(),
          known?: boolean(),
          overrides_activity?: boolean(),
          dot_class: String.t() | nil,
          chip_text: String.t() | nil,
          chip_class: String.t() | nil,
          label: String.t() | nil
        }

  # Cockpit status tokens (#729). Meaning-named; theme-aware via app.css.
  @dot_working "bg-status-ok shadow-[0_0_0_3px] shadow-status-ok/25 animate-pulse"
  @dot_blocked "bg-status-danger shadow-[0_0_0_3px] shadow-status-danger/30"
  @dot_done "bg-status-live"
  @dot_idle "bg-base-content/20"
  @dot_errored "bg-status-danger shadow-[0_0_0_3px] shadow-status-danger/30"
  @dot_stalled "bg-status-warning shadow-[0_0_0_3px] shadow-status-warning/30 animate-pulse"
  # Steady rather than pulsing: nothing is happening, and nothing will until you
  # act. The pulse is reserved for states that claim ongoing activity.
  @dot_awaiting "bg-status-warning shadow-[0_0_0_3px] shadow-status-warning/30"

  @chip_blocked "bg-status-danger/15 text-status-danger-fg"
  @chip_done "bg-status-live/15 text-status-live-fg"
  @chip_errored "bg-status-danger/15 text-status-danger-fg"
  @chip_stalled "bg-status-warning/15 text-status-warning-fg"
  @chip_awaiting "bg-status-warning/15 text-status-warning-fg"

  @doc "Normalize a topology/report state token to an atom, or `:unknown`."
  @spec normalize(state()) :: atom()
  def normalize(state)
      when state in [
             :working,
             :blocked,
             :done,
             :idle,
             :errored,
             :stalled,
             :awaiting_input,
             :unknown
           ],
      do: state

  def normalize("working"), do: :working
  def normalize("blocked"), do: :blocked
  def normalize("done"), do: :done
  def normalize("idle"), do: :idle
  def normalize("errored"), do: :errored
  def normalize("stalled"), do: :stalled
  def normalize("awaiting_input"), do: :awaiting_input
  def normalize("unknown"), do: :unknown
  def normalize(_), do: :unknown

  @doc """
  Build the chrome presentation for a resolved agent state.

  `:unknown` / nil return `known?: false` so callers keep ordinary tmux activity
  chrome — including title-heuristic `:ready` with no live report.
  """
  @spec present(state(), String.t() | nil) :: presentation()
  def present(state, message \\ nil) do
    state = normalize(state)
    message = blank_to_nil(message)

    case state do
      :working ->
        known(state, @dot_working, nil, nil, working_label(message))

      :blocked ->
        known(
          state,
          @dot_blocked,
          "needs input",
          @chip_blocked,
          "Agent blocked: " <> (message || "needs input")
        )

      :done ->
        known(state, @dot_done, "done", @chip_done, "Agent done")

      :idle ->
        known(state, @dot_idle, nil, nil, "Agent idle")

      :errored ->
        known(
          state,
          @dot_errored,
          "error",
          @chip_errored,
          "Agent errored: " <> (message || "check the pane")
        )

      :stalled ->
        known(state, @dot_stalled, "stalled", @chip_stalled, stalled_label(message))

      # Deliberately not the blocked chrome: this is derived from transcript
      # shape, and it cannot tell a question from a finished turn. It asks for a
      # look, it does not claim the agent said it is blocked.
      :awaiting_input ->
        known(
          state,
          @dot_awaiting,
          "waiting",
          @chip_awaiting,
          "Agent stopped and is waiting on you"
        )

      _unknown ->
        %{
          state: :unknown,
          known?: false,
          overrides_activity?: false,
          dot_class: nil,
          chip_text: nil,
          chip_class: nil,
          label: nil
        }
    end
  end

  @doc "Whether chrome should replace tmux activity colour for this state."
  @spec overrides_activity?(state()) :: boolean()
  def overrides_activity?(state), do: present(state).overrides_activity?

  @doc "Activity-dot classes, or nil when the caller should keep tmux activity."
  @spec dot_class(state()) :: String.t() | nil
  def dot_class(state), do: present(state).dot_class

  @doc "Operator-facing tooltip / aria label, or nil when unknown."
  @spec label(state(), String.t() | nil) :: String.t() | nil
  def label(state, message \\ nil), do: present(state, message).label

  @doc "Optional short chip text for rails (`needs input`, `stalled`, …)."
  @spec chip_text(state()) :: String.t() | nil
  def chip_text(state), do: present(state).chip_text

  @doc "Chip surface classes paired with `chip_text/1`."
  @spec chip_class(state()) :: String.t() | nil
  def chip_class(state), do: present(state).chip_class

  @doc """
  Merge agent chrome onto an existing activity `{class, label}` pair.

  Unknown keeps the activity pair untouched (honest degradation / ready ambiguity).
  """
  @spec apply_to_activity(String.t(), String.t(), state(), String.t() | nil) ::
          {String.t(), String.t()}
  def apply_to_activity(activity_class, activity_label, state, message \\ nil) do
    chrome = present(state, message)

    if chrome.overrides_activity? do
      {chrome.dot_class, chrome.label || activity_label}
    else
      {activity_class, activity_label}
    end
  end

  @doc """
  Title/tooltip line for a task summary under a known agent state.

  Unknown leaves the summary alone. Known states append the chrome label so the
  summary text itself stays the human task string.
  """
  @spec task_title(String.t() | nil, state(), String.t() | nil) :: String.t() | nil
  def task_title(task_summary, state, message \\ nil) do
    summary = blank_to_nil(task_summary)
    chrome = present(state, message)

    cond do
      is_nil(summary) and is_nil(chrome.label) -> nil
      is_nil(summary) -> chrome.label
      is_nil(chrome.label) -> summary
      true -> summary <> " · " <> chrome.label
    end
  end

  defp known(state, dot, chip_text, chip_class, label) do
    %{
      state: state,
      known?: true,
      overrides_activity?: true,
      dot_class: dot,
      chip_text: chip_text,
      chip_class: chip_class,
      label: label
    }
  end

  defp working_label(nil), do: "Agent pane working"
  defp working_label(detail), do: "Agent working — " <> detail

  defp stalled_label(nil),
    do: "Agent looks busy but its worktree has been idle — may be wedged"

  defp stalled_label(detail), do: "Agent may be wedged — " <> detail

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil
end
