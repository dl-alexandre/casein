defmodule Casein.Cockpit.Inspectors do
  @moduledoc """
  LiveView-owned inspector viewports and the workspace PubSub surface request.

  Inspectors are **not** registry-backed feature panes. They own nothing durable:
  reopening re-derives them. An agent (or any process) can ask a mounted cockpit
  to surface one via `request_open/2`; if nobody is watching, nothing happens.

  ## Naming: `pane_id` vs `slot_id`

  - **`pane_id`** — a tmux pane / PTY (process + size, no layout position).
  - **`slot_id`** — a node in Casein's layout tree (position + size + filler).

  This module stores **slots**. A slot may be filled by an inspector viewport;
  it is never a tmux pane id. Do not rename tmux-facing `pane_id` identifiers
  to "slot" (issue #750).

  Socket state shape (viewer-local):

      inspector_slots: [%{id: slot_id(), kind: atom(), title: String.t() | nil, attrs: map()}]
      cockpit_geometry: Casein.Cockpit.Geometry.t()
      inspector_placement: :right | :bottom
      inspector_fraction: float()
  """

  alias Casein.Cockpit.Geometry

  @pubsub Casein.PubSub
  @topic_prefix "cockpit_inspectors:"

  @type slot_id :: String.t()

  @type slot :: %{
          id: slot_id(),
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
      inspector_slots: [],
      inspector_placement: placement,
      inspector_fraction: fraction,
      cockpit_geometry: Geometry.terminal_only()
    }
  end

  @doc """
  Open an inspector in the region.

  The region holds **one** inspector (#692): opening another replaces it.
  There is no tab strip; returning to a previous inspector is a palette action.
  """
  @spec open([slot()], map() | keyword(), keyword()) :: {[slot()], Geometry.t()}
  def open(slots, attrs, opts \\ []) when is_list(slots) do
    _ = slots
    slot = build_slot(attrs)
    slots = [slot]
    {slots, geometry(slots, opts)}
  end

  @doc "Close one inspector by `slot_id`. Empty list restores terminal-only geometry."
  @spec close([slot()], slot_id(), keyword()) :: {[slot()], Geometry.t()}
  def close(slots, id, opts \\ []) when is_list(slots) and is_binary(id) do
    slots = Enum.reject(slots, &(&1.id == id))
    {slots, geometry(slots, opts)}
  end

  @doc "Close every inspector."
  @spec close_all(keyword()) :: {[slot()], Geometry.t()}
  def close_all(opts \\ []) do
    {[], Geometry.for_inspectors([], opts)}
  end

  @doc "Recompute geometry from current slots + placement/fraction prefs."
  @spec geometry([slot()], keyword()) :: Geometry.t()
  def geometry(slots, opts \\ []) when is_list(slots) do
    Geometry.for_inspectors(slots,
      placement: Keyword.get(opts, :placement, :right),
      fraction: Keyword.get(opts, :fraction, 0.4)
    )
  end

  @doc """
  Serialize open inspectors for a session template (issues #691 / #694).

  Records kind + optional path/run_id only — restore reopens the viewport and
  the LiveView re-derives content from current git/ledger state. No snapshot.
  """
  @spec serialize([slot()]) :: [map()]
  def serialize(slots) when is_list(slots) do
    Enum.map(slots, fn slot ->
      base = %{
        "type" => "inspector",
        "kind" => kind_string(slot.kind)
      }

      base
      |> maybe_put_path(slot_path(slot))
      |> maybe_put_run_id(slot_run_id(slot))
    end)
  end

  def serialize(_), do: []

  @doc """
  Restore inspector viewports from a serialized template fragment.

  Returns `{slots, geometry}` with fresh ids — identity is not durable.
  """
  @spec restore(term(), keyword()) :: {[slot()], Geometry.t()}
  def restore(list, opts \\ [])

  def restore(list, opts) when is_list(list) do
    # One inspector at a time — keep the last serialized entry if a template
    # still carries a multi-inspector list from before #692's amendment.
    slots =
      list
      |> Enum.map(&cast_serialized/1)
      |> Enum.reject(&is_nil/1)
      |> List.last()
      |> List.wrap()

    {slots, geometry(slots, opts)}
  end

  def restore(_, opts), do: {[], Geometry.for_inspectors([], opts)}

  @doc "Primary (first) diff path among open inspectors, if any."
  @spec primary_diff_path([slot()]) :: String.t() | nil
  def primary_diff_path(slots) when is_list(slots) do
    slots
    |> Enum.filter(&(&1.kind == :diff))
    |> Enum.find_value(&slot_path/1)
  end

  def primary_diff_path(_), do: nil

  @doc "True when any open inspector is a diff viewport."
  @spec diff_open?([slot()]) :: boolean()
  def diff_open?(slots) when is_list(slots), do: Enum.any?(slots, &(&1.kind == :diff))
  def diff_open?(_), do: false

  @doc "Primary (first) run id among open run inspectors, if any."
  @spec primary_run_id([slot()]) :: String.t() | nil
  def primary_run_id(slots) when is_list(slots) do
    slots
    |> Enum.filter(&(&1.kind == :run))
    |> Enum.find_value(&slot_run_id/1)
  end

  def primary_run_id(_), do: nil

  @doc "True when any open inspector is a run viewport."
  @spec run_open?([slot()]) :: boolean()
  def run_open?(slots) when is_list(slots), do: Enum.any?(slots, &(&1.kind == :run))
  def run_open?(_), do: false

  defp build_slot(attrs) when is_list(attrs), do: build_slot(Map.new(attrs))

  defp build_slot(attrs) when is_map(attrs) do
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

  defp slot_path(%{attrs: attrs}) when is_map(attrs) do
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

  defp slot_path(_), do: nil

  defp slot_run_id(%{attrs: attrs}) when is_map(attrs) do
    case attrs["run_id"] || attrs[:run_id] do
      id when is_binary(id) ->
        case String.trim(id) do
          "" -> nil
          p -> p
        end

      _ ->
        nil
    end
  end

  defp slot_run_id(_), do: nil

  defp maybe_put_path(base, path) when is_binary(path) and path != "",
    do: Map.put(base, "path", path)

  defp maybe_put_path(base, _), do: base

  defp maybe_put_run_id(base, run_id) when is_binary(run_id) and run_id != "",
    do: Map.put(base, "run_id", run_id)

  defp maybe_put_run_id(base, _), do: base

  defp cast_serialized(%{"type" => "inspector"} = raw), do: cast_serialized_kind(raw)
  defp cast_serialized(%{type: "inspector"} = raw), do: cast_serialized_kind(raw)
  defp cast_serialized(%{"kind" => _} = raw), do: cast_serialized_kind(raw)
  defp cast_serialized(%{kind: _} = raw), do: cast_serialized_kind(raw)
  defp cast_serialized(_), do: nil

  defp cast_serialized_kind(raw) when is_map(raw) do
    kind = Map.get(raw, "kind") || Map.get(raw, :kind) || :inspector
    path = Map.get(raw, "path") || Map.get(raw, :path)
    run_id = Map.get(raw, "run_id") || Map.get(raw, :run_id)
    title = Map.get(raw, "title") || Map.get(raw, :title)
    kind_atom = normalize_kind(kind)

    attrs =
      %{kind: kind_atom, title: title}
      |> maybe_put_attr(:path, path)
      |> maybe_put_attr(:run_id, run_id)
      |> then(fn a ->
        cond do
          is_binary(a[:path]) and (is_nil(a[:title]) or a[:title] == "") ->
            Map.put(a, :title, a[:path])

          is_binary(a[:run_id]) and (is_nil(a[:title]) or a[:title] == "") ->
            Map.put(a, :title, "Run")

          true ->
            a
        end
      end)

    build_slot(attrs)
  end

  defp maybe_put_attr(map, _key, value) when value in [nil, ""], do: map

  defp maybe_put_attr(map, key, value) when is_binary(value) do
    case String.trim(value) do
      "" -> map
      trimmed -> Map.put(map, key, trimmed)
    end
  end

  defp maybe_put_attr(map, _key, _), do: map
end
