defmodule DevIDE.Readiness do
  @moduledoc """
  Product-level readiness independent of any deployment integration.

  A ready DevIDE process can serve requests and reach its configured database.
  Reverse proxies, Unix sockets, deploy drift, and poller state belong to
  `DevIDE.Deployment.Health`; portable installations do not need them.
  """

  @default_timeout 1_000

  @type status :: %{
          ok: boolean(),
          checks: %{database: :ready | :unavailable}
        }

  @doc "Returns the minimal readiness status used by `/healthz`."
  @spec status(keyword()) :: status()
  def status(opts \\ []) do
    query = Keyword.get(opts, :query, &query_database/0)

    try do
      case query.() do
        {:ok, _result} -> ready()
        _other -> unavailable()
      end
    rescue
      _error -> unavailable()
    catch
      :exit, _reason -> unavailable()
    end
  end

  defp query_database do
    timeout = Application.get_env(:dev_ide, :readiness_timeout_ms, @default_timeout)
    Ecto.Adapters.SQL.query(DevIde.Repo, "SELECT 1", [], timeout: timeout, log: false)
  end

  defp ready, do: %{ok: true, checks: %{database: :ready}}
  defp unavailable, do: %{ok: false, checks: %{database: :unavailable}}
end
