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
  """

  use GenServer

  require Logger

  alias Casein.Labels
  alias Casein.Runs.AgentLifecycle
  alias Casein.Terminals.AgentState
  alias Casein.Terminals.IssueBinding
  alias Casein.Terminals.NextPrompt
  alias Casein.Terminals.WorkHandles

  @default_interval_ms 30_000
  @managed_prefix "casein_"

  @type result :: %{
          observed_at: String.t(),
          sessions: non_neg_integer(),
          reconciled: non_neg_integer(),
          panes_observed: non_neg_integer(),
          sessions_lost: non_neg_integer(),
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

        result = %{
          observed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          sessions: length(sessions),
          reconciled: reconciled,
          panes_observed: panes_observed,
          sessions_lost: MapSet.size(lost),
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
