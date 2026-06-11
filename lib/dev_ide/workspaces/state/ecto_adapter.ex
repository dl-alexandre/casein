defmodule DevIDE.Workspaces.State.EctoAdapter do
  @moduledoc "Postgres-backed adapter for `DevIDE.Workspaces.State`."

  @behaviour DevIDE.Workspaces.State.Adapter

  alias DevIDE.Workspaces.State.WorkspaceRecord
  alias DevIde.Repo
  import Ecto.Query

  defmodule Row do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}
    schema "workspace_records" do
      field :external_id, :string
      field :name, :string
      field :host_path, :string
      field :status, :string
      field :mode, :string
      field :db_isolation, :string
      field :db_isolation_source, :string
      field :db_isolation_summary, :string
      field :db_isolation_detected_at, :utc_datetime_usec
      field :manager_payload, :map, default: %{}
      field :last_seen_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end
  end

  @impl true
  def upsert(%WorkspaceRecord{} = r) do
    attrs = Map.from_struct(r) |> Map.drop([:id, :inserted_at, :updated_at])

    %Row{}
    |> Ecto.Changeset.change(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: :external_id,
      returning: true
    )
    |> case do
      {:ok, row} -> {:ok, to_record(row)}
      {:error, _} = err -> err
    end
  end

  @impl true
  def get(external_id) do
    case Repo.get_by(Row, external_id: external_id) do
      nil -> :error
      row -> {:ok, to_record(row)}
    end
  end

  @impl true
  def list do
    Row
    |> order_by([r], asc: r.name)
    |> Repo.all()
    |> Enum.map(&to_record/1)
  end

  @impl true
  def delete(external_id) do
    case Repo.get_by(Row, external_id: external_id) do
      nil ->
        :ok

      row ->
        Repo.delete(row)
        |> case do
          {:ok, _} -> :ok
          {:error, _} = err -> err
        end
    end
  end

  defp to_record(%Row{} = r) do
    %WorkspaceRecord{
      id: r.id,
      external_id: r.external_id,
      name: r.name,
      host_path: r.host_path,
      status: r.status,
      mode: r.mode,
      db_isolation: r.db_isolation,
      db_isolation_source: r.db_isolation_source,
      db_isolation_summary: r.db_isolation_summary,
      db_isolation_detected_at: r.db_isolation_detected_at,
      manager_payload: r.manager_payload || %{},
      last_seen_at: r.last_seen_at,
      inserted_at: r.inserted_at,
      updated_at: r.updated_at
    }
  end
end
