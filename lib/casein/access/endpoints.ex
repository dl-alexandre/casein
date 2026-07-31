defmodule Casein.Access.Endpoints do
  @moduledoc """
  Pure inventory of doors this installation advertises.

  Assembles candidates from existing configuration only — `Casein.Origin`,
  LAN env keys shared with `Casein.Setup.LanRuntime`, and the bound HTTP
  socket from `CaseinWeb.Endpoint`. No HTTP, no remote DNS, no `System.cmd`.

  Probing is `Casein.Access.Probe`; selection is out of scope here.
  """

  alias Casein.Access.Endpoint
  alias Casein.Origin

  @doc """
  Return advertised endpoints for this installation.

  Pure and cheap: safe for pairing-page render and reconnect decisions.
  Filters to `advertised?: true` and de-duplicates by `base_url`.
  """
  @spec advertised() :: [Endpoint.t()]
  def advertised do
    []
    |> maybe_prepend(loopback_endpoint())
    |> Kernel.++(lan_endpoints())
    |> maybe_prepend(public_https_endpoint())
    |> Enum.filter(& &1.advertised?)
    |> Enum.uniq_by(& &1.base_url)
  end

  @doc """
  Format doctor lines for endpoint + probe pairs.

  Each entry is `{%Endpoint{}, alive? :: boolean()}`.
  """
  @spec doctor_lines([{Endpoint.t(), boolean()}]) :: [String.t()]
  def doctor_lines(entries) when is_list(entries) do
    header = ["Access endpoints", ""]

    body =
      case entries do
        [] ->
          ["  WARN  access endpoints - none advertised"]

        list ->
          Enum.map(list, fn {endpoint, alive?} ->
            status = if alive?, do: "OK   ", else: "WARN "
            detail = "#{endpoint.base_url} scope=#{endpoint.scope} auth=#{endpoint.auth} #{liveness(alive?)}"
            "  #{status} #{endpoint.kind} - #{detail}"
          end)
      end

    header ++ body
  end

  defp liveness(true), do: "alive"
  defp liveness(false), do: "dead"

  defp maybe_prepend(list, nil), do: list
  defp maybe_prepend(list, item), do: [item | list]

  defp loopback_endpoint do
    {host, port} = bound_http_host_port()
    Endpoint.loopback("http://#{host}:#{port}", advertised?: true)
  end

  defp public_https_endpoint do
    case Origin.canonical_base_url() do
      url when is_binary(url) and url != "" ->
        Endpoint.public_https(url, advertised?: true)

      _ ->
        nil
    end
  end

  defp lan_endpoints do
    port = env_int("CASEIN_LAN_INSECURE_HTTP_PORT") || 80
    host = configured_string("CASEIN_LAN_HOST")
    ip = configured_string("CASEIN_LAN_IP")
    lan_mode? = truthy_env?("CASEIN_LAN") or truthy_env?("CASEIN_LAN_INSECURE_HTTP")

    # Pure config only — never call LanRuntime.status/1 (HTTP + systemctl).
    # Advertise when LAN mode is on or an explicit host/IP is configured.
    candidates =
      []
      |> maybe_add_host(host, port)
      |> maybe_add_host(ip, port)

    if candidates == [] and lan_mode? do
      # Fall back to mDNS short name only when LAN mode is explicitly enabled.
      # LocalDomain.mdns_hostname/0 is local gethostname — not network I/O.
      case safe_mdns_hostname() do
        nil -> []
        mdns -> [Endpoint.lan(url_for(mdns, port), advertised?: true)]
      end
    else
      Enum.map(candidates, fn url -> Endpoint.lan(url, advertised?: true) end)
    end
  end

  defp maybe_add_host(list, nil, _port), do: list
  defp maybe_add_host(list, "", _port), do: list

  defp maybe_add_host(list, host, port) do
    list ++ [url_for(host, port)]
  end

  defp url_for(host, 80), do: "http://#{host}"
  defp url_for(host, port), do: "http://#{host}:#{port}"

  defp safe_mdns_hostname do
    if Code.ensure_loaded?(Casein.Setup.LocalDomain) and
         function_exported?(Casein.Setup.LocalDomain, :mdns_hostname, 0) do
      Casein.Setup.LocalDomain.mdns_hostname()
    else
      nil
    end
  rescue
    _ -> nil
  end

  defp bound_http_host_port do
    http =
      Application.get_env(:casein, CaseinWeb.Endpoint, [])
      |> Keyword.get(:http, [])

    port =
      case Keyword.get(http, :port) do
        p when is_integer(p) and p > 0 -> p
        _ -> env_int("PORT") || 4000
      end

    host =
      case Keyword.get(http, :ip) do
        {127, 0, 0, 1} -> "127.0.0.1"
        :loopback -> "127.0.0.1"
        {:local, _sock} -> "127.0.0.1"
        {a, b, c, d} when is_integer(a) -> Enum.join([a, b, c, d], ".")
        _ -> "127.0.0.1"
      end

    {host, port}
  end

  defp configured_string(name) do
    case System.get_env(name) do
      nil -> nil
      value ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end
    end
  end

  defp truthy_env?(name) do
    System.get_env(name) in ~w(1 true TRUE yes YES on ON)
  end

  defp env_int(name) do
    case System.get_env(name) do
      nil -> nil
      value -> String.to_integer(value)
    end
  rescue
    ArgumentError -> nil
  end
end
