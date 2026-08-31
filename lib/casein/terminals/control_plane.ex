defmodule Casein.Terminals.ControlPlane do
  @moduledoc """
  Background reconciliation for the Casein terminal control plane.

  The UI and MCP callers are not the only observers of tmux. A coordinator can
  disappear while a session remains alive, and a pane can be replaced while
  in-memory state still points at its old id. This process periodically scans
  managed sessions and prunes pane-keyed state using the live topology.

  It also provides the single cleanup boundary used when a topology watcher
  observes a session termination. Cleanup is deliberately conservative: a
  failed probe never becomes an empty pane list, so a transient tmux error does
  not erase live work metadata.

  ## Announcing session loss

  `sessions_lost` used to be a one-tick snapshot: `lost` was computed, exposed
  on `status/0`, and then `seen_sessions` was overwritten, so the next pass
  seconds later reported `0` again — forever, and across a Casein restart it
  reported `0` from the start. On 2026-08-29 an unattended `libpam` upgrade
  stopped `casein-tmux.service` (`Type=forking` + `KillMode=control-group`,
  i.e. the tmux server *was* the unit's main process) and destroyed every
  session across four workspaces; the fleet API answered `sessions: []` for
  eight hours, indistinguishable from an idle fleet, and `sessions_lost` read
  `0` (OneBackend-v3#20076).

  A session vanishing without Casein having killed it is now a durable audit
  event and an alert. Teardowns Casein performs itself — `Terminals.Tmux.kill/1`
  records them in `Casein.Terminals.ExpectedRemovals` — are counted separately
  and never alert,
  so the signal stays trustworthy rather than habitually red.
  """

  use GenServer

  require Logger

  alias Casein.Audit
  alias Casein.Labels
  alias Casein.Terminals.ExpectedRemovals
  alias Casein.Runs.AgentLifecycle
  alias Casein.Terminals.AgentState
  alias Casein.Terminals.IssueBinding
  alias Casein.Terminals.NextPrompt
  alias Casein.Terminals.WorkHandles

  @default_interval_ms 30_000
  @managed_prefix "casein_"
  @loss_action "fleet.sessions_lost"
  @ops_workspace "_ops"
  @ops_topic "ops:health"

  @type result :: %{
          observed_at: String.t(),
          sessions: non_neg_integer(),
          reconciled: non_neg_integer(),
          panes_observed: non_neg_integer(),
          sessions_lost: non_neg_integer(),
          sessions_lost_unexplained: non_neg_integer(),
          sessions_lost_expected: non_neg_integer(),
          errors: [map()]
        }

  @doc "Start the background reconciler. The default child is named globally."
  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)

    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Force one reconciliation pass and return its result."
  @spec reconcile_now(keyword()) :: {:ok, result()} | {:error, term()}
  def reconcile_now(opts \\ []) when is_list(opts) do
    GenServer.call(__MODULE__, {:reconcile, opts}, 30_000)
  catch
    :exit, reason -> {:error, reason}
  end

  @doc "Return the last reconciliation result and process health."
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  catch
    :exit, _ -> %{state: "unavailable", note: "control-plane reconciler is not running"}
  end

  @doc "Prune all pane-keyed stores against a known live pane set."
  @spec reconcile_session(String.t(), [String.t()]) :: :ok
  def reconcile_session(session, pane_ids)
      when is_binary(session) and is_list(pane_ids) do
    AgentState.prune_session(session, pane_ids)
    IssueBinding.prune_session(session, pane_ids)
    Labels.prune_session(session, pane_ids)
    NextPrompt.prune_session(session, pane_ids)
    WorkHandles.prune_session(session, pane_ids)
    AgentLifecycle.prune_session(session, pane_ids)
    :ok
  end

  @impl true
  def init(opts) do
    state = %{
      adapter: Keyword.get(opts, :adapter, Casein.Terminals.tmux_adapter()),
      interval_ms: normalize_interval(Keyword.get(opts, :interval_ms, configured_interval())),
      last_result: nil,
      seen_sessions: MapSet.new(),
      run_count: 0
    }

    {:ok, state, {:continue, :reconcile}}
  end

  @impl true
  def handle_continue(:reconcile, state) do
    {:noreply, schedule_reconcile(run(state, []))}
  end

  @impl true
  def handle_call(:status, _from, state) do
    result =
      %{
        state: status_state(state.last_result),
        interval_ms: state.interval_ms,
        run_count: state.run_count,
        last_reconciliation: state.last_result
      }

    {:reply, result, state}
  end

  def handle_call({:reconcile, opts}, _from, state) do
    state = run(state, opts)
    {:reply, {:ok, state.last_result}, state}
  end

  @impl true
  def handle_info(:reconcile, state) do
    {:noreply, schedule_reconcile(run(state, []))}
  end

  ## Reconciliation

  defp run(state, opts) do
    adapter = Keyword.get(opts, :adapter, state.adapter)

    case list_sessions(adapter) do
      {:ok, sessions} ->
        {reconciled, panes_observed, errors} = reconcile_live_sessions(adapter, sessions)
        current = MapSet.new(sessions)
        lost = MapSet.difference(state.seen_sessions, current)

        Enum.each(lost, &reconcile_session(&1, []))

        {expected, unexplained} =
          lost |> MapSet.to_list() |> Enum.split_with(&ExpectedRemovals.claim/1)

        # A session Casein did not kill has disappeared. Say so once, durably.
        if unexplained != [], do: announce_loss(unexplained, length(sessions))

        result = %{
          observed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          sessions: length(sessions),
          reconciled: reconciled,
          panes_observed: panes_observed,
          sessions_lost: MapSet.size(lost),
          sessions_lost_unexplained: length(unexplained),
          sessions_lost_expected: length(expected),
          errors: errors
        }

        %{state | last_result: result, seen_sessions: current, run_count: state.run_count + 1}

      {:error, reason} ->
        result = %{
          observed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          sessions: 0,
          reconciled: 0,
          panes_observed: 0,
          sessions_lost: 0,
          sessions_lost_unexplained: 0,
          sessions_lost_expected: 0,
          errors: [%{session: nil, reason: inspect(reason)}]
        }

        Logger.warning("control-plane reconciliation probe failed: #{inspect(reason)}")
        %{state | last_result: result, run_count: state.run_count + 1}
    end
  end

  defp list_sessions(adapter) do
    result =
      if function_exported?(adapter, :list_sessions_result, 0) do
        adapter.list_sessions_result()
      else
        {:ok, adapter.list_sessions()}
      end

    case result do
      {:ok, sessions} when is_list(sessions) ->
        names =
          sessions
          |> Enum.map(&session_name/1)
          |> Enum.filter(&(is_binary(&1) and String.starts_with?(&1, @managed_prefix)))
          |> Enum.uniq()

        {:ok, names}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :invalid_session_inventory}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  # Durable first, then broadcast: the audit row is the record that survives
  # the restart which used to erase the evidence.
  defp announce_loss(sessions, remaining) do
    Logger.warning(
      "sessions disappeared without a Casein teardown: #{Enum.join(sessions, ", ")} " <>
        "(#{length(sessions)} lost, #{remaining} still live)"
    )

    :telemetry.execute(
      [:casein, :terminals, :sessions_lost],
      %{count: length(sessions)},
      %{sessions: sessions}
    )

    _ =
      Audit.emit!(%{
        workspace_id: @ops_workspace,
        actor_id: "control_plane",
        action: @loss_action,
        source: "ops",
        target_type: "tmux_server",
        target_ref: "sessions",
        metadata: %{
          "sessions" => sessions,
          "count" => length(sessions),
          "sessions_remaining" => remaining
        }
      })

    Phoenix.PubSub.broadcast(
      Casein.PubSub,
      @ops_topic,
      {:ops_health, :sessions_lost, :raised,
       %{
         id: :sessions_lost,
         severity: :alarm,
         subject: "tmux sessions",
         detected_at: DateTime.utc_now(),
         evidence: %{sessions: sessions, count: length(sessions), sessions_remaining: remaining},
         suggestion:
           "#{length(sessions)} session(s) vanished with no Casein teardown. Work in those " <>
             "panes is gone from tmux; worktrees on disk survive and can be recovered. " <>
             "Check whether a unit owning the tmux server was stopped " <>
             "(journalctl -u casein-tmux.service -u casein-tmux-anchor.service) — an " <>
             "unattended package upgrade did exactly that on 2026-08-29."
       }}
    )
  end

  defp reconcile_live_sessions(adapter, sessions) do
    Enum.reduce(sessions, {0, 0, []}, fn session, {reconciled, observed, errors} ->
      case live_pane_ids(adapter, session) do
        {:ok, pane_ids} ->
          reconcile_session(session, pane_ids)
          {reconciled + 1, observed + length(pane_ids), errors}

        {:error, reason} ->
          {reconciled, observed, [%{session: session, reason: inspect(reason)} | errors]}
      end
    end)
  end

  defp live_pane_ids(adapter, session) do
    result =
      if function_exported?(adapter, :list_session_panes_result, 1) do
        adapter.list_session_panes_result(session)
      else
        {:ok, adapter.list_session_panes(session)}
      end

    case result do
      {:ok, panes} when is_list(panes) ->
        {:ok,
         panes
         |> Enum.map(&pane_id/1)
         |> Enum.filter(&(is_binary(&1) and &1 != ""))
         |> Enum.uniq()}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :invalid_pane_inventory}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  defp schedule_reconcile(%{interval_ms: interval} = state)
       when is_integer(interval) and interval > 0 do
    Process.send_after(self(), :reconcile, interval)
    state
  end

  defp schedule_reconcile(state), do: state

  defp configured_interval do
    Application.get_env(:casein, :control_plane_reconcile_ms, @default_interval_ms)
  end

  defp normalize_interval(value) when is_integer(value) and value > 0, do: value
  defp normalize_interval(_), do: nil

  defp status_state(nil), do: "starting"
  defp status_state(%{errors: []}), do: "healthy"
  defp status_state(%{errors: _errors}), do: "degraded"

  defp session_name(%{session: session}), do: session
  defp session_name(%{"session" => session}), do: session
  defp session_name(session) when is_binary(session), do: session
  defp session_name(_), do: nil

  defp pane_id(%{id: pane_id}), do: pane_id
  defp pane_id(%{"id" => pane_id}), do: pane_id
  defp pane_id(_), do: nil
end
