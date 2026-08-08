defmodule Casein.Cockpit.Inspectors do
  @moduledoc """
  LiveView-owned inspector viewports and the workspace PubSub surface request.

  Inspectors are **not** registry-backed feature panes. They own nothing durable:
  reopening re-derives them. An agent (or any process) can ask a mounted cockpit
  to surface one via `request_open/2`; if nobody is watching, nothing happens.

  Socket state shape (viewer-local):

      inspector_panes: [%{id: String.t(), kind: atom(), title: String.t() | nil, attrs: map()}]
      cockpit_geometry: Casein.Cockpit.Geometry.t()
      inspector_placement: :right | :bottom
      inspector_fraction: float()
  """

  alias Casein.Cockpit.Geometry

  @pubsub Casein.PubSub
  @topic_prefix "cockpit_inspectors:"

  @type pane :: %{
          id: String.t(),
          kind: atom(),
          title: String.t() | nil,
          attrs: map()
        }

  @doc "PubSub topic a cockpit LiveView subscribes to for surface requests."
  @spec topic(String.t()) :: String.t()
  def topic(workspace_id) when is_binary(workspace_id), do: @topic_prefix <> workspace_id

  @doc "Subscribe the caller to inspector surface requests for `workspace_id`."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(workspace_id) when is_binary(workspace_id) do
    Phoenix.PubSub.subscribe(@pubsub, topic(workspace_id))
  end

  @doc """
  Ask mounted cockpits to surface an inspector.

  Broadcasts `{:inspector_open, attrs}` on the workspace topic. No registry —
  unwatched workspaces drop the message.
  """
  @spec request_open(String.t(), map() | keyword()) :: :ok
  def request_open(workspace_id, attrs) when is_binary(workspace_id) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      topic(workspace_id),
      {:inspector_open, normalize_request(attrs)}
    )
  end

  @doc "Empty inspector list + full-bleed terminal geometry."
  @spec initial_assigns(keyword()) :: map()
  def initial_assigns(opts \\ []) do
    placement = normalize_placement(Keyword.get(opts, :placement, :right))
    fraction = normalize_fraction(Keyword.get(opts, :fraction, 0.4))

    %{
      inspector_panes: [],
      inspector_placement: placement,
      inspector_fraction: fraction,
      cockpit_geometry: Geometry.terminal_only()
    }
  end

  @doc "Open (or replace same-id) an inspector pane in the viewer-local list."
  @spec open([pane()], map() | keyword(), keyword()) :: {[pane()], Geometry.t()}
  def open(panes, attrs, opts \\ []) when is_list(panes) do
    pane = build_pane(attrs)
    panes = upsert(panes, pane)
    {panes, geometry(panes, opts)}
  end

  @doc "Close one inspector by id. Empty list restores terminal-only geometry."
  @spec close([pane()], String.t(), keyword()) :: {[pane()], Geometry.t()}
  def close(panes, id, opts \\ []) when is_list(panes) and is_binary(id) do
    panes = Enum.reject(panes, &(&1.id == id))
    {panes, geometry(panes, opts)}
  end

  @doc "Close every inspector."
  @spec close_all(keyword()) :: {[pane()], Geometry.t()}
  def close_all(opts \\ []) do
    {[], Geometry.for_inspectors([], opts)}
  end

  @doc "Recompute geometry from current panes + placement/fraction prefs."
  @spec geometry([pane()], keyword()) :: Geometry.t()
  def geometry(panes, opts \\ []) when is_list(panes) do
    Geometry.for_inspectors(panes,
      placement: Keyword.get(opts, :placement, :right),
      fraction: Keyword.get(opts, :fraction, 0.4)
    )
  end

  defp upsert(panes, pane) do
    case Enum.find_index(panes, &(&1.id == pane.id)) do
      nil -> panes ++ [pane]
      idx -> List.replace_at(panes, idx, pane)
    end
  end

  defp build_pane(attrs) when is_list(attrs), do: build_pane(Map.new(attrs))

  defp build_pane(attrs) when is_map(attrs) do
    kind = normalize_kind(Map.get(attrs, :kind) || Map.get(attrs, "kind") || :inspector)
    id = Map.get(attrs, :id) || Map.get(attrs, "id") || default_id(kind)
    title = Map.get(attrs, :title) || Map.get(attrs, "title")
    rest = Map.drop(attrs, [:id, "id", :kind, "kind", :title, "title", :attrs, "attrs"])
    nested = Map.get(attrs, :attrs) || Map.get(attrs, "attrs") || %{}

    %{
      id: to_string(id),
      kind: kind,
      title: title,
      attrs: Map.merge(stringify_keys(rest), stringify_keys(nested))
    }
  end

  defp normalize_request(attrs) when is_list(attrs), do: normalize_request(Map.new(attrs))
  defp normalize_request(attrs) when is_map(attrs), do: attrs
  defp normalize_request(_), do: %{}

  defp normalize_kind(kind) when is_atom(kind), do: kind

  defp normalize_kind(kind) when is_binary(kind) do
    String.to_existing_atom(kind)
  rescue
    ArgumentError -> :inspector
  end

  defp normalize_kind(_), do: :inspector

  defp normalize_placement(p) when p in [:right, :bottom], do: p
  defp normalize_placement("right"), do: :right
  defp normalize_placement("bottom"), do: :bottom
  defp normalize_placement(_), do: :right

  defp normalize_fraction(f) when is_float(f) and f > 0.0 and f < 1.0, do: f
  defp normalize_fraction(f) when is_integer(f) and f > 0 and f < 100, do: f / 100
  defp normalize_fraction(_), do: 0.4

  defp default_id(kind), do: "insp-#{kind}-#{System.unique_integer([:positive])}"

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp stringify_keys(_), do: %{}
end
