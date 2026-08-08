defmodule Casein.Runs.AgentLifecycle do
  @moduledoc """
  Boundary emitter that lifts agent lifecycle into `Casein.Runs.Ledger`.

  Design ground truth (`docs/design/agent-work-as-a-run.md`):

    * Open primarily on `:working`; claim/issue is an attribute, not the trigger.
    * Fall back to first `send_command` for silent runtimes (Grok/OpenCode).
    * Close on `:done` / `:errored` / pane death; prefer close over hang (`:idle`).
    * `:blocked` does **not** close — emit `approval_requested` and keep the Run open.
    * Identity is per pane session; issue binding is optional metadata.
    * A Run adds no policy authority.

  This module owns Ledger writes. `Casein.Terminals.AgentState` stays free of
  Ledger references — callers (AgentState.Server transitions, send_command
  fallback, topology prune) invoke this boundary instead.
  """

  use GenServer

  alias Casein.Runs.Ledger
  alias Casein.Terminals.IssueBinding

  @registered_name __MODULE__

  @type key :: {String.t(), String.t()}

  @type open_run :: %{
          run_id: String.t(),
          workspace_id: String.t(),
          actor_id: String.t() | nil,
          tmux_session: String.t(),
          pane_id: String.t(),
          issue: pos_integer() | nil,
          opened_by: String.t(),
          blocked?: boolean()
        }

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, @registered_name))
  end

  @doc """
  Observe a semantic agent-state transition.

  Opens on first `:working` when no Run is open. Closes on `:done`, `:errored`,
  and `:idle`. `:blocked` emits `approval_requested` and leaves the Run open.
  """
  @spec observe_state(map()) :: :ok
  def observe_state(attrs) when is_map(attrs) do
    GenServer.cast(@registered_name, {:observe_state, normalize_attrs(attrs)})
  end

  @doc """
  Fallback open path: first successful `send_command` after idle.

  Load-bearing for Grok and OpenCode, which otherwise report nothing. No-ops
  when a Run is already open for the pane.
  """
  @spec note_send_command(map()) :: :ok
  def note_send_command(attrs) when is_map(attrs) do
    GenServer.cast(@registered_name, {:note_send_command, normalize_attrs(attrs)})
  end

  @doc """
  Close open Runs for panes that no longer exist (pane death / prune).

  Same lifecycle hook as issue-binding prune: a binding cannot outlive its pane,
  and neither can an open Run.
  """
  @spec prune_session(String.t(), [String.t()]) :: :ok
  def prune_session(tmux_session, pane_ids)
      when is_binary(tmux_session) and is_list(pane_ids) do
    GenServer.cast(@registered_name, {:prune_session, tmux_session, MapSet.new(pane_ids)})
  end

  @doc "Open Run for a pane, if any (tests / supervisor reads)."
  @spec get(String.t(), String.t()) :: open_run() | nil
  def get(tmux_session, pane_id) when is_binary(tmux_session) and is_binary(pane_id) do
    GenServer.call(@registered_name, {:get, {tmux_session, pane_id}})
  end

  @doc false
  @spec clear() :: :ok
  def clear, do: GenServer.call(@registered_name, :clear)

  ## Server

  @impl true
  def init(_), do: {:ok, %{opens: %{}}}

  @impl true
  def handle_call({:get, key}, _from, state) do
    {:reply, Map.get(state.opens, key), state}
  end

  def handle_call(:clear, _from, _state), do: {:reply, :ok, %{opens: %{}}}

  @impl true
  def handle_cast({:observe_state, attrs}, state) do
    {:noreply, do_observe_state(state, attrs)}
  end

  def handle_cast({:note_send_command, attrs}, state) do
    {:noreply, do_note_send_command(state, attrs)}
  end

  def handle_cast({:prune_session, tmux_session, live_panes}, state) do
    {:noreply, do_prune_session(state, tmux_session, live_panes)}
  end

  ## Transitions

  defp do_observe_state(state, attrs) do
    with workspace_id when is_binary(workspace_id) <- attrs.workspace_id,
         session when is_binary(session) <- attrs.tmux_session,
         pane when is_binary(pane) <- attrs.pane_id,
         semantic when semantic in [:working, :blocked, :done, :idle, :errored, :stalled] <-
           attrs.state do
      key = {session, pane}
      open = Map.get(state.opens, key)
      apply_state(state, key, open, semantic, attrs)
    else
      _ -> state
    end
  end

  defp apply_state(state, key, nil, :working, attrs) do
    open_run(state, key, attrs, "working")
  end

  defp apply_state(state, _key, nil, _state, _attrs), do: state

  defp apply_state(state, key, open, :working, attrs) do
    open =
      if open.blocked? do
        emit_approval_granted(open, attrs)
        %{open | blocked?: false}
      else
        open
      end

    %{state | opens: Map.put(state.opens, key, refresh_open(open, attrs))}
  end

  defp apply_state(state, key, open, :blocked, attrs) do
    unless open.blocked? do
      emit_approval_requested(open, attrs)
    end

    %{state | opens: Map.put(state.opens, key, %{refresh_open(open, attrs) | blocked?: true})}
  end

  defp apply_state(state, key, open, :done, attrs) do
    open = maybe_clear_block(open, attrs, :granted)
    finish_run(state, key, open, :succeeded, attrs)
  end

  defp apply_state(state, key, open, :idle, attrs) do
    # Prefer close over hang: idle after work means the turn ended without an
    # explicit done report (common when a Stop hook is missed).
    open = maybe_clear_block(open, attrs, :granted)
    finish_run(state, key, open, :succeeded, attrs)
  end

  defp apply_state(state, key, open, :errored, attrs) do
    open = maybe_clear_block(open, attrs, :denied)
    finish_run(state, key, open, :failed, attrs)
  end

  defp apply_state(state, key, open, :stalled, attrs) do
    # Design requires a distinct timeout close for stalled/wedged — not silence.
    # Duration is whatever produced `:stalled` upstream (AgentState stall window);
    # this module does not invent a second timer.
    open = maybe_clear_block(open, attrs, :denied)
    finish_run(state, key, open, :timed_out, attrs)
  end

  defp do_note_send_command(state, attrs) do
    with workspace_id when is_binary(workspace_id) <- attrs.workspace_id,
         session when is_binary(session) <- attrs.tmux_session,
         pane when is_binary(pane) <- attrs.pane_id do
      key = {session, pane}

      case Map.get(state.opens, key) do
        nil -> open_run(state, key, attrs, "send_command")
        open -> %{state | opens: Map.put(state.opens, key, refresh_open(open, attrs))}
      end
    else
      _ -> state
    end
  end

  defp do_prune_session(state, tmux_session, live_panes) do
    {keep, drop} =
      Enum.split_with(state.opens, fn {{session, pane}, _open} ->
        session != tmux_session or MapSet.member?(live_panes, pane)
      end)

    Enum.each(drop, fn {_key, open} ->
      emit_finished(open, :abandoned, %{
        workspace_id: open.workspace_id,
        actor_id: open.actor_id,
        message: "pane closed",
        source: :prune
      })
    end)

    %{state | opens: Map.new(keep)}
  end

  defp open_run(state, key, attrs, opened_by) do
    run_id = Ledger.new_run_id()
    issue = issue_for(attrs.tmux_session, attrs.pane_id)

    open = %{
      run_id: run_id,
      workspace_id: attrs.workspace_id,
      actor_id: attrs.actor_id,
      tmux_session: attrs.tmux_session,
      pane_id: attrs.pane_id,
      issue: issue,
      opened_by: opened_by,
      blocked?: false
    }

    _ =
      Ledger.run_started(%{
        workspace_id: open.workspace_id,
        actor_id: open.actor_id || "agent",
        run_id: run_id,
        command_id: "agent.lifecycle",
        metadata: base_meta(open, attrs, opened_by)
      })

    %{state | opens: Map.put(state.opens, key, open)}
  end

  defp finish_run(state, key, open, status, attrs) do
    emit_finished(open, status, attrs)
    %{state | opens: Map.delete(state.opens, key)}
  end

  defp emit_finished(open, status, attrs) do
    _ =
      Ledger.run_finished(status, %{
        workspace_id: open.workspace_id,
        actor_id: attrs[:actor_id] || open.actor_id || "agent",
        run_id: open.run_id,
        command_id: "agent.lifecycle",
        metadata:
          base_meta(open, attrs, open.opened_by)
          |> maybe_put("close_reason", attrs[:message])
          |> maybe_put("close_source", attrs[:source])
      })

    :ok
  end

  defp emit_approval_requested(open, attrs) do
    _ =
      Ledger.approval_requested(%{
        workspace_id: open.workspace_id,
        actor_id: attrs.actor_id || open.actor_id || "agent",
        run_id: open.run_id,
        command_id: "agent.lifecycle",
        metadata: base_meta(open, attrs, open.opened_by)
      })

    :ok
  end

  defp emit_approval_granted(open, attrs) do
    _ =
      Ledger.approval_granted(%{
        workspace_id: open.workspace_id,
        actor_id: attrs.actor_id || open.actor_id || "agent",
        run_id: open.run_id,
        command_id: "agent.lifecycle",
        metadata: base_meta(open, attrs, open.opened_by)
      })

    :ok
  end

  defp emit_approval_denied(open, attrs) do
    _ =
      Ledger.approval_denied(%{
        workspace_id: open.workspace_id,
        actor_id: attrs.actor_id || open.actor_id || "agent",
        run_id: open.run_id,
        command_id: "agent.lifecycle",
        metadata: base_meta(open, attrs, open.opened_by)
      })

    :ok
  end

  defp maybe_clear_block(%{blocked?: true} = open, attrs, :granted) do
    emit_approval_granted(open, attrs)
    %{open | blocked?: false}
  end

  defp maybe_clear_block(%{blocked?: true} = open, attrs, :denied) do
    emit_approval_denied(open, attrs)
    %{open | blocked?: false}
  end

  defp maybe_clear_block(open, _attrs, _outcome), do: open

  defp refresh_open(open, attrs) do
    %{
      open
      | actor_id: attrs.actor_id || open.actor_id,
        issue: issue_for(attrs.tmux_session, attrs.pane_id) || open.issue
    }
  end

  defp issue_for(session, pane) do
    case IssueBinding.get(session, pane) do
      %{issue: issue} when is_integer(issue) -> issue
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp base_meta(open, attrs, opened_by) do
    %{
      "source" => "agent_lifecycle",
      "plane" => "agent",
      "opened_by" => opened_by,
      "tmux_session" => open.tmux_session,
      "pane" => open.pane_id,
      "agent_session_id" => attrs[:agent_session_id],
      "tool" => attrs[:tool],
      "message" => attrs[:message],
      "semantic_state" => attrs[:state] && to_string(attrs[:state])
    }
    |> maybe_put("issue", open.issue || attrs[:issue])
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
    |> Map.new()
  end

  defp maybe_put(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_attrs(attrs) do
    %{
      workspace_id: bin(attrs, :workspace_id) || bin(attrs, "workspace_id"),
      tmux_session: bin(attrs, :tmux_session) || bin(attrs, "tmux_session"),
      pane_id: bin(attrs, :pane_id) || bin(attrs, "pane_id"),
      actor_id: bin(attrs, :actor_id) || bin(attrs, "actor_id"),
      agent_session_id: bin(attrs, :agent_session_id) || bin(attrs, "agent_session_id"),
      tool: bin(attrs, :tool) || bin(attrs, "tool"),
      message: bin(attrs, :message) || bin(attrs, "message"),
      source: attrs[:source] || attrs["source"],
      state: normalize_state(attrs[:state] || attrs["state"]),
      issue: attrs[:issue] || attrs["issue"]
    }
  end

  defp bin(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp normalize_state(state)
       when state in [:working, :blocked, :done, :idle, :errored, :stalled],
       do: state

  defp normalize_state("working"), do: :working
  defp normalize_state("blocked"), do: :blocked
  defp normalize_state("done"), do: :done
  defp normalize_state("idle"), do: :idle
  defp normalize_state("errored"), do: :errored
  defp normalize_state("stalled"), do: :stalled
  defp normalize_state(_), do: nil
end
