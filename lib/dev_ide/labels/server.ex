defmodule DevIDE.Labels.Server do
  @moduledoc false

  use GenServer

  alias Phoenix.PubSub

  @topic_prefix "pane_labels:"
  @debounce_ms 30_000
  @max_entries 500
  @quiet_suffix " · quiet"
  @registered_name :"Elixir.DevIDE.Labels"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, @registered_name))
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
      |> Map.new(fn {{session, pane}, entry} -> {label_key(session, pane), entry} end)

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
  defp label_key(tmux_session, pane_id), do: tmux_session <> "::" <> pane_id
end
