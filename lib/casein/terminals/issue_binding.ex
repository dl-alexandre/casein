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

  ## Duplicate-work guard

  Two live panes in the same workspace must not bind the same issue by default.
  `bind/5` refuses with a structured `:issue_already_bound` error naming the
  holder `pane_id`, `window_id`, and `issue`. `allow_duplicate: true` records
  both holders. A dead pane is pruned before the check, so it can never block
  re-dispatch.
  """

  use GenServer

  alias Phoenix.PubSub

  @topic_prefix "issue_binding:"

  @type entry :: %{
          issue: pos_integer(),
          url: String.t() | nil,
          title: String.t() | nil,
          bound_at: DateTime.t(),
          workspace_id: String.t() | nil,
          window_id: String.t() | nil
        }

  @type holder :: %{
          issue: pos_integer(),
          pane_id: String.t(),
          window_id: String.t() | nil,
          session: String.t(),
          workspace_id: String.t() | nil,
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

  Options:

    * `:allow_duplicate` — record a second live holder instead of refusing
    * `:window_id` — stored so a refusal can name the holder window
    * `:check_live` — evict dead-pane holders before the duplicate check
    * `:live?` — `(session, pane_id -> boolean() | :unknown)` for tests
  """
  @spec bind(String.t() | nil, String.t(), String.t(), term(), keyword()) ::
          {:ok, entry()} | {:error, :invalid_issue} | {:error, map()}
  def bind(workspace_id, tmux_session, pane_id, issue, opts \\ [])
      when is_binary(tmux_session) and is_binary(pane_id) do
    case normalize_issue(issue) do
      nil ->
        {:error, :invalid_issue}

      number ->
        if Keyword.get(opts, :check_live, false), do: prune_dead(workspace_id, number, opts)

        GenServer.call(
          __MODULE__,
          {:bind, workspace_id, tmux_session, pane_id, number,
           Keyword.take(opts, [:url, :title, :window_id, :allow_duplicate])}
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

  @doc """
  Workspace-scoped holders of an issue.

  One read-only call for "who is on #N in this workspace?". Pass `check_live:
  true` so a dead pane is dropped before the list is returned.
  """
  @spec holders(String.t() | nil, term(), keyword()) :: [holder()] | {:error, :invalid_issue}
  def holders(workspace_id, issue, opts \\ []) do
    case normalize_issue(issue) do
      nil ->
        {:error, :invalid_issue}

      number ->
        if Keyword.get(opts, :check_live, false), do: prune_dead(workspace_id, number, opts)
        GenServer.call(__MODULE__, {:holders, workspace_id, number})
    end
  end

  @doc """
  `:ok` when no other live holder exists, or the same structured refusal
  `bind/5` returns.
  """
  @spec check_available(String.t() | nil, term(), keyword()) :: :ok | {:error, term()}
  def check_available(workspace_id, issue, opts \\ []) do
    case holders(workspace_id, issue, opts) do
      {:error, _} = err ->
        err

      listed ->
        except = Keyword.get(opts, :except)
        others = reject_self(listed, except)

        cond do
          others == [] -> :ok
          Keyword.get(opts, :allow_duplicate, false) == true -> :ok
          true -> {:error, refusal(hd(others), hd(others).issue)}
        end
    end
  end

  @doc """
  Drop bindings whose panes are confirmed gone.

  A pane that cannot be observed (`:unknown`) is kept — fail closed, same as
  treating it as live. Only a positive "not in the session" evicts.
  """
  @spec prune_dead(String.t() | nil, term(), keyword()) :: :ok
  def prune_dead(workspace_id, issue, opts \\ []) do
    case normalize_issue(issue) do
      nil ->
        :ok

      number ->
        live? =
          case Keyword.get(opts, :live?) do
            fun when is_function(fun, 2) -> fun
            _ -> &default_pane_live?/2
          end

        number
        |> then(&GenServer.call(__MODULE__, {:holders, workspace_id, &1}))
        |> Enum.each(fn holder ->
          case live?.(holder.session, holder.pane_id) do
            false -> clear(workspace_id, holder.session, holder.pane_id)
            _ -> :ok
          end
        end)
    end
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
    others =
      state
      |> holders_in(workspace_id, number)
      |> reject_self({session, pane_id})

    cond do
      others != [] and Keyword.get(opts, :allow_duplicate, false) != true ->
        {:reply, {:error, refusal(hd(others), number)}, state}

      true ->
        entry = %{
          issue: number,
          url: Keyword.get(opts, :url),
          title: Keyword.get(opts, :title),
          bound_at: DateTime.utc_now(),
          workspace_id: workspace_id,
          window_id: Keyword.get(opts, :window_id)
        }

        state = Map.put(state, {session, pane_id}, entry)
        broadcast(workspace_id, session, pane_id, entry)
        {:reply, {:ok, entry}, state}
    end
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

  def handle_call({:holders, workspace_id, issue}, _from, state) do
    {:reply, holders_in(state, workspace_id, issue), state}
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

  defp holders_in(state, workspace_id, issue) do
    state
    |> Enum.flat_map(fn
      {{session, pane_id}, %{issue: ^issue} = entry} ->
        if workspace_match?(entry, workspace_id),
          do: [to_holder(session, pane_id, entry)],
          else: []

      _ ->
        []
    end)
    |> Enum.sort_by(&{&1.session, &1.pane_id})
  end

  defp workspace_match?(%{workspace_id: id}, id), do: true
  defp workspace_match?(_entry, _workspace_id), do: false

  defp to_holder(session, pane_id, entry) do
    %{
      issue: entry.issue,
      pane_id: pane_id,
      window_id: Map.get(entry, :window_id),
      session: session,
      workspace_id: Map.get(entry, :workspace_id),
      url: entry.url,
      title: entry.title,
      bound_at: entry.bound_at
    }
  end

  defp reject_self(holders, {session, pane_id}) do
    Enum.reject(holders, &(&1.session == session and &1.pane_id == pane_id))
  end

  defp reject_self(holders, %{session: session, pane_id: pane_id}) do
    reject_self(holders, {session, pane_id})
  end

  defp reject_self(holders, _), do: holders

  defp refusal(holder, issue) do
    %{
      error: :issue_already_bound,
      pane_id: holder.pane_id,
      window_id: holder.window_id,
      issue: issue,
      session: holder.session,
      message:
        "Issue ##{issue} is already bound to #{holder.pane_id}" <>
          window_suffix(holder.window_id) <> ".",
      escape_hatch: "allow_duplicate"
    }
  end

  defp window_suffix(id) when is_binary(id) and id != "", do: " (window #{id})"
  defp window_suffix(_), do: ""

  defp default_pane_live?(session, pane_id) when is_binary(session) and is_binary(pane_id) do
    adapter = Casein.Terminals.tmux_adapter()
    panes = list_session_panes(adapter, session)

    case panes do
      list when is_list(list) ->
        Enum.any?(list, fn pane -> pane_id_of(pane) == pane_id end)

      :unknown ->
        :unknown
    end
  rescue
    _ -> :unknown
  catch
    :exit, _ -> :unknown
  end

  defp default_pane_live?(_session, _pane_id), do: :unknown

  defp list_session_panes(adapter, session) do
    cond do
      function_exported?(adapter, :list_session_panes_result, 1) ->
        case adapter.list_session_panes_result(session) do
          {:ok, list} when is_list(list) -> list
          {:error, _} -> []
          _ -> :unknown
        end

      function_exported?(adapter, :list_session_panes, 1) ->
        adapter.list_session_panes(session)

      true ->
        :unknown
    end
  end

  defp pane_id_of(pane) when is_map(pane), do: Map.get(pane, :id) || Map.get(pane, "id")
  defp pane_id_of(_), do: nil

  defp broadcast(workspace_id, session, pane_id, entry) when is_binary(workspace_id) do
    PubSub.broadcast(
      Casein.PubSub,
      topic(workspace_id),
      {:issue_binding_updated, session, pane_id, entry}
    )
  end

  defp broadcast(_workspace_id, _session, _pane_id, _entry), do: :ok
end
