defmodule DevIDE.Labels do
  @moduledoc """
  Ephemeral conversation-aware pane labels for DevIDE chrome.

  Labels are keyed by `{tmux_session, pane_id}` and broadcast to workspace
  LiveViews. They never mutate tmux window or pane titles.
  """

  use GenServer

  alias DevIDE.Labels.Derivation
  alias Phoenix.PubSub

  @topic_prefix "pane_labels:"
  @debounce_ms 30_000
  @max_entries 500
  @quiet_suffix " · quiet"

  @type source :: :mcp | :annotation | :agent | :quiet | :manual

  @type entry :: %{
          label: String.t(),
          base_label: String.t() | nil,
          source: source(),
          tool: String.t() | nil,
          frozen?: boolean(),
          updated_at: DateTime.t()
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec subscribe(String.t()) :: :ok
  def subscribe(workspace_id) when is_binary(workspace_id) do
    PubSub.subscribe(DevIde.PubSub, topic(workspace_id))
  end

  @spec key(String.t(), String.t()) :: String.t()
  def key(tmux_session, pane_id) when is_binary(tmux_session) and is_binary(pane_id),
    do: tmux_session <> "::" <> pane_id

  @spec get(String.t(), String.t()) :: entry() | nil
  def get(tmux_session, pane_id) when is_binary(tmux_session) and is_binary(pane_id) do
    GenServer.call(__MODULE__, {:get, {tmux_session, pane_id}})
  end

  @spec for_session(String.t()) :: %{String.t() => entry()}
  def for_session(tmux_session) when is_binary(tmux_session) do
    GenServer.call(__MODULE__, {:for_session, tmux_session})
  end

  @spec propose_from_mcp(String.t() | nil, String.t(), map(), :ok | {:error, term()}) :: :ok
  def propose_from_mcp(workspace_id, tool, args, result)
      when is_binary(tool) and is_map(args) do
    source = if tool == "annotation_propose", do: :annotation, else: :mcp

    with label when is_binary(label) <- Derivation.from_mcp(tool, args, result),
         {session, pane_id} <- mcp_target(args, result),
         true <- is_binary(workspace_id) do
      propose(workspace_id, session, pane_id, label, source, tool, immediate?: false)
    else
      _ -> :ok
    end
  end

  @spec set_agent_label(String.t(), String.t(), String.t(), String.t(), keyword()) :: :ok
  def set_agent_label(workspace_id, tmux_session, pane_id, label, opts \\ [])
      when is_binary(workspace_id) and is_binary(tmux_session) and is_binary(pane_id) and
             is_binary(label) do
    case Derivation.from_agent_label(label) do
      nil ->
        :ok

      normalized ->
        freeze? = Keyword.get(opts, :freeze, false)
        source = if freeze?, do: :manual, else: :agent

        propose(
          workspace_id,
          tmux_session,
          pane_id,
          normalized,
          source,
          "terminal_set_agent_label",
          immediate?: true,
          frozen?: freeze?
        )
    end
  end

  @spec mark_quiet(String.t() | nil, String.t(), String.t()) :: :ok
  def mark_quiet(workspace_id, tmux_session, pane_id)
      when is_binary(tmux_session) and is_binary(pane_id) do
    GenServer.cast(__MODULE__, {:mark_quiet, workspace_id, tmux_session, pane_id})
  end

  @spec clear_quiet(String.t() | nil, String.t(), String.t()) :: :ok
  def clear_quiet(workspace_id, tmux_session, pane_id)
      when is_binary(tmux_session) and is_binary(pane_id) do
    GenServer.cast(__MODULE__, {:clear_quiet, workspace_id, tmux_session, pane_id})
  end

  @spec prune_session(String.t(), [String.t()]) :: :ok
  def prune_session(tmux_session, pane_ids) when is_binary(tmux_session) and is_list(pane_ids) do
    GenServer.cast(__MODULE__, {:prune_session, tmux_session, MapSet.new(pane_ids)})
  end

  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  defp propose(workspace_id, tmux_session, pane_id, label, source, tool, opts) do
    GenServer.cast(__MODULE__, {
      :propose,
      workspace_id,
      tmux_session,
      pane_id,
      label,
      source,
      tool,
      opts
    })
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:get, key}, _from, state) do
    {:reply, Map.get(state, key), state}
  end

  def handle_call({:for_session, tmux_session}, _from, state) do
    labels =
      state
      |> Enum.filter(fn {{session, _pane}, _entry} -> session == tmux_session end)
      |> Map.new(fn {{session, pane}, entry} -> {key(session, pane), entry} end)

    {:reply, labels, state}
  end

  def handle_call(:clear, _from, _state), do: {:reply, :ok, %{}}

  @impl true
  def handle_cast(
        {:propose, workspace_id, tmux_session, pane_id, label, source, tool, opts},
        state
      ) do
    key = {tmux_session, pane_id}
    immediate? = Keyword.get(opts, :immediate?, false)
    frozen? = Keyword.get(opts, :frozen?, false)
    now = DateTime.utc_now()

    case Map.get(state, key) do
      %{frozen?: true} ->
        {:noreply, state}

      current ->
        if immediate? or should_update?(current, label, now) do
          entry = %{
            label: label,
            base_label: label,
            source: source,
            tool: tool,
            frozen?: frozen?,
            updated_at: now
          }

          state =
            state
            |> Map.put(key, entry)
            |> trim_size()

          broadcast(workspace_id, tmux_session, pane_id, entry)
          {:noreply, state}
        else
          {:noreply, state}
        end
    end
  end

  def handle_cast({:mark_quiet, workspace_id, tmux_session, pane_id}, state) do
    key = {tmux_session, pane_id}

    case Map.get(state, key) do
      %{frozen?: true} ->
        {:noreply, state}

      %{label: label, base_label: base} ->
        base = base || strip_quiet(label)

        if String.ends_with?(label, @quiet_suffix) do
          {:noreply, state}
        else
          commit_quiet(state, workspace_id, tmux_session, pane_id, base)
        end

      nil ->
        commit_quiet(state, workspace_id, tmux_session, pane_id, "agent")
    end
  end

  def handle_cast({:clear_quiet, workspace_id, tmux_session, pane_id}, state) do
    key = {tmux_session, pane_id}

    case Map.get(state, key) do
      %{frozen?: true} ->
        {:noreply, state}

      %{base_label: base, source: :quiet} = entry when is_binary(base) ->
        entry = %{entry | label: base, source: :mcp, updated_at: DateTime.utc_now()}
        broadcast(workspace_id, tmux_session, pane_id, entry)
        {:noreply, Map.put(state, key, entry)}

      %{label: label} = entry when is_binary(label) ->
        if String.ends_with?(label, @quiet_suffix) do
          base = strip_quiet(label)
          entry = %{entry | label: base, base_label: base, updated_at: DateTime.utc_now()}
          broadcast(workspace_id, tmux_session, pane_id, entry)
          {:noreply, Map.put(state, key, entry)}
        else
          {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_cast({:prune_session, tmux_session, pane_ids}, state) do
    pruned =
      Map.filter(state, fn {{session, pane}, _entry} ->
        session != tmux_session or MapSet.member?(pane_ids, pane)
      end)

    {:noreply, pruned}
  end

  defp commit_quiet(state, workspace_id, tmux_session, pane_id, base) do
    key = {tmux_session, pane_id}
    now = DateTime.utc_now()

    entry = %{
      label: base <> @quiet_suffix,
      base_label: base,
      source: :quiet,
      tool: nil,
      frozen?: false,
      updated_at: now
    }

    broadcast(workspace_id, tmux_session, pane_id, entry)
    {:noreply, Map.put(state, key, entry)}
  end

  defp should_update?(nil, _label, _now), do: true

  defp should_update?(%{label: current, updated_at: updated_at}, label, now) do
    current != label and DateTime.diff(now, updated_at, :millisecond) >= @debounce_ms
  end

  defp strip_quiet(label) when is_binary(label) do
    String.replace_suffix(label, @quiet_suffix, "")
  end

  defp trim_size(state) do
    if map_size(state) <= @max_entries, do: state, else: trim_oldest(state)
  end

  defp trim_oldest(state) do
    state
    |> Enum.sort_by(fn {_key, %{updated_at: at}} -> at end, DateTime)
    |> Enum.take(-@max_entries)
    |> Map.new()
  end

  defp broadcast(workspace_id, tmux_session, pane_id, entry) when is_binary(workspace_id) do
    PubSub.broadcast(
      DevIde.PubSub,
      topic(workspace_id),
      {:pane_label_updated, tmux_session, pane_id, entry}
    )
  end

  defp broadcast(_workspace_id, _tmux_session, _pane_id, _entry), do: :ok

  defp topic(workspace_id), do: @topic_prefix <> workspace_id

  defp mcp_target(args, result) do
    session =
      arg(args, :session) || result_field(result, "session") || result_field(result, :session)

    pane =
      arg(args, :pane) || arg(args, :pane_id) ||
        result_field(result, "target") || result_field(result, :target)

    if is_binary(session) and session != "" and is_binary(pane) and pane != "" do
      {session, pane}
    else
      :error
    end
  end

  defp result_field({:ok, payload}, key) when is_map(payload), do: Map.get(payload, key)
  defp result_field(_, _), do: nil

  defp arg(args, key) when is_atom(key) do
    Map.get(args, Atom.to_string(key)) || Map.get(args, key)
  end
end
