defmodule Casein.Terminals.TmuxTopology do
  @moduledoc """
  Casein facade over `TmuxCtl.Topology` and `TmuxCtl.Topology.Watcher`.

  Preserves the historical public API and PubSub message tuple
  `{Casein.Terminals.TmuxTopology, msg}` for LiveView compatibility.
  Audit on session terminate is emitted via an injected watcher callback.
  """

  alias Casein.Audit
  alias Casein.Terminals.PaneState
  alias Casein.Terminals.Tmux
  alias TmuxCtl.Topology
  alias TmuxCtl.Topology.Watcher

  @registry Casein.Terminals.TopologyRegistry
  @supervisor Casein.Terminals.TopologySupervisor
  @pubsub Casein.PubSub
  @topic_prefix "terminal_topology:"

  @type window :: Topology.window()
  @type pane :: Topology.pane()
  @type t :: Topology.t()

  @doc """
  Return the current window topology for a session.

  With no options, this uses the supervised watcher when available, starting it
  on demand. Passing `:tmux` preserves the original direct-read behavior for
  tests and call sites that need a specific adapter.
  """
  @spec get(String.t(), keyword()) :: t()
  def get(session, opts \\ []) when is_binary(session) do
    Watcher.get(session, watcher_opts(opts))
    |> PaneState.enrich_topology()
  end

  @doc "Read topology directly from tmux without using the watcher process."
  @spec snapshot(String.t(), keyword()) :: t()
  def snapshot(session, opts \\ []) when is_binary(session) do
    opts = Keyword.put_new_lazy(opts, :tmux, &tmux_adapter/0)

    Topology.snapshot(session, opts)
    |> PaneState.enrich_topology()
  end

  @doc "Start the topology watcher for a tmux session if needed."
  @spec ensure_started(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(session, opts \\ []) when is_binary(session) do
    Watcher.ensure_started(session, watcher_opts(opts))
  end

  @doc "Request an immediate refresh from the topology watcher."
  @spec refresh(String.t()) :: :ok | {:error, term()}
  def refresh(session) when is_binary(session) do
    Watcher.refresh(session, watcher_opts([]))
  end

  @doc "Update polling options for a running topology watcher."
  @spec configure(String.t(), keyword()) :: :ok | {:error, term()}
  def configure(session, opts) when is_binary(session) and is_list(opts) do
    Watcher.configure(session, watcher_opts(opts))
  end

  @doc "Refresh the watcher immediately and return the updated topology."
  @spec refresh_now(String.t(), keyword()) :: t()
  def refresh_now(session, opts \\ []) when is_binary(session) do
    Watcher.refresh_now(session, watcher_opts(opts))
    |> PaneState.enrich_topology()
  end

  @doc "Subscribe the caller to topology updates for a tmux session."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(session) when is_binary(session) do
    Watcher.subscribe(session, watcher_opts([]))
  end

  @doc """
  Register the caller as a live consumer of the session's watcher.
  """
  @spec watch(String.t(), keyword()) :: :ok | {:error, term()}
  def watch(session, opts \\ []) when is_binary(session) do
    Watcher.watch(session, watcher_opts(opts))
  end

  @doc "Deregister the caller as a consumer of the session's watcher."
  @spec unwatch(String.t()) :: :ok
  def unwatch(session) when is_binary(session) do
    Watcher.unwatch(session, watcher_opts([]))
  end

  @doc """
  Moves the caller's topology subscription from `old_session` to
  `new_session` in one step.
  """
  @spec switch_subscription(String.t() | nil, String.t(), keyword()) ::
          {:ok, %{session: String.t(), generation: pos_integer() | nil, topology: t()}}
  def switch_subscription(old_session, new_session, opts \\ []) when is_binary(new_session) do
    with {:ok, %{topology: topology} = result} <-
           Watcher.switch_subscription(old_session, new_session, watcher_opts(opts)) do
      {:ok, %{result | topology: PaneState.enrich_topology(topology)}}
    end
  end

  @doc "Return the PubSub topic used for a tmux session."
  @spec topic(String.t()) :: String.t()
  def topic(session) when is_binary(session), do: @topic_prefix <> session

  defp watcher_opts(opts) do
    opts
    |> Keyword.put_new(:registry, @registry)
    |> Keyword.put_new(:supervisor, @supervisor)
    |> Keyword.put_new(:pubsub, @pubsub)
    |> Keyword.put_new(:broadcast_tag, __MODULE__)
    |> Keyword.put_new(:topic_prefix, @topic_prefix)
    |> Keyword.put_new_lazy(:tmux_resolver, fn -> fn -> tmux_adapter() end end)
    |> Keyword.put_new_lazy(:on_session_terminated, &session_terminated_callback/0)
    |> Keyword.put_new(:topology_transform, &PaneState.enrich_topology/1)
    |> Keyword.put_new_lazy(:refresh_ms, fn ->
      Application.get_env(:dev_ide, :tmux_topology_refresh_ms, 300)
    end)
    |> Keyword.put_new_lazy(:reconcile_ms, fn ->
      Application.get_env(:dev_ide, :tmux_topology_reconcile_ms, 10_000)
    end)
    |> Keyword.put_new_lazy(:event_source, &event_source_opt/0)
    |> Keyword.put_new_lazy(:idle_stop_ms, fn ->
      Application.get_env(:dev_ide, :tmux_topology_idle_stop_ms, 60_000)
    end)
  end

  defp event_source_opt do
    if Casein.Terminals.TmuxEvents.enabled?() do
      {Casein.Terminals.TmuxEvents, []}
    end
  end

  defp session_terminated_callback do
    fn state, reason -> emit_session_terminated_audit(state, reason) end
  end

  defp tmux_adapter do
    Application.get_env(:dev_ide, :tmux_adapter, Tmux)
  end

  defp emit_session_terminated_audit(%{workspace_id: workspace_id} = state, reason)
       when is_binary(workspace_id) and workspace_id != "" do
    Audit.emit!(%{
      action: "tmux.session_terminated",
      workspace_id: workspace_id,
      actor_id: "system",
      target_type: "tmux_session",
      target_ref: state.session,
      metadata: %{
        session: state.session,
        reason: reason,
        last_topology_version: state.topology.version,
        active_window_id: state.topology.active_window_id,
        active_pane_id: state.topology.active_pane_id
      }
    })
  end

  defp emit_session_terminated_audit(_state, _reason), do: nil
end
