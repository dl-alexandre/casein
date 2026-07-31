defmodule Casein.Access.Probe do
  @moduledoc """
  Liveness probe for a single `Casein.Access.Endpoint`.

  Follows the preview readiness convention: a short-timeout HTTP GET to
  `/healthz` with redirects disabled. Alive means the peer answered with a
  status that proves a server is present — 2xx, 3xx, 401, or 403.

  **Trap:** a 302 from a public endpoint without a bearer is alive, not dead.
  Caddy's `@bearer` bypass redirects unauthenticated browser traffic by
  design; reading that as failure has cost real debugging time before.
  """

  alias Casein.Access.Endpoint

  @default_timeout_ms 1_500
  @health_path "/healthz"

  @doc """
  True when the endpoint answers within the timeout with a live status.

  Accepts `%Endpoint{}` or a bare base URL string. Options:

  * `:timeout_ms` — connect + receive timeout (default 1500)
  * `:path` — probe path (default `/healthz`)
  """
  @spec reachable?(Endpoint.t() | String.t(), keyword()) :: boolean()
  def reachable?(target, opts \\ [])

  def reachable?(%Endpoint{base_url: base_url}, opts) when is_binary(base_url) do
    reachable?(base_url, opts)
  end

  def reachable?(base_url, opts) when is_binary(base_url) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    path = Keyword.get(opts, :path, @health_path)
    url = join_url(base_url, path)

    # Load-bearing, do not remove: `mix casein.doctor` calls this from a Mix
    # task where the app is not started, so Req's Finch pool does not exist yet
    # and `Req.get/2` dies in `Req.Finch.finch_name/1`. Idempotent and cheap
    # when the app is already running.
    _ = Application.ensure_all_started(:req)

    case Req.get(url,
           redirect: false,
           retry: false,
           connect_options: [timeout: timeout],
           receive_timeout: timeout,
           headers: [{"user-agent", "Casein-Access-Probe"}]
         ) do
      {:ok, %{status: status}} when is_integer(status) ->
        alive_status?(status)

      {:error, _reason} ->
        false
    end
  rescue
    # Narrow on purpose: a probe must not crash its caller, but it must not
    # swallow programmer error either. Only transport/protocol failures degrade
    # to "dead"; an ArgumentError from a bad option or a typo still raises.
    _ in [Req.TransportError, Req.HTTPError] -> false
  end

  def reachable?(_target, _opts), do: false

  defp alive_status?(status) when status in 200..399, do: true
  defp alive_status?(status) when status in [401, 403], do: true
  defp alive_status?(_status), do: false

  defp join_url(base_url, path) do
    base = String.trim_trailing(base_url, "/")
    path = if String.starts_with?(path, "/"), do: path, else: "/" <> path
    base <> path
  end
end
