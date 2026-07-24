defmodule CaseinWeb.Forms.PreviousSessionsSearch do
  @moduledoc "Schemaless changeset for the previous-sessions search form."

  import Ecto.Changeset

  @types %{
    query: :string,
    workspace: :string,
    source: :string,
    session: :string,
    pane: :string,
    since: :string,
    until: :string,
    limit: :integer
  }

  @default_limit 20
  @limit_options [10, 20, 50]

  @url_aliases %{
    "q" => "query",
    "workspace_id" => "workspace",
    "workspace_name" => "workspace",
    "sources" => "source",
    "session_id" => "session",
    "pane_id" => "pane",
    "from" => "since",
    "to" => "until"
  }

  @doc false
  def from_params(params) when is_map(params) do
    normalized = normalize_params(params)

    {%{}, @types}
    |> cast(normalized, Map.keys(@types))
    |> trim_strings()
    |> clamp_limit()
  end

  @doc false
  def to_filters(%Ecto.Changeset{} = changeset) do
    defaults = %{
      query: "",
      workspace: "",
      source: "",
      session: "",
      pane: "",
      since: "",
      until: "",
      limit: @default_limit
    }

    Map.merge(defaults, apply_changes(changeset))
  end

  @doc false
  def to_form(%Ecto.Changeset{} = changeset, opts \\ []) do
    form_data =
      changeset
      |> apply_changes()
      |> Map.new(fn {key, value} ->
        {Atom.to_string(key), form_value(key, value)}
      end)

    Phoenix.Component.to_form(form_data, Keyword.merge([as: :search], opts))
  end

  @doc false
  def search_opts(filters) when is_map(filters) do
    [
      query: filters.query,
      workspace: filters.workspace,
      source: filters.source,
      session: filters.session,
      pane: filters.pane,
      since: filters.since,
      until: filters.until,
      limit: to_string(filters.limit)
    ]
  end

  defp normalize_params(params) do
    params
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      key = to_string(key)
      canonical = Map.get(@url_aliases, key, key)
      Map.put(acc, canonical, value)
    end)
  end

  defp trim_strings(changeset) do
    Enum.reduce(
      [:query, :workspace, :source, :session, :pane, :since, :until],
      changeset,
      fn field, cs ->
        update_change(cs, field, fn
          value when is_binary(value) -> String.trim(value)
          value -> value
        end)
      end
    )
  end

  defp clamp_limit(changeset) do
    limit =
      case get_change(changeset, :limit) || get_field(changeset, :limit) do
        value when value in @limit_options ->
          value

        value when is_binary(value) ->
          case Integer.parse(String.trim(value)) do
            {parsed, ""} when parsed in @limit_options -> parsed
            _ -> @default_limit
          end

        _ ->
          @default_limit
      end

    put_change(changeset, :limit, limit)
  end

  defp form_value(:limit, value) when is_integer(value), do: Integer.to_string(value)
  defp form_value(_key, value) when is_binary(value), do: value
  defp form_value(_key, nil), do: ""
  defp form_value(_key, value), do: to_string(value)
end
