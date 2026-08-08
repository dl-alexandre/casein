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

  @doc """
  Serialize open inspectors for a session template (issue #691).

  Records kind + optional path only — restore reopens the viewport and the
  LiveView re-derives content from current git state. There is no snapshot.
  """
  @spec serialize([pane()]) :: [map()]
  def serialize(panes) when is_list(panes) do
    Enum.map(panes, fn pane ->
      base = %{
        "type" => "inspector",
        "kind" => kind_string(pane.kind)
      }

      path = pane_path(pane)

      if is_binary(path) and path != "" do
        Map.put(base, "path", path)
      else
        base
      end
    end)
  end

  def serialize(_), do: []

  @doc """
  Restore inspector viewports from a serialized template fragment.

  Returns `{panes, geometry}` with fresh ids — identity is not durable.
  """
  @spec restore(term(), keyword()) :: {[pane()], Geometry.t()}
  def restore(list, opts \\ [])

  def restore(list, opts) when is_list(list) do
    panes =
      list
      |> Enum.map(&cast_serialized/1)
      |> Enum.reject(&is_nil/1)

    {panes, geometry(panes, opts)}
  end

  def restore(_, opts), do: {[], Geometry.for_inspectors([], opts)}

  @doc "Primary (first) diff path among open inspectors, if any."
  @spec primary_diff_path([pane()]) :: String.t() | nil
  def primary_diff_path(panes) when is_list(panes) do
    panes
    |> Enum.filter(&(&1.kind == :diff))
    |> Enum.find_value(&pane_path/1)
  end

  def primary_diff_path(_), do: nil

  @doc "True when any open inspector is a diff viewport."
  @spec diff_open?([pane()]) :: boolean()
  def diff_open?(panes) when is_list(panes), do: Enum.any?(panes, &(&1.kind == :diff))
  def diff_open?(_), do: false

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

  defp kind_string(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp kind_string(kind) when is_binary(kind), do: kind
  defp kind_string(_), do: "inspector"

  defp pane_path(%{attrs: attrs}) when is_map(attrs) do
    case attrs["path"] || attrs[:path] do
      path when is_binary(path) ->
        case String.trim(path) do
          "" -> nil
          p -> p
        end

      _ ->
        nil
    end
  end

  defp pane_path(_), do: nil

  defp cast_serialized(%{"type" => "inspector"} = raw), do: cast_serialized_kind(raw)
  defp cast_serialized(%{type: "inspector"} = raw), do: cast_serialized_kind(raw)
  defp cast_serialized(%{"kind" => _} = raw), do: cast_serialized_kind(raw)
  defp cast_serialized(%{kind: _} = raw), do: cast_serialized_kind(raw)
  defp cast_serialized(_), do: nil

  defp cast_serialized_kind(raw) when is_map(raw) do
    kind = Map.get(raw, "kind") || Map.get(raw, :kind) || :inspector
    path = Map.get(raw, "path") || Map.get(raw, :path)
    title = Map.get(raw, "title") || Map.get(raw, :title)

    attrs =
      cond do
        is_binary(path) and String.trim(path) != "" ->
          %{kind: normalize_kind(kind), title: title || path, path: String.trim(path)}

        true ->
          %{kind: normalize_kind(kind), title: title}
      end

    build_pane(attrs)
  end
end
