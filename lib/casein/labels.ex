defmodule Casein.Labels do
  @moduledoc """
  Ephemeral conversation-aware pane labels for Casein chrome.

  Labels are keyed by `{tmux_session, pane_id}` and broadcast to workspace
  LiveViews. They never mutate tmux window or pane titles.
  """

  alias Casein.Labels.Derivation
  alias Phoenix.PubSub

  @topic_prefix "pane_labels:"

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
    Casein.Labels.Server.start_link(opts)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @spec subscribe(String.t()) :: :ok
  def subscribe(workspace_id) when is_binary(workspace_id) do
    PubSub.subscribe(Casein.PubSub, topic(workspace_id))
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

        tool = Keyword.get(opts, :tool, "terminal_set_agent_label")

        propose(
          workspace_id,
          tmux_session,
          pane_id,
          normalized,
          source,
          tool,
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

  @doc """
  Attach `:label` (display string) to topology panes from the session store.

  Pure join — does not invent labels. Used by fleet chrome so
  `terminal_topology` can distinguish `manager` vs `worker` without a
  separate Labels lookup.
  """
  @spec enrich_topology(map(), String.t()) :: map()
  def enrich_topology(%{panes: panes} = topology, tmux_session)
      when is_list(panes) and is_binary(tmux_session) do
    case for_session(tmux_session) do
      labels when map_size(labels) == 0 ->
        topology

      labels ->
        %{
          topology
          | panes:
              Enum.map(panes, fn pane ->
                pane_id = Map.get(pane, :id) || Map.get(pane, "id")

                entry =
                  if is_binary(pane_id) do
                    Map.get(labels, key(tmux_session, pane_id))
                  end

                case entry do
                  %{label: label} when is_binary(label) and label != "" ->
                    Map.put(pane, :label, label)

                  _ ->
                    pane
                end
              end)
        }
    end
  end

  def enrich_topology(topology, _tmux_session), do: topology

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
