defmodule DevIDE.Commands.History.EctoAdapter do
  @moduledoc "Postgres-backed adapter for `DevIDE.Commands.History`."
  @behaviour DevIDE.Commands.History

  alias DevIDE.Commands.History.Record
  alias DevIde.Repo
  import Ecto.Query

  defmodule Row do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: false}
    schema "command_run_records" do
      field :workspace_id, :string
      field :actor_id, :string
      field :command_id, :string
      field :argv, {:array, :string}, virtual: true
      field :argv_json, :map, source: :argv, default: %{}
      field :status, :string
      field :exit_code, :string
      field :output, :string
      field :output_truncated, :boolean, default: false
      field :started_at, :utc_datetime_usec
      field :finished_at, :utc_datetime_usec
      field :duration_ms, :integer
      field :metadata, :map, default: %{}
      timestamps(type: :utc_datetime_usec)
    end
  end

  @impl true
  def create(%Record{} = r) do
    attrs = %{
      id: r.id,
      workspace_id: r.workspace_id,
      actor_id: r.actor_id,
      command_id: r.command_id,
      argv_json: %{"argv" => r.argv},
      status: r.status,
      exit_code: r.exit_code,
      output: r.output,
      output_truncated: r.output_truncated,
      started_at: r.started_at,
      finished_at: r.finished_at,
      duration_ms: r.duration_ms,
      metadata: r.metadata || %{}
    }

    %Row{}
    |> Ecto.Changeset.change(attrs)
    |> Repo.insert()
    |> case do
      {:ok, row} -> {:ok, to_record(row)}
      {:error, _} = err -> err
    end
  end

  @impl true
  def update(id, attrs) do
    case Repo.get(Row, id) do
      nil ->
        {:error, :not_found}

      row ->
        merged_metadata = Map.merge(row.metadata || %{}, Map.get(attrs, :metadata, %{}))

        change_attrs =
          attrs
          |> Map.take(~w(status exit_code output output_truncated finished_at duration_ms)a)
          |> Map.put(:metadata, merged_metadata)

        row
        |> Ecto.Changeset.change(change_attrs)
        |> Repo.update()
        |> case do
          {:ok, row} -> {:ok, to_record(row)}
          {:error, _} = err -> err
        end
    end
  end

  @impl true
  def get(id) do
    case Repo.get(Row, id) do
      nil -> :error
      row -> {:ok, to_record(row)}
    end
  end

  @impl true
  def recent_for(workspace_id, limit) do
    Row
    |> where([r], r.workspace_id == ^workspace_id)
    |> order_by([r], desc: r.started_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(&to_record/1)
  end

  @impl true
  def list(opts) do
    n = Keyword.get(opts, :limit, 100)

    Row
    |> order_by([r], desc: r.started_at)
    |> limit(^n)
    |> Repo.all()
    |> Enum.map(&to_record/1)
  end

  defp to_record(%Row{} = r) do
    %Record{
      id: r.id,
      workspace_id: r.workspace_id,
      actor_id: r.actor_id,
      command_id: r.command_id,
      argv: argv_from_json(r.argv_json),
      status: r.status,
      exit_code: r.exit_code,
      output: r.output,
      output_truncated: r.output_truncated || false,
      started_at: r.started_at,
      finished_at: r.finished_at,
      duration_ms: r.duration_ms,
      metadata: r.metadata || %{},
      inserted_at: r.inserted_at,
      updated_at: r.updated_at
    }
  end

  defp argv_from_json(%{"argv" => list}) when is_list(list), do: list
  defp argv_from_json(_), do: []
end
