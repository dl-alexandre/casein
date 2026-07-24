defmodule Casein.Annotations.Annotation do
  @moduledoc """
  Structured human/agent annotation attached to workspace context.

  An annotation can point at terminal output, a file range, and eventually a
  preview/browser surface. `preview_id` is intentionally nullable and not a
  foreign key yet because the preview persistence model has not landed in this
  repo.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @author_types [:human, :agent_grok, :agent_codex, :agent_claude]
  @visibilities [:private, :shared, :per_agent]
  @approval_states [:pending, :approved, :rejected]

  schema "annotations" do
    field :content, :string
    field :author_type, Ecto.Enum, values: @author_types
    field :visibility, Ecto.Enum, values: @visibilities, default: :shared
    field :approval_state, Ecto.Enum, values: @approval_states, default: :approved

    field :workspace_id, :string
    field :session_id, :string
    field :pane_id, :string
    field :preview_id, :binary_id

    field :terminal_range, :map
    field :file_path, :string
    field :file_range, :map
    field :linked_entities, Casein.EctoTypes.MapList, default: []
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(annotation, attrs) do
    annotation
    |> cast(attrs, [
      :content,
      :author_type,
      :visibility,
      :approval_state,
      :workspace_id,
      :session_id,
      :pane_id,
      :preview_id,
      :terminal_range,
      :file_path,
      :file_range,
      :linked_entities,
      :metadata
    ])
    |> update_change(:content, &trim_content/1)
    |> validate_required([:content, :author_type, :workspace_id])
    |> validate_length(:content, min: 1, max: 20_000)
    |> validate_context_present()
  end

  def author_types, do: @author_types
  def visibilities, do: @visibilities
  def approval_states, do: @approval_states

  defp trim_content(content) when is_binary(content), do: String.trim(content)
  defp trim_content(content), do: content

  defp validate_context_present(changeset) do
    fields = [:terminal_range, :file_path, :file_range, :preview_id, :linked_entities]

    if Enum.any?(fields, &context_present?(get_field(changeset, &1))) do
      changeset
    else
      add_error(changeset, :base, "annotation must reference terminal, file, or preview context")
    end
  end

  defp context_present?(nil), do: false
  defp context_present?(""), do: false
  defp context_present?([]), do: false
  defp context_present?(%{} = map), do: map_size(map) > 0
  defp context_present?(_), do: true
end
