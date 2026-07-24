defmodule Casein.Previews.Identity do
  @moduledoc false

  alias Casein.Previews.{Surface, Url}

  @doc "Stable key for deduplicating workspace previews."
  def surface_key(%Surface{name: name, url: url}) do
    cond do
      is_binary(name) and String.trim(name) != "" -> normalize_name(name)
      true -> url_key(url)
    end
  end

  def surface_key(name) when is_atom(name), do: name |> Atom.to_string() |> normalize_name()
  def surface_key(name) when is_binary(name), do: normalize_name(name)
  def surface_key(_), do: nil

  @doc "Stable key for a raw URL. Paths and query strings are intentionally ignored."
  def url_key(url) when is_binary(url) do
    url = Url.normalize_localhost(url)

    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) ->
        port = uri.port || default_port(scheme)
        host = String.downcase(host)

        if host in ["localhost", "127.0.0.1", "0.0.0.0"] do
          if scheme == "http", do: "localhost:#{port}", else: "https://localhost:#{port}"
        else
          "origin:#{scheme}://#{host}:#{port}"
        end

      _ ->
        nil
    end
  end

  def url_key(_), do: nil

  @doc "Derive a key from preview open attrs."
  def attrs_key(attrs) when is_map(attrs) do
    metadata = Map.get(attrs, :metadata) || Map.get(attrs, "metadata") || %{}

    metadata_value(metadata, :surface_key) ||
      metadata_value(metadata, :surface) ||
      url_key(Map.get(attrs, :url) || Map.get(attrs, "url"))
  end

  def attrs_key(_), do: nil

  @doc """
  Returns the caller-provided metadata `surface_key`, or nil.

  Distinguishes a deliberate identity (set by pane-bound previews) from a key
  derived from a generic surface label or URL, so dedup can match strictly.
  """
  def explicit_surface_key(attrs) when is_map(attrs) do
    metadata = Map.get(attrs, :metadata) || Map.get(attrs, "metadata") || %{}
    metadata_value(metadata, :surface_key)
  end

  def explicit_surface_key(_), do: nil

  defp normalize_name(name) do
    name
    |> String.trim()
    |> String.downcase()
  end

  defp metadata_value(metadata, key) when is_map(metadata) and is_atom(key) do
    case Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key)) do
      value when is_binary(value) and value != "" -> normalize_name(value)
      _ -> nil
    end
  end

  defp metadata_value(_, _), do: nil

  defp default_port("https"), do: 443
  defp default_port(_), do: 80
end
