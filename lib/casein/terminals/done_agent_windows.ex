defmodule Casein.Terminals.DoneAgentWindows do
  @moduledoc """
  Soft-closes agent windows whose agent has reported it finished.

  `Casein.Terminals.TmuxWindowJanitor` reaps *blank* windows — one pane, sitting
  at a shell, never renamed. An agent window is never blank: it holds an agent
  runtime, and when that runtime finishes it usually leaves a completed TUI or a
  returned prompt behind. So the janitor never touches it, and across a fleet of
  5-8 agent windows the finished ones accumulate until someone closes each by
  hand.

  This sweep covers exactly that case, and it closes **softly** — through
  `Casein.Terminals.WindowTrash`, so the window disappears from every viewer
  immediately but tmux is untouched for the grace period and any viewer can take
  the close back. Nothing here ever calls `kill-window` directly.

  ## Why `:done` only, and not `:idle`

  `:done` is **report-only** (see `Casein.Terminals.AgentState`): the title
  heuristic can never produce it, so it is always an explicit claim by the agent
  that its work finished.

  `:idle` is not. `semantic_from_heuristic(:ready)` is `:idle`, and `resolve/4`
  also downgrades a long-stale `:working` report to `:idle` when the title reads
  ready. An agent sitting at a permission prompt, or one whose hook missed a
  `Stop` event, therefore presents as `:idle` without ever having finished
  anything. Closing on `:idle` would take windows away from agents that are
  merely waiting — including waiting *on the operator*.

  So the sweep acts on `:done` alone. `:idle` is available to a human as a hint
  in the UI, but it is not a completion signal and this module does not treat it
  as one.

  ## Close policy — a window is soft-closed only when ALL hold

    * its session name starts with `casein_` (never touch foreign sessions);
    * it has an agent-role pane whose resolved state is `:done`;
    * that `:done` report is at least `:done_agent_window_grace_seconds` old, so
      an agent that reports done and immediately starts another turn is not
      closed out from under itself;
    * no other pane in the window is `:working`;
    * no pane is running something other than a shell or a known agent runtime —
      a build, an editor or an `ssh` in a sibling pane means the window is still
      in use;
    * it is not the session's active window (never yank the window the operator
      is looking at);
    * it is not already pending in `WindowTrash`.

  ## Configuration

    * `:done_agent_window_sweep_ms` — sweep interval in ms; `nil`/`0` disables
      the sweep entirely. **Default `nil` (off)** — closing someone's window is
      not a behaviour to enable silently.
    * `:done_agent_window_grace_seconds` — how long a `:done` report must have
      been standing. Default `120`.
  """
  use GenServer

  require Logger

  alias Casein.Terminals.AgentState
  alias Casein.Terminals.PaneState
  alias Casein.Terminals.TmuxTopology
  alias Casein.Terminals.WindowTrash

  @default_grace_seconds 120

  # Foreground commands that do not, on their own, mean "this window is busy".
  # Shells are idle prompts; the agent runtimes are the thing that just finished.
  @quiescent ~w(bash zsh sh fish claude grok codex opencode agent node)

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Run one sweep now and return the windows it soft-closed."
  @spec sweep_now() :: [map()]
  def sweep_now, do: GenServer.call(__MODULE__, :sweep_now)

  @doc "Report what a sweep would close, without closing anything."
  @spec dry_run_now() :: [map()]
  def dry_run_now, do: GenServer.call(__MODULE__, :dry_run_now)

  @doc "Grace period a `:done` report must outlive before its window is closed."
  @spec grace_seconds() :: non_neg_integer()
  def grace_seconds do
    case Application.get_env(:casein, :done_agent_window_grace_seconds, @default_grace_seconds) do
      n when is_integer(n) and n >= 0 -> n
      _ -> @default_grace_seconds
    end
  end

  ## Server

  @impl GenServer
  def init(_opts) do
    case sweep_ms() do
      ms when is_integer(ms) and ms > 0 ->
        Process.send_after(self(), :sweep, ms)
        {:ok, %{interval: ms}}

      _ ->
        # Disabled: hold the process (so the supervisor tree is stable) but
        # never arm a timer.
        {:ok, %{interval: nil}}
    end
  end

  @impl GenServer
  def handle_info(:sweep, %{interval: ms} = state) when is_integer(ms) and ms > 0 do
    _ = sweep(close?: true)
    Process.send_after(self(), :sweep, ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def handle_call(:sweep_now, _from, state), do: {:reply, sweep(close?: true), state}
  def handle_call(:dry_run_now, _from, state), do: {:reply, sweep(close?: false), state}

  ## Sweep

  defp sweep(opts) do
    close? = Keyword.get(opts, :close?, false)
    now = DateTime.utc_now()

    grace = grace_seconds()

    for {session, topology} <- sessions_with_topology(),
        reports = AgentState.for_session(session),
        window <- Map.get(topology, :windows, []),
        closable?(session, window, now, grace, reports),
        candidate = candidate(session, window, now),
        close?(close?, session, window) do
      candidate
    end
  end

  defp close?(false, _session, _window), do: true

  defp close?(true, session, window) do
    window_id = PaneState.map_get(window, :id)
    name = PaneState.map_get(window, :name)

    case WindowTrash.trash(session, window_id, name) do
      {:ok, _} ->
        Logger.info("done-agent window soft-closed session=#{session} window=#{window_id}")
        true

      other ->
        Logger.warning(
          "done-agent window soft-close failed session=#{session} window=#{window_id} " <>
            "reason=#{inspect(other)}"
        )

        false
    end
  end

  @doc """
  Whether a window is eligible for a soft close.

  Pure over an enriched topology window (see `AgentState.enrich_topology/2`) plus
  the session's raw reports (`AgentState.for_session/1`), so the policy is
  testable without tmux.

  Both inputs are required and neither is redundant. The enriched window carries
  the *reconciled* verdict, so a `:done` report that a live working spinner has
  already overridden does not qualify. The raw report carries `reported_at`,
  which is what the grace period is measured against — and which deliberately
  does not ride on the pane payload, because a per-pane timestamp would change on
  every report and churn the payload hashes that LiveView change tracking and
  the topology differ depend on.
  """
  @spec closable?(String.t(), map(), DateTime.t(), non_neg_integer(), map()) :: boolean()
  def closable?(session, window, now, grace_seconds, reports) do
    panes = PaneState.window_panes(window)

    String.starts_with?(session, "casein_") and
      panes != [] and
      not truthy?(PaneState.map_get(window, :active)) and
      not WindowTrash.pending?(session, PaneState.map_get(window, :id)) and
      has_done_agent?(panes, now, grace_seconds, reports) and
      no_pane_working?(panes) and
      all_panes_quiescent?(panes)
  end

  # At least one agent-role pane whose reconciled state is :done AND whose own
  # report says :done and has stood past the grace period.
  defp has_done_agent?(panes, now, grace_seconds, reports) do
    Enum.any?(panes, fn pane ->
      PaneState.agent_role?(pane) and
        PaneState.map_get(pane, :agent_state) == :done and
        done_settled?(Map.get(reports, PaneState.map_get(pane, :id)), now, grace_seconds)
    end)
  end

  # A `:done` that arrived seconds ago may be one turn in a longer session. Only
  # a report that has stood unchanged past the grace period counts — and it must
  # be a genuine `:done` report, never a state inferred from a title.
  defp done_settled?(%{state: :done, reported_at: %DateTime{} = at}, now, grace_seconds),
    do: DateTime.diff(now, at, :second) >= grace_seconds

  defp done_settled?(_entry, _now, _grace_seconds), do: false

  defp no_pane_working?(panes) do
    not Enum.any?(panes, &(PaneState.map_get(&1, :agent_state) == :working))
  end

  # A sibling pane running a build, an editor or an ssh means the window is
  # still someone's workspace even though the agent in it finished.
  defp all_panes_quiescent?(panes) do
    Enum.all?(panes, fn pane ->
      case PaneState.map_get(pane, :current_command) do
        cmd when is_binary(cmd) -> cmd in @quiescent
        _ -> false
      end
    end)
  end

  defp candidate(session, window, now) do
    %{
      session: session,
      window_id: PaneState.map_get(window, :id),
      name: PaneState.map_get(window, :name),
      reason: :done_agent_window,
      observed_at: now
    }
  end

  defp sweep_ms do
    Application.get_env(:casein, :done_agent_window_sweep_ms)
  end

  # Enriched topology per live Casein session. Injectable so the sweep can be
  # exercised without a tmux server.
  defp sessions_with_topology do
    case Application.get_env(:casein, :done_agent_window_source) do
      fun when is_function(fun, 0) -> fun.()
      _ -> live_sessions_with_topology()
    end
  end

  defp live_sessions_with_topology do
    backend = Casein.Terminals.Backend.module()

    Enum.flat_map(backend.list_sessions(), fn entry ->
      case session_name(entry) do
        name when is_binary(name) and name != "" ->
          [{name, AgentState.enrich_topology(TmuxTopology.snapshot(name, tmux: backend), name)}]

        _ ->
          []
      end
    end)
  rescue
    # A tmux server that vanished mid-sweep is not an error worth crashing the
    # sweep over; the next tick will find it gone.
    _ -> []
  end

  defp session_name(%{session: name}) when is_binary(name), do: name
  defp session_name(%{"session" => name}) when is_binary(name), do: name
  defp session_name(name) when is_binary(name), do: name
  defp session_name(_), do: nil

  defp truthy?(true), do: true
  defp truthy?("1"), do: true
  defp truthy?(_), do: false
end
