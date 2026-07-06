defmodule DevIDE.Files.FilePaneRegistration do
  @moduledoc """
  Persisted binding of a file pane to a tmux pane id.

  Mirrors `DevIDE.Previews.PreviewPaneRegistration` in spirit: it survives
  LiveView reconnect and server restart so a file pane (and its open tabs)
  rehydrate. Deliberately stores **only** the tab list + active path — never
  file content or version tokens, which are always derived fresh from disk on
  read so a stale token can never clobber a concurrently-edited file.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "file_pane_registrations" do
    field :workspace_id, :string
    field :tmux_session, :string
    field :pane_id, :string
    field :pane_window_id, :string
    field :placement, :string
    field :anchor_pane_id, :string
    field :anchor_window_id, :string
    # Ordered tabs: [%{"path" => rel, "line" => int | nil}]
    field :open_files, {:array, :map}, default: []
    field :active_path, :string
    field :status, Ecto.Enum, values: [:open, :closed]

    timestamps(type: :utc_datetime)
  end

  def changeset(registration, attrs) do
    registration
    |> cast(attrs, [
      :workspace_id,
      :tmux_session,
      :pane_id,
      :pane_window_id,
      :placement,
      :anchor_pane_id,
      :anchor_window_id,
      :open_files,
      :active_path,
      :status
    ])
    |> validate_required([:workspace_id, :pane_id])
    |> put_default_status()
  end

  defp put_default_status(changeset) do
    case get_field(changeset, :status) do
      nil -> put_change(changeset, :status, :open)
      _ -> changeset
    end
  end
end
