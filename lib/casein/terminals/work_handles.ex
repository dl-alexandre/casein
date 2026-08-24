defmodule Casein.Terminals.WorkHandles do
  @moduledoc """
  Durable work handles for agent tasks.

  Pane ids are ephemeral: `respawn-pane -k`, wedge recovery, and window
  renumber all invalidate every outstanding pane reference. Orchestrators then
  fall back to screen-scraping lane labels, which drift from reality.

  A **work handle** is an id that outlives the pane currently serving it.
  Create one, attach (or reattach) it to a runtime pane, and resolve it back to
  whichever pane currently holds it. Status is always taken from **recorded**
  state (`Casein.Terminals.AgentState` plus the handle's own recorded fields) —
  never from the pane's rendered title or scrollback.

  ## Failure direction

  Losing the pane binding is cheap — the handle stays and can be reattached.
  Deleting a handle because its pane died is exactly the wrong direction: that
  is the failure mode this module exists to prevent. `prune_session/2` only
  clears the pane pointer on dead panes; the handle itself remains.

  ## Why not `IssueBinding` or `AgentState`

  * `IssueBinding` keys by pane and is cleared on pane close (a claim must not
    outlive its agent). Handles must do the opposite.
  * `AgentState` expires and is a semantic report, not a durable identity.
  """

  use GenServer

  alias Casein.Terminals.AgentState
  alias Phoenix.PubSub

  @topic_prefix "work_handles:"
  @id_bytes 16

  @type handle_id :: String.t()

  @type t :: %{
          handle_id: handle_id(),
          workspace_id: String.t(),
          session: String.t() | nil,
          pane_id: String.t() | nil,
          label: String.t() | nil,
          runtime: String.t() | nil,
          task_slug: String.t() | nil,
          worktree_path: String.t() | nil,
          branch: String.t() | nil,
          window_id: String.t() | nil,
          window_name: String.t() | nil,
          recorded_status: String.t() | nil,
          message: String.t() | nil,
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          attached_at: DateTime.t() | nil
        }

  ## Client API

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Create a durable work handle.

  Optional `:session` + `:pane_id` attach it immediately. Optional
  `:recorded_status` / `:message` / `:label` are stored on the handle itself so
  status never depends on scraping the pane.
  """
  @spec create(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def create(workspace_id, opts \\ []) when is_binary(workspace_id) do
    GenServer.call(__MODULE__, {:create, workspace_id, opts})
  end

  @doc """
  Attach (or reattach) an existing handle to a pane.

  This is the respawn path: the handle id stays the same, the pane pointer
  moves. Returns `{:error, :unknown_handle}` when the id is missing.
  """
  @spec attach(handle_id(), String.t(), String.t(), String.t()) ::
          {:ok, t()} | {:error, :unknown_handle | :workspace_mismatch}
  def attach(handle_id, workspace_id, session, pane_id)
      when is_binary(handle_id) and is_binary(workspace_id) and is_binary(session) and
             is_binary(pane_id) do
    GenServer.call(__MODULE__, {:attach, handle_id, workspace_id, session, pane_id})
  end

  @doc "Drop the pane binding without destroying the handle. Idempotent."
  @spec detach(handle_id()) :: :ok | {:error, :unknown_handle}
  def detach(handle_id) when is_binary(handle_id) do
    GenServer.call(__MODULE__, {:detach, handle_id})
  end

  @doc """
  Fetch a handle and resolve its current pane + recorded status.

  The returned map always includes:

    * handle fields (`handle_id`, `workspace_id`, `label`, …)
    * `pane` — `%{session, pane_id}` when attached, else `nil`
    * `status` — `%{source: "recorded", state, message}` from AgentState when
      the pane has a report, otherwise the handle's own `recorded_status`
  """
  @spec get(handle_id()) :: {:ok, map()} | {:error, :unknown_handle}
  def get(handle_id) when is_binary(handle_id) do
    case GenServer.call(__MODULE__, {:fetch, handle_id}) do
      {:ok, handle} -> {:ok, resolve(handle)}
      :error -> {:error, :unknown_handle}
    end
  end

  def get(_), do: {:error, :unknown_handle}

  @doc "All handles for a workspace, each resolved like `get/1`."
  @spec list(String.t()) :: [map()]
  def list(workspace_id) when is_binary(workspace_id) do
    GenServer.call(__MODULE__, {:list, workspace_id})
    |> Enum.map(&resolve/1)
    |> Enum.sort_by(& &1.handle_id)
  end

  @doc "Join inspectable work-handle identity onto an enriched tmux topology."
  @spec enrich_topology(map(), String.t() | nil, String.t()) :: map()
  def enrich_topology(%{panes: panes} = topology, workspace_id, session)
      when is_list(panes) and is_binary(workspace_id) and is_binary(session) do
    handles =
      workspace_id
      |> list()
      |> Enum.filter(&(&1.session == session))

    by_pane = Enum.group_by(handles, & &1.pane_id)

    topology
    |> Map.put(:work_handles, handles)
    |> Map.put(:work_handles_observe_state, "ok")
    |> Map.put(
      :panes,
      Enum.map(panes, fn pane ->
        pane_id = Map.get(pane, :id) || Map.get(pane, "id")
        pane_handles = Map.get(by_pane, pane_id, [])

        case Enum.max_by(pane_handles, & &1.updated_at, fn -> nil end) do
          nil ->
            pane

          handle ->
            pane
            |> Map.put(:work_handle, handle)
            |> Map.put(:work_handles, pane_handles)
            |> maybe_put_handle_label(handle)
        end
      end)
    )
  catch
    :exit, _ ->
      topology
      |> Map.put(:work_handles, [])
      |> Map.put(:work_handles_observe_state, "unavailable")
  end

  def enrich_topology(topology, _workspace_id, _session), do: topology

  @doc """
  Record status on the handle itself.

  Prefer this (or `AgentState.report/5`) over reading the pane title. Status on
  the wire always declares `source: \"recorded\"`.
  """
  @spec record_status(handle_id(), String.t() | atom(), String.t() | nil) ::
          {:ok, t()} | {:error, :unknown_handle}
  def record_status(handle_id, status, message \\ nil)
      when is_binary(handle_id) and (is_binary(status) or is_atom(status)) do
    GenServer.call(
      __MODULE__,
      {:record_status, handle_id, normalize_status(status), truncate_message(message)}
    )
  end

  @doc """
  Clear pane pointers for panes that no longer exist — **without** deleting
  the handles. A dead pane must not destroy the durable id.
  """
  @spec prune_session(String.t(), [String.t()]) :: :ok
  def prune_session(tmux_session, pane_ids)
      when is_binary(tmux_session) and is_list(pane_ids) do
    GenServer.cast(__MODULE__, {:prune_session, tmux_session, MapSet.new(pane_ids)})
  end

  @doc false
  @spec clear_all() :: :ok
  def clear_all, do: GenServer.call(__MODULE__, :clear_all)

  @spec subscribe(String.t()) :: :ok
  def subscribe(workspace_id) when is_binary(workspace_id),
    do: PubSub.subscribe(Casein.PubSub, topic(workspace_id))

  @doc false
  def topic(workspace_id), do: @topic_prefix <> workspace_id

  ## Server

  @impl GenServer
  def init(_opts), do: {:ok, %{}}

  @impl GenServer
  def handle_call({:create, workspace_id, opts}, _from, state) do
    now = DateTime.utc_now()
    session = blank_to_nil(Keyword.get(opts, :session))
    pane_id = blank_to_nil(Keyword.get(opts, :pane_id) || Keyword.get(opts, :pane))

    handle = %{
      handle_id: generate_id(),
      workspace_id: workspace_id,
      session: session,
      pane_id: pane_id,
      label: blank_to_nil(Keyword.get(opts, :label)),
      runtime: blank_to_nil(Keyword.get(opts, :runtime)),
      task_slug: blank_to_nil(Keyword.get(opts, :task_slug)),
      worktree_path: blank_to_nil(Keyword.get(opts, :worktree_path)),
      branch: blank_to_nil(Keyword.get(opts, :branch)),
      window_id: blank_to_nil(Keyword.get(opts, :window_id)),
      window_name: blank_to_nil(Keyword.get(opts, :window_name)),
      recorded_status:
        normalize_status(Keyword.get(opts, :recorded_status) || Keyword.get(opts, :status)),
      message: truncate_message(Keyword.get(opts, :message)),
      created_at: now,
      updated_at: now,
      attached_at: if(session && pane_id, do: now, else: nil)
    }

    state = Map.put(state, handle.handle_id, handle)
    broadcast(workspace_id, handle)
    {:reply, {:ok, handle}, state}
  end

  def handle_call({:attach, handle_id, workspace_id, session, pane_id}, _from, state) do
    case Map.fetch(state, handle_id) do
      {:ok, %{workspace_id: ^workspace_id} = handle} ->
        now = DateTime.utc_now()

        handle = %{
          handle
          | session: session,
            pane_id: pane_id,
            attached_at: now,
            updated_at: now
        }

        state = Map.put(state, handle_id, handle)
        broadcast(workspace_id, handle)
        {:reply, {:ok, handle}, state}

      {:ok, _other_ws} ->
        {:reply, {:error, :workspace_mismatch}, state}

      :error ->
        {:reply, {:error, :unknown_handle}, state}
    end
  end

  def handle_call({:detach, handle_id}, _from, state) do
    case Map.fetch(state, handle_id) do
      {:ok, handle} ->
        handle = %{
          handle
          | session: nil,
            pane_id: nil,
            attached_at: nil,
            updated_at: DateTime.utc_now()
        }

        state = Map.put(state, handle_id, handle)
        broadcast(handle.workspace_id, handle)
        {:reply, :ok, state}

      :error ->
        {:reply, {:error, :unknown_handle}, state}
    end
  end

  def handle_call({:fetch, handle_id}, _from, state) do
    {:reply, Map.fetch(state, handle_id), state}
  end

  def handle_call({:list, workspace_id}, _from, state) do
    handles =
      for {_id, %{workspace_id: ^workspace_id} = handle} <- state, do: handle

    {:reply, handles, state}
  end

  def handle_call({:record_status, handle_id, status, message}, _from, state) do
    case Map.fetch(state, handle_id) do
      {:ok, handle} ->
        handle = %{
          handle
          | recorded_status: status,
            message: message || handle.message,
            updated_at: DateTime.utc_now()
        }

        state = Map.put(state, handle_id, handle)
        broadcast(handle.workspace_id, handle)
        {:reply, {:ok, handle}, state}

      :error ->
        {:reply, {:error, :unknown_handle}, state}
    end
  end

  def handle_call(:clear_all, _from, _state), do: {:reply, :ok, %{}}

  @impl GenServer
  def handle_cast({:prune_session, session, live_panes}, state) do
    state =
      Enum.reduce(state, state, fn
        {id, %{session: ^session, pane_id: pane_id} = handle}, acc
        when is_binary(pane_id) ->
          if MapSet.member?(live_panes, pane_id) do
            acc
          else
            # Pane is gone — keep the durable id, drop only the pointer.
            handle = %{
              handle
              | session: nil,
                pane_id: nil,
                attached_at: nil,
                updated_at: DateTime.utc_now()
            }

            broadcast(handle.workspace_id, handle)
            Map.put(acc, id, handle)
          end

        {_id, _handle}, acc ->
          acc
      end)

    {:noreply, state}
  end

  ## Resolve

  defp resolve(handle) do
    pane =
      if is_binary(handle.session) and is_binary(handle.pane_id) do
        %{session: handle.session, pane_id: handle.pane_id}
      else
        nil
      end

    %{
      handle_id: handle.handle_id,
      workspace_id: handle.workspace_id,
      label: handle.label,
      runtime: handle.runtime,
      task_slug: handle.task_slug,
      worktree_path: handle.worktree_path,
      branch: handle.branch,
      window_id: handle.window_id,
      window_name: handle.window_name,
      session: handle.session,
      pane_id: handle.pane_id,
      pane: pane,
      status: recorded_status(handle),
      created_at: DateTime.to_iso8601(handle.created_at),
      updated_at: DateTime.to_iso8601(handle.updated_at),
      attached_at: iso_or_nil(handle.attached_at)
    }
  end

  # Status is always from recorded state — AgentState report when present,
  # otherwise the handle's own recorded_status. Never pane title / task_summary.
  defp recorded_status(%{session: session, pane_id: pane_id} = handle)
       when is_binary(session) and is_binary(pane_id) do
    case AgentState.get(session, pane_id) do
      %{state: state, message: message} ->
        %{
          source: "recorded",
          state: Atom.to_string(state),
          message: message || handle.message
        }

      _ ->
        handle_recorded(handle)
    end
  end

  defp recorded_status(handle), do: handle_recorded(handle)

  defp handle_recorded(handle) do
    %{
      source: "recorded",
      state: handle.recorded_status || "unknown",
      message: handle.message
    }
  end

  ## Internals

  defp generate_id do
    @id_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp normalize_status(nil), do: nil
  defp normalize_status(status) when is_atom(status), do: Atom.to_string(status)

  defp normalize_status(status) when is_binary(status) do
    status = String.trim(status)
    if status == "", do: nil, else: status
  end

  defp normalize_status(_), do: nil

  defp truncate_message(nil), do: nil

  defp truncate_message(message) when is_binary(message) do
    message = String.trim(message)

    cond do
      message == "" -> nil
      String.length(message) <= 200 -> message
      true -> String.slice(message, 0, 200)
    end
  end

  defp truncate_message(_), do: nil

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp blank_to_nil(_), do: nil

  defp iso_or_nil(nil), do: nil
  defp iso_or_nil(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp maybe_put_handle_label(pane, %{label: label}) when is_binary(label) and label != "" do
    if Map.get(pane, :label) || Map.get(pane, "label") do
      pane
    else
      Map.put(pane, :label, label)
    end
  end

  defp maybe_put_handle_label(pane, _handle), do: pane

  defp broadcast(workspace_id, handle) when is_binary(workspace_id) do
    PubSub.broadcast(
      Casein.PubSub,
      topic(workspace_id),
      {:work_handle_updated, handle.handle_id, handle}
    )
  end

  defp broadcast(_workspace_id, _handle), do: :ok
end
