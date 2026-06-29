defmodule DevIdeWeb.CoreComponentsTableTestView do
  @moduledoc false
  use Phoenix.Component

  import DevIdeWeb.CoreComponents

  attr :id, :string, required: true
  attr :rows, :list, required: true

  def render(assigns) do
    ~H"""
    <.table id={@id} rows={@rows}>
      <:col :let={row} label="Name">{row.name}</:col>
      <:action :let={row}><span id={"act-#{row.id}"}>Edit</span></:action>
    </.table>
    """
  end
end
