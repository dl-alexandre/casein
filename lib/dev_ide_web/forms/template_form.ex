defmodule CaseinWeb.Forms.TemplateForm do
  @moduledoc "Schemaless changeset for tmux template save/edit metadata forms."

  import Ecto.Changeset

  @types %{
    id: :string,
    source_id: :string,
    name: :string,
    description: :string,
    tags: :string
  }

  @doc false
  def from_params(params) when is_map(params) do
    normalized =
      %{"name" => "", "description" => "", "tags" => ""}
      |> Map.merge(Map.new(params, fn {key, value} -> {to_string(key), value} end))

    {%{}, @types}
    |> cast(normalized, [:id, :source_id, :name, :description, :tags])
    |> trim_strings()
  end

  @doc false
  def validate(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([:name])
    |> validate_length(:name, max: 255)
  end

  @doc false
  def apply(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate()
    |> apply_changes()
  end

  defp trim_strings(changeset) do
    Enum.reduce([:name, :description, :tags], changeset, fn field, cs ->
      update_change(cs, field, fn
        value when is_binary(value) -> String.trim(value)
        value -> value
      end)
    end)
  end

  @doc false
  def to_form(%Ecto.Changeset{} = changeset, opts \\ []) do
    form_data =
      changeset
      |> apply_changes()
      |> Map.new(fn {key, value} ->
        {Atom.to_string(key), value || ""}
      end)

    Phoenix.Component.to_form(form_data, Keyword.merge([as: :template], opts))
  end
end
