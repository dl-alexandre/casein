defmodule CaseinWeb.OriginOptions do
  @moduledoc false

  @localhost_hosts ["localhost", "127.0.0.1"]

  def on_devbox(host) when is_binary(host) do
    ["https://#{host}", "//localhost", "//127.0.0.1"]
  end

  def desktop(port) when is_integer(port) and port in 1024..65_535 do
    Enum.map(@localhost_hosts, &origin("http", &1, port))
  end

  def desktop_lan(port, host, lan_ips)
      when is_integer(port) and port in 1024..65_535 and is_binary(host) do
    lan(host, scheme: "http", port: port, lan_ips: List.wrap(lan_ips))
  end

  def lan(host, opts \\ []) when is_binary(host) do
    scheme = Keyword.get(opts, :scheme, "http")
    port = Keyword.get(opts, :port, default_port(scheme))
    lan_ip = Keyword.get(opts, :lan_ip)
    lan_ips = Keyword.get(opts, :lan_ips, [])

    [host, lan_ip | List.wrap(lan_ips) ++ @localhost_hosts]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.uniq()
    |> Enum.map(&origin(scheme, &1, port))
  end

  defp origin(scheme, host, port) when port in [80, "80"] and scheme == "http" do
    "http://#{host}"
  end

  defp origin(scheme, host, port) when port in [443, "443"] and scheme == "https" do
    "https://#{host}"
  end

  defp origin(scheme, host, port), do: "#{scheme}://#{host}:#{port}"

  defp default_port("https"), do: 443
  defp default_port(_scheme), do: 80
end
