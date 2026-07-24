defmodule Casein.Panes.Preview do
  @moduledoc """
  Deprecated alias for `Casein.Previews.Pane`.

  Kept so the historical module atom remains resolvable if any pane-type
  registry or external reference still points at `Casein.Panes.Preview`.
  New code should use `Casein.Previews.Pane`.
  """

  @behaviour Casein.Panes.Pane

  alias Casein.Previews.Pane

  @impl true
  defdelegate attach(node, ctx), to: Pane

  @impl true
  defdelegate serialize(pane_id), to: Pane

  @impl true
  defdelegate terminate(pane_id), to: Pane

  @impl true
  defdelegate render_payload(pane_id), to: Pane

  defdelegate render_payload_from(reg), to: Pane

  @impl true
  defdelegate list(workspace_id), to: Pane

  @impl true
  defdelegate handle_input(pane_id, input), to: Pane

  @impl true
  defdelegate set_active(pane_id, active?), to: Pane
end
