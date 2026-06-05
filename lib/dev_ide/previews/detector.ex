defmodule DevIDE.Previews.Detector do
  @moduledoc """
  Detects browser-preview candidates from terminal output.

  Dev servers tend to print either full localhost URLs or short host:port
  hints. This module keeps the parsing server-side so the preview broker can
  associate candidates with the pane/session that produced them.
  """

  @url_regex ~r/https?:\/\/(?:localhost|127\.0\.0\.1|0\.0\.0\.0):\d{2,5}(?:\/[^\s\)\]"'<>]*)?/i
  @host_port_regex ~r/(?:localhost|127\.0\.0\.1|0\.0\.0\.0):(\d{2,5})/i
  @ansi_regex ~r/\e\[[0-?]*[ -\/]*[@-~]/

  @doc "Returns normalized localhost preview candidates from a PTY chunk."
  def discover(data) when is_binary(data) do
    text = strip_ansi(data)
    urls = urls_from_text(text)
    full_url_ports = urls |> Enum.map(& &1.port) |> MapSet.new()

    (urls ++ host_ports_from_text(text, full_url_ports))
    |> Enum.uniq_by(& &1.url)
    |> Enum.filter(&valid_port?/1)
    |> Enum.take(8)
  end

  def discover(_), do: []

  defp urls_from_text(text) do
    @url_regex
    |> Regex.scan(text)
    |> Enum.map(fn [url | _] -> normalize_url(url) end)
    |> Enum.reject(&is_nil/1)
  end

  defp host_ports_from_text(text, full_url_ports) do
    @host_port_regex
    |> Regex.scan(text)
    |> Enum.reject(fn [_match, port] ->
      MapSet.member?(full_url_ports, String.to_integer(port))
    end)
    |> Enum.map(fn [_match, port] -> candidate("http://localhost:#{port}") end)
  end

  defp strip_ansi(text), do: Regex.replace(@ansi_regex, text, "")

  defp normalize_url(url) do
    url
    |> String.trim_trailing(".")
    |> DevIDE.Previews.Url.normalize_localhost()
    |> candidate()
  end

  defp candidate(url) do
    uri = URI.parse(url)

    if uri.scheme in ["http", "https"] and uri.host in ["localhost", "127.0.0.1", "0.0.0.0"] do
      port = uri.port || default_port(uri.scheme)
      path = uri.path || ""
      query = if uri.query, do: "?#{uri.query}", else: ""

      %{
        url: "#{uri.scheme}://localhost:#{port}#{path}#{query}",
        port: port,
        title: "localhost:#{port}"
      }
    end
  end

  defp default_port("https"), do: 443
  defp default_port(_), do: 80

  defp valid_port?(%{port: port}) when is_integer(port), do: port > 0 and port < 65_536
  defp valid_port?(_), do: false
end
