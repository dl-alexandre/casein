defmodule Casein.Workspaces.Isolation.Patterns do
  @moduledoc """
  Host-pattern matching for shared/unsafe DB isolation labels.

  Extracted so isolation probes can classify hosts without referencing
  `Casein.Workspaces.Isolation` (breaking the probe ↔ context cycle).
  """

  @spec shared?(String.t()) :: boolean()
  def shared?(host) when is_binary(host),
    do: matches_any?(host, Application.get_env(:dev_ide, :shared_db_patterns, []))

  @spec unsafe?(String.t()) :: boolean()
  def unsafe?(host) when is_binary(host),
    do: matches_any?(host, Application.get_env(:dev_ide, :unsafe_db_patterns, []))

  defp matches_any?(host, patterns) do
    h = String.downcase(host)
    Enum.any?(patterns, &match_one?(h, &1))
  end

  defp match_one?(host, %Regex{} = re), do: Regex.match?(re, host)
  defp match_one?(host, p) when is_binary(p), do: String.contains?(host, String.downcase(p))
  defp match_one?(_, _), do: false
end
