defmodule DevIDE.Runners.ProgressReportRow do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "runner_progress_reports" do
    field :assignment_id, :binary_id
    field :client_report_id, :string
    field :runner_id, :string
    field :position, :integer
    field :event, :string
    field :stream, :string
    field :message, :string
    field :data, :string
    field :data_truncated, :boolean, default: false
    field :evidence, :map, default: %{}
    field :observed_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
  end
end
