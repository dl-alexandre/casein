defmodule Casein.Setup.LocalDomain do
  @moduledoc """
  Helpers for Casein's local hosts-file domain.

  `.local` is intentionally not the default here. On Linux desktops with
  `nss-mdns`, `.local` is mDNS-owned and may short-circuit before `/etc/hosts`.
  `devide.test` uses the RFC-reserved testing TLD and works predictably with a
  hosts-file entry.
  """

  @default_domain "devide.test"
  @begin_marker "# BEGIN Casein local domain"
  @end_marker "# END Casein local domain"

  def default_domain, do: System.get_env("CASEIN_LOCAL_DOMAIN") || @default_domain

  def short_hostname do
    case :inet.gethostname() do
      {:ok, hostname} ->
        hostname
        |> List.to_string()
        |> String.split(".")
        |> List.first()

      {:error, _} ->
        "localhost"
    end
  end

  def mdns_hostname do
    hostname = short_hostname()

    if String.ends_with?(hostname, ".local") do
      hostname
    else
      "#{hostname}.local"
    end
  end

  def default_ip do
    System.get_env("CASEIN_LAN_IP") || autodetect_lan_ip() || "127.0.0.1"
  end

  def resolve_ipv4(domain) when is_binary(domain) do
    domain
    |> String.to_charlist()
    |> :inet.gethostbyname(:inet)
    |> case do
      {:ok, {:hostent, _name, _aliases, :inet, 4, [addr | _]}} ->
        {:ok, addr |> :inet.ntoa() |> List.to_string()}

      {:ok, _} ->
        {:error, :no_ipv4}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def hosts_mapping(content, domain) when is_binary(content) and is_binary(domain) do
    content
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case parse_hosts_line(line) do
        {ip, names, _comment} ->
          if domain in names, do: ip

        nil ->
          nil
      end
    end)
  end

  def put_hosts_entry(content, domain, ip)
      when is_binary(content) and is_binary(domain) and is_binary(ip) do
    lines =
      content
      |> String.split("\n")
      |> remove_managed_block()
      |> Enum.map(&remove_domain_from_hosts_line(&1, domain))
      |> Enum.reject(&is_nil/1)
      |> trim_trailing_empty_lines()

    (lines ++ ["", @begin_marker, "#{ip} #{domain}", @end_marker])
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp autodetect_lan_ip do
    with {:ok, ifaddrs} <- :inet.getifaddrs() do
      ifaddrs
      |> Enum.flat_map(fn {_ifname, attrs} ->
        for {:addr, {a, b, _c, _d} = addr} <- attrs,
            a != 127,
            a != 0,
            {a, b} != {169, 254},
            do: addr
      end)
      |> Enum.sort_by(&private_score/1)
      |> List.first()
      |> case do
        nil -> nil
        addr -> addr |> :inet.ntoa() |> List.to_string()
      end
    end
  end

  defp private_score({192, 168, _, _}), do: 0
  defp private_score({10, _, _, _}), do: 1
  defp private_score({172, b, _, _}) when b in 16..31, do: 2
  defp private_score(_), do: 3

  defp remove_managed_block(lines), do: remove_managed_block(lines, false, [])

  defp remove_managed_block([], _skipping?, acc), do: Enum.reverse(acc)

  defp remove_managed_block([line | rest], false, acc) do
    if String.trim(line) == @begin_marker do
      remove_managed_block(rest, true, acc)
    else
      remove_managed_block(rest, false, [line | acc])
    end
  end

  defp remove_managed_block([line | rest], true, acc) do
    if String.trim(line) == @end_marker do
      remove_managed_block(rest, false, acc)
    else
      remove_managed_block(rest, true, acc)
    end
  end

  defp remove_domain_from_hosts_line(line, domain) do
    case parse_hosts_line(line) do
      {ip, names, comment} ->
        names = Enum.reject(names, &(&1 == domain))

        case names do
          [] -> nil
          _ -> format_hosts_line(ip, names, comment)
        end

      nil ->
        line
    end
  end

  defp parse_hosts_line(line) do
    {body, comment} =
      case String.split(line, "#", parts: 2) do
        [body, comment] -> {body, "#" <> comment}
        [body] -> {body, ""}
      end

    case String.split(body) do
      [ip | names] when names != [] -> {ip, names, comment}
      _ -> nil
    end
  end

  defp format_hosts_line(ip, names, ""), do: Enum.join([ip | names], " ")
  defp format_hosts_line(ip, names, comment), do: Enum.join([ip | names], " ") <> " " <> comment

  defp trim_trailing_empty_lines(lines) do
    lines
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
  end
end
