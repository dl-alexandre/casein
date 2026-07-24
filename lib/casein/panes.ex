defmodule Casein.Panes do
  @moduledoc """
  Facade over every feature-pane type, so the web layer sees one uniform surface.

  A "feature pane" is a pane whose live render/input state is addressable purely
  from a registry (previews, files) — as opposed to terminal panes, which are
  served by `PaneWorker`. The facade folds only the types that implement the
  runtime callbacks (`render_payload/1` + `list/1`); terminals are skipped.

  Convention: `c:Casein.Panes.Pane.render_payload/1` returns a **non-empty** map
  for a pane the type owns and an **empty** map (`%{}`) for an unknown pane id.
  The facade relies on this to identify a pane's owning type without a separate
  lookup callback.
  """

  alias Casein.Panes.Pane

  @type snapshot :: %{optional(String.t()) => %{type: atom(), payload: map()}}

  @doc """
  Every renderable feature pane for a workspace, keyed by pane id.

  Used for mount-time hydration and reconnect: `%{pane_id => %{type, payload}}`.
  """
  @spec snapshot(String.t()) :: snapshot()
  def snapshot(workspace_id) when is_binary(workspace_id) do
    for type <- feature_types(),
        impl = Pane.impl(type),
        pane_ref <- impl.list(workspace_id),
        payload = impl.render_payload(pane_ref),
        map_size(payload) > 0,
        into: %{} do
      {pane_ref, %{type: type, payload: payload}}
    end
  end

  @doc """
  Resolve a pane id to its owning feature type and current render payload.

  Returns `{type, payload}` or `nil`. Used to authorize and route generic
  `pane:input` events without the web layer knowing the concrete registry.
  """
  @spec get_by_pane(String.t()) :: {atom(), map()} | nil
  def get_by_pane(pane_id) when is_binary(pane_id) do
    Enum.find_value(feature_types(), fn type ->
      impl = Pane.impl(type)

      case impl.render_payload(pane_id) do
        payload when is_map(payload) and map_size(payload) > 0 -> {type, payload}
        _ -> nil
      end
    end)
  end

  @doc "Feature-pane types — those that expose the runtime render/list callbacks."
  @spec feature_types() :: [atom()]
  def feature_types do
    Enum.filter(Pane.types(), fn type ->
      impl = Pane.impl(type)

      Code.ensure_loaded?(impl) and function_exported?(impl, :render_payload, 1) and
        function_exported?(impl, :list, 1)
    end)
  end
end
