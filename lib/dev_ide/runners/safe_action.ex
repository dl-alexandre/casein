defmodule DevIDE.Runners.SafeAction do
  @moduledoc """
  Authoritative registry of actions a durable runner may execute.

  Assignments store only a `safe_action_id`. The executable argv is resolved
  from this registry at claim/replay time, never from request payloads or
  persisted assignment metadata.
  """

  alias DevIDE.Commands
  alias DevIDE.Terminals.Workflows

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
    static_actions() ++ workflow_actions()
  end

  defp static_actions do
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

  defp workflow_actions do
    Workflows.list_command_ids()
    |> Enum.flat_map(fn command_id ->
      case workflow_action(command_id) do
        {:ok, action} -> [action]
        :error -> []
      end
    end)
  end

  @spec fetch(String.t()) :: {:ok, t()} | :error
  def fetch(id) when is_binary(id) do
    cond do
      String.starts_with?(id, "command:workflow:") ->
        id
        |> String.replace_prefix("command:", "")
        |> workflow_action()

      true ->
        case Enum.find(all(), &(&1.id == id)) do
          nil -> :error
          action -> {:ok, action}
        end
    end
  end

  def fetch(_), do: :error

  @spec fetch_command(String.t()) :: {:ok, t()} | :error
  def fetch_command(command_id) when is_binary(command_id) do
    case Workflows.fetch_command(command_id) do
      {:ok, _} -> workflow_action(command_id)
      :error -> fetch(id_for_command(command_id))
    end
  end

  def fetch_command(_), do: :error

  @spec compatible?(t(), [String.t()]) :: boolean()
  def compatible?(%__MODULE__{requires: requires}, capabilities) when is_list(capabilities) do
    caps = MapSet.new(capabilities)
    Enum.all?(requires, &MapSet.member?(caps, &1))
  end

  def compatible?(_, _), do: false

  @spec compatible_ids([String.t()]) :: [String.t()]
  def compatible_ids(capabilities) when is_list(capabilities) do
    ids =
      all()
      |> Enum.filter(&compatible?(&1, capabilities))
      |> Enum.map(& &1.id)

    if @runner_capability in capabilities, do: ["command:workflow:" | ids], else: ids
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

  defp workflow_action(command_id) do
    case Workflows.fetch_command(command_id) do
      {:ok, workflow} ->
        {:ok,
         %__MODULE__{
           id: id_for_command(workflow.command_id),
           version: @version,
           kind: :workspace_command,
           command_id: workflow.command_id,
           argv: workflow.argv,
           requires: [@runner_capability],
           description: workflow.description
         }}

      :error ->
        :error
    end
  end

  defp id_for_command(command_id), do: "command:" <> command_id
end
