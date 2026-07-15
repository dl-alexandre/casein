defmodule DevIDE.PreviewPanes.PreviewPaneRegistration do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "preview_pane_registrations" do
    field :workspace_id, :string
    field :tmux_session, :string
    field :pane_id, :string
    field :url, :string
    field :display_url, :string
    field :source_url, :string
    field :viewport, :map
    field :shared, :boolean, default: false
    field :source_pane_id, :string
    field :placement, :string
    field :anchor_pane_id, :string
    field :anchor_window_id, :string
    field :pane_window_id, :string
    field :status, Ecto.Enum, values: [:open, :closed]

    belongs_to :preview, DevIDE.Previews.Preview
    belongs_to :control_session, DevIDE.Previews.ControlSession

    timestamps(type: :utc_datetime)
  end

  def changeset(registration, attrs) do
    registration
    |> cast(attrs, [
      :workspace_id,
      :tmux_session,
      :pane_id,
      :preview_id,
      :control_session_id,
      :url,
      :display_url,
      :source_url,
      :viewport,
      :shared,
      :source_pane_id,
      :placement,
      :anchor_pane_id,
      :anchor_window_id,
      :pane_window_id,
      :status
    ])
    |> validate_required([
      :workspace_id,
      :pane_id,
      :preview_id,
      :control_session_id,
      :url,
      :display_url
    ])
    |> put_default_status()
  end

  defp put_default_status(changeset) do
    case get_field(changeset, :status) do
      nil -> put_change(changeset, :status, :open)
      _ -> changeset
    end
  end
end
