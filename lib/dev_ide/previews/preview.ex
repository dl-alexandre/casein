defmodule DevIDE.Previews.Preview do
  use Ecto.Schema
  import Ecto.Changeset

  schema "previews" do
    field :url, :string
    field :title, :string
    field :mode, Ecto.Enum, values: [:tab, :iframe]
    field :status, Ecto.Enum, values: [:open, :closed, :error]
    field :trusted, :boolean, default: false
    field :workspace_id, :binary_id
    field :session_id, :binary_id
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
      :trusted,
      :workspace_id,
      :session_id,
      :pane_id,
      :metadata
    ])
    |> validate_required([:url, :workspace_id])
    |> validate_url()
    |> put_default_mode()
    |> put_default_status()
  end

  defp validate_url(changeset) do
    validate_change(changeset, :url, fn :url, url ->
      if is_binary(url) and
           (String.starts_with?(url, "http://") or String.starts_with?(url, "https://")) do
        []
      else
        [url: "must be a valid http or https URL"]
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
