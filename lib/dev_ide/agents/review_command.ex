defmodule DevIDE.Agents.ReviewCommand do
  @moduledoc """
  Allowlisted review-mode agent command.

  M8 contract: argv is **fixed at compile time** and chosen by id from an
  allowlist. User payloads pick an id; they never supply argv. `requires` is
  matched against the workspace's detected `Capability.kind`s before the run
  is allowed to start.

  M8 seed allowlist contains only diagnostic invocations because no
  write-free upstream OpenCode review subcommand exists yet. Add more ids
  here when one does; do not invent argv inline elsewhere.
  """

  alias DevIDE.Agents.Capability

  @type id :: String.t()
  @type output_kind :: :diagnostic | :transcript | :proposal

  @type t :: %__MODULE__{
          id: id(),
          argv: [String.t()],
          requires: [Capability.kind()],
          output_kind: output_kind(),
          description: String.t()
        }

  @enforce_keys [:id, :argv, :requires, :output_kind, :description]
  defstruct [:id, :argv, :requires, :output_kind, :description]

  @spec all() :: [t()]
  def all do
    [
      %__MODULE__{
        id: "opencode-version",
        argv: ["opencode", "--version"],
        requires: [:opencode],
        output_kind: :diagnostic,
        description:
          "Print the OpenCode version. Diagnostic only — proves the supervised run lifecycle without invoking any agent action."
      }
    ]
  end

  @spec fetch(id()) :: {:ok, t()} | :error
  def fetch(id) when is_binary(id) do
    case Enum.find(all(), &(&1.id == id)) do
      nil -> :error
      cmd -> {:ok, cmd}
    end
  end

  def fetch(_), do: :error

  @spec available?(t(), [Capability.t()]) :: boolean()
  def available?(%__MODULE__{requires: req}, caps) when is_list(caps) do
    detected = caps |> Enum.filter(&(&1.status == :detected)) |> Enum.map(& &1.kind)
    Enum.all?(req, &(&1 in detected))
  end
end
