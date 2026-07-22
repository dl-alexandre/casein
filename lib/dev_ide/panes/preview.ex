defmodule DevIDE.Panes.Preview do
  @moduledoc """
  Deprecated alias for `DevIDE.Previews.Pane`.

  Kept so the historical module atom remains resolvable if any pane-type
  registry or external reference still points at `DevIDE.Panes.Preview`.
  New code should use `DevIDE.Previews.Pane`.
  """

  @behaviour DevIDE.Panes.Pane

  alias DevIDE.Previews.Pane

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
