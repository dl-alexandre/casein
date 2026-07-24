defmodule Casein.Terminals.CommandRedactor.Default do
  @moduledoc false

  @behaviour Casein.Terminals.CommandRedactor

  @assignment ~r/((?:api[_-]?key|token|secret|password|passwd|authorization)\s*[:=]\s*)(["']?)[^\s"';&]+/i
  @bearer ~r/(Bearer\s+)[A-Za-z0-9._~+\/=-]{12,}/i

  @impl true
  def redact(data, _metadata) when is_binary(data) do
    data
    |> redact_assignment()
    |> redact_bearer()
  end

  defp redact_assignment(data), do: Regex.replace(@assignment, data, "\\1\\2[REDACTED]")
  defp redact_bearer(data), do: Regex.replace(@bearer, data, "\\1[REDACTED]")
end
