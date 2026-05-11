defmodule DevIDE.Workspaces.Isolation do
  @moduledoc """
  Public API for DB isolation detection + the configurable host pattern lists.

  Configure via:

      config :dev_ide,
        shared_db_patterns: ["stage.rds.amazonaws.com", "stage-db."],
        unsafe_db_patterns: ["prod-db.", ".prod.rds.amazonaws.com"]

  Patterns are case-insensitive substrings. The lists may also contain
  `~r/.../` regexes — those are matched with `Regex.match?/2`.
  """

  alias DevIDE.Workspaces.DbIsolation

  @spec detect(map() | nil, String.t() | nil) :: DbIsolation.t()
  def detect(workspace, root) when is_binary(root) do
    impl().detect(workspace || %{}, root)
  end

  def detect(_workspace, _root),
    do: %DbIsolation{
      isolation: :unknown,
      source: :none,
      detected_at: DateTime.utc_now()
    }

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

  defp impl,
    do:
      Application.get_env(
        :dev_ide,
        :isolation_probe,
        DevIDE.Workspaces.IsolationProbe.LocalAdapter
      )
end
