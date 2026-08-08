defmodule Casein.Terminals.IssueBinding do
  @moduledoc """
  Binds a claimed GitHub issue to the pane working it.

  When a runner claims `queue/*` work (see the claim protocol in `AGENTS.md`),
  the claim lives in two places that cannot see each other: a label on the issue,
  and an agent in a tmux pane. This module is the join. Casein chrome and
  `terminal_topology` can then answer "what is this pane working on?" and,
  inversely, "is anyone actually on issue #N?".

  That second question is the one that matters operationally. A claim is a lease
  — an issue can sit `queue/claimed` long after the pane that claimed it died,
  and the only way to tell an abandoned claim from a slow one is to look at the
  pane. With the binding in topology, that check is a lookup instead of an
  archaeology exercise across issue comments.

  ## Why not `Labels` or `AgentState`

  Both already key by `{tmux_session, pane_id}`, prune on pane close, and
  broadcast to LiveViews, so either looks like a home at first glance:

    * `Casein.Labels` holds a *conversation label* — a derived, human-facing
      string that quiet-marking and MCP proposals rewrite. A binding is neither
      derived nor rewritable, and burying an issue number in a display string
      means parsing it back out to answer "who has #N".

    * `Casein.Terminals.AgentState` entries **expire** (30 min), because a stale
      state report should decay into the title heuristic. A binding must not:
      an agent thinking for an hour still owns its issue. Expiry is exactly the
      wrong failure direction here.

  So this is its own store, deliberately small, with the same key and the same
  prune contract as both.

  ## Failure direction

  Losing a binding is cheap — the issue still carries its `queue/claimed` label
  and its claim comment, which remain the source of truth. Showing a *wrong*
  binding is not cheap: it would tell an operator that a dead pane is working
  an issue. So every ambiguous case here resolves toward *no binding*: a crash
  empties the table, pruning is aggressive, and clearing is idempotent.
  """

  use GenServer

  alias Phoenix.PubSub

  @topic_prefix "issue_binding:"

  @type entry :: %{
          issue: pos_integer(),
          url: String.t() | nil,
          title: String.t() | nil,
          bound_at: DateTime.t()
        }

  ## Client API

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Bind an issue number to a pane. Re-binding replaces the previous binding.

  `issue` accepts an integer or a string like `"#678"` / `"678"`; anything else
  is a no-op rather than an error, so a malformed value can never leave a
  half-written binding.
  """
  @spec bind(String.t() | nil, String.t(), String.t(), term(), keyword()) ::
          {:ok, entry()} | {:error, :invalid_issue}
  def bind(workspace_id, tmux_session, pane_id, issue, opts \\ [])
      when is_binary(tmux_session) and is_binary(pane_id) do
    case normalize_issue(issue) do
      nil ->
        {:error, :invalid_issue}

      number ->
        GenServer.call(
          __MODULE__,
          {:bind, workspace_id, tmux_session, pane_id, number, Keyword.take(opts, [:url, :title])}
        )
    end
  end

  @doc "Remove a pane's binding. Idempotent."
  @spec clear(String.t() | nil, String.t(), String.t()) :: :ok
  def clear(workspace_id, tmux_session, pane_id)
      when is_binary(tmux_session) and is_binary(pane_id) do
    GenServer.call(__MODULE__, {:clear, workspace_id, tmux_session, pane_id})
  end

  @doc "The binding for a pane, or nil."
  @spec get(String.t(), String.t()) :: entry() | nil
  def get(tmux_session, pane_id) when is_binary(tmux_session) and is_binary(pane_id) do
    GenServer.call(__MODULE__, {:get, {tmux_session, pane_id}})
  end

  @doc "Bindings for a session, keyed by pane id."
  @spec for_session(String.t()) :: %{optional(String.t()) => entry()}
  def for_session(tmux_session) when is_binary(tmux_session) do
    GenServer.call(__MODULE__, {:for_session, tmux_session})
  end

  @doc """
  Panes currently bound to an issue, as `{tmux_session, pane_id}`.

  Answers "is anyone actually on #N?" — the inverse lookup that makes a stale
  `queue/claimed` label distinguishable from live work.
  """
  @spec panes_for_issue(pos_integer()) :: [{String.t(), String.t()}]
  def panes_for_issue(issue) when is_integer(issue) and issue > 0 do
    GenServer.call(__MODULE__, {:panes_for_issue, issue})
  end

  @doc "Drop bindings for panes that no longer exist in a session."
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

  @doc """
  Attach `:issue` to panes and windows in a topology.

  Runs alongside the other enrichers. A window takes the binding of its agent
  pane, so a collapsed window still shows what it is working on.
  """
  @spec enrich_topology(map(), String.t()) :: map()
  def enrich_topology(%{panes: panes, windows: windows} = topology, tmux_session)
      when is_list(panes) and is_list(windows) and is_binary(tmux_session) do
    case for_session(tmux_session) do
      bindings when map_size(bindings) == 0 ->
        topology

      bindings ->
        %{
          topology
          | panes: Enum.map(panes, &put_issue(&1, Map.get(bindings, map_get(&1, :id)))),
            windows: Enum.map(windows, &put_window_issue(&1, bindings))
        }
    end
  end

  def enrich_topology(topology, _tmux_session), do: topology

  @doc """
  Normalize an issue reference to a positive integer, or nil.

  Accepts `678`, `"678"`, `"#678"`, and a full issue URL, because all three turn
  up in claim comments and MCP arguments.
  """
  @spec normalize_issue(term()) :: pos_integer() | nil
  def normalize_issue(issue) when is_integer(issue) and issue > 0, do: issue

  def normalize_issue(issue) when is_binary(issue) do
    issue
    |> String.trim()
    |> String.trim_leading("#")
    |> String.split("/")
    |> List.last()
    |> Integer.parse()
    |> case do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  def normalize_issue(_issue), do: nil

  ## Server

  @impl GenServer
  def init(_opts), do: {:ok, %{}}

  @impl GenServer
  def handle_call({:bind, workspace_id, session, pane_id, number, opts}, _from, state) do
    entry = %{
      issue: number,
      url: Keyword.get(opts, :url),
      title: Keyword.get(opts, :title),
      bound_at: DateTime.utc_now()
    }

    state = Map.put(state, {session, pane_id}, entry)
    broadcast(workspace_id, session, pane_id, entry)
    {:reply, {:ok, entry}, state}
  end

  def handle_call({:clear, workspace_id, session, pane_id}, _from, state) do
    state = Map.delete(state, {session, pane_id})
    broadcast(workspace_id, session, pane_id, nil)
    {:reply, :ok, state}
  end

  def handle_call({:get, key}, _from, state), do: {:reply, Map.get(state, key), state}

  def handle_call({:for_session, session}, _from, state) do
    bindings =
      for {{s, pane_id}, entry} <- state, s == session, into: %{}, do: {pane_id, entry}

    {:reply, bindings, state}
  end

  def handle_call({:panes_for_issue, issue}, _from, state) do
    panes = for {{s, p}, %{issue: ^issue}} <- state, do: {s, p}
    {:reply, Enum.sort(panes), state}
  end

  def handle_call(:clear_all, _from, _state), do: {:reply, :ok, %{}}

  @impl GenServer
  def handle_cast({:prune_session, session, pane_ids}, state) do
    state =
      Enum.reduce(state, state, fn
        {{^session, pane_id} = key, _entry}, acc ->
          if MapSet.member?(pane_ids, pane_id), do: acc, else: Map.delete(acc, key)

        {_key, _entry}, acc ->
          acc
      end)

    {:noreply, state}
  end

  ## Internals

  defp put_issue(pane, nil), do: pane
  defp put_issue(pane, %{issue: issue}), do: Map.put(pane, :issue, issue)

  defp put_window_issue(window, bindings) do
    window
    |> window_pane_ids()
    |> Enum.find_value(&Map.get(bindings, &1))
    |> case do
      nil -> window
      %{issue: issue} -> Map.put(window, :issue, issue)
    end
  end

  defp window_pane_ids(window) do
    case map_get(window, :pane_list) do
      panes when is_list(panes) -> Enum.map(panes, &map_get(&1, :id))
      _ -> []
    end
  end

  defp map_get(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_get(_map, _key), do: nil

  defp broadcast(workspace_id, session, pane_id, entry) when is_binary(workspace_id) do
    PubSub.broadcast(
      Casein.PubSub,
      topic(workspace_id),
      {:issue_binding_updated, session, pane_id, entry}
    )
  end

  defp broadcast(_workspace_id, _session, _pane_id, _entry), do: :ok
end
