defmodule Casein.Terminals.CommandRedactor do
  @moduledoc """
  Redaction hook for terminal command records before they enter CommandLog.
  """

  @callback redact(binary(), map()) :: binary()

  @spec redact(binary() | nil, map()) :: binary() | nil
  def redact(data, metadata \\ %{})

  def redact(nil, _metadata), do: nil

  def redact(data, metadata) when is_binary(data) and is_map(metadata) do
    module =
      Application.get_env(
        :casein,
        :terminal_command_redactor,
        Casein.Terminals.CommandRedactor.Default
      )

    module.redact(data, metadata)
  end
end
