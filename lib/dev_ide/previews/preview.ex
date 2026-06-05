defmodule DevIDE.Previews.Preview do
  use Ecto.Schema
  import Ecto.Changeset

  schema "previews" do
    field :url, :string
    field :title, :string
    field :mode, Ecto.Enum, values: [:tab, :iframe]
    field :status, Ecto.Enum, values: [:open, :closed, :error]
    field :trusted, :boolean, default: false
    field :workspace_id, :string
    field :session_id, :string
    field :pane_id, :string
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  def changeset(preview, attrs) do
    preview
    |> cast(attrs, [
      :url,
      :title,
      :mode,
      :status,
      :trusted,
      :workspace_id,
      :session_id,
      :pane_id,
      :metadata
    ])
    |> validate_required([:url, :workspace_id])
    |> validate_inclusion(:status, [:open, :closed, :error])
    |> validate_url()
    |> put_default_mode()
    |> put_default_status()
  end

  defp validate_url(changeset) do
    validate_change(changeset, :url, fn :url, url ->
      if DevIDE.Previews.Url.valid_preview_url?(url) do
        []
      else
        [url: "must be a valid localhost http or https URL"]
      end
    end)
  end

  defp put_default_mode(changeset) do
    case get_field(changeset, :mode) do
      nil -> put_change(changeset, :mode, :tab)
      _ -> changeset
    end
  end

  defp put_default_status(changeset) do
    case get_field(changeset, :status) do
      nil -> put_change(changeset, :status, :open)
      _ -> changeset
    end
  end
end
