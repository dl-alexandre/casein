defmodule DevIDE.Commands.Annotations do
  @moduledoc """
  Public entry point for parsing Mix command output into annotations.
  """

  alias DevIDE.Commands.Annotations.{Annotation, MixParser}

  @spec from_record(map(), String.t() | nil) :: [Annotation.t()]
  def from_record(%{output: output, command_id: cmd}, root) do
    MixParser.parse(output || "", cmd, root)
  end

  def from_record(_, _), do: []

  @spec group_by_severity([Annotation.t()]) :: %{
          error: [Annotation.t()],
          warning: [Annotation.t()],
          info: [Annotation.t()]
        }
  def group_by_severity(annotations) do
    %{
      error: Enum.filter(annotations, &(&1.severity == :error)),
      warning: Enum.filter(annotations, &(&1.severity == :warning)),
      info: Enum.filter(annotations, &(&1.severity == :info))
    }
  end
end
