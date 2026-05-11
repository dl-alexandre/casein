defmodule DevIDE.Runners.SafeAction do
  @moduledoc """
  Authoritative registry of actions a durable runner may execute.

  Assignments store only a `safe_action_id`. The executable argv is resolved
  from this registry at claim/replay time, never from request payloads or
  persisted assignment metadata.
  """

  alias DevIDE.Commands

  @type t :: %__MODULE__{
          id: String.t(),
          version: pos_integer(),
          kind: :workspace_command,
          command_id: String.t(),
          argv: [String.t()],
          requires: [String.t()],
          description: String.t()
        }

  @enforce_keys [:id, :version, :kind, :command_id, :argv, :requires, :description]
  defstruct [:id, :version, :kind, :command_id, :argv, :requires, :description]

  @runner_capability "workspace-command:v1"
  @version 1

  @spec all() :: [t()]
  def all do
    Commands.allowlist()
    |> Enum.sort_by(fn {id, _argv} -> id end)
    |> Enum.map(fn {command_id, argv} ->
      %__MODULE__{
        id: id_for_command(command_id),
        version: @version,
        kind: :workspace_command,
        command_id: command_id,
        argv: argv,
        requires: [@runner_capability],
        description: "Run the allowlisted #{command_id} workspace command."
      }
    end)
  end

  @spec fetch(String.t()) :: {:ok, t()} | :error
  def fetch(id) when is_binary(id) do
    case Enum.find(all(), &(&1.id == id)) do
      nil -> :error
      action -> {:ok, action}
    end
  end

  def fetch(_), do: :error

  @spec fetch_command(String.t()) :: {:ok, t()} | :error
  def fetch_command(command_id) when is_binary(command_id),
    do: fetch(id_for_command(command_id))

  def fetch_command(_), do: :error

  @spec compatible?(t(), [String.t()]) :: boolean()
  def compatible?(%__MODULE__{requires: requires}, capabilities) when is_list(capabilities) do
    caps = MapSet.new(capabilities)
    Enum.all?(requires, &MapSet.member?(caps, &1))
  end

  def compatible?(_, _), do: false

  @spec compatible_ids([String.t()]) :: [String.t()]
  def compatible_ids(capabilities) when is_list(capabilities) do
    all()
    |> Enum.filter(&compatible?(&1, capabilities))
    |> Enum.map(& &1.id)
  end

  def compatible_ids(_), do: []

  @spec to_runner_payload(t()) :: map()
  def to_runner_payload(%__MODULE__{} = action) do
    %{
      id: action.id,
      version: action.version,
      kind: Atom.to_string(action.kind),
      command_id: action.command_id,
      argv: action.argv,
      requires: action.requires,
      description: action.description
    }
  end

  defp id_for_command(command_id), do: "command:" <> command_id
end
