defmodule Casein.Access.Endpoint do
  @moduledoc """
  A single door into this Casein installation.

  Endpoints are pure data: kind, base URL, auth mode, reachability scope, and
  whether the installation advertises the door. Selection and probing live
  elsewhere so inventory stays cheap enough for pairing-page render and
  reconnect decisions.
  """

  @enforce_keys [:kind, :base_url, :auth, :scope, :advertised?]
  defstruct [:kind, :base_url, :auth, :scope, :advertised?]

  @type kind :: :loopback | :lan | :public_https | :ssh_forward | :tailscale
  @type auth :: :session | :bearer | :device_link
  @type scope :: :any | :same_host | :same_tailnet | :same_lan

  @type t :: %__MODULE__{
          kind: kind(),
          base_url: String.t(),
          auth: auth(),
          scope: scope(),
          advertised?: boolean()
        }

  @kinds ~w(loopback lan public_https ssh_forward tailscale)a
  @auths ~w(session bearer device_link)a
  @scopes ~w(any same_host same_tailnet same_lan)a

  @doc """
  Build an endpoint from a keyword list or map.

  Raises `ArgumentError` on unknown keys or invalid enum values. `base_url` is
  trimmed and has a trailing slash stripped.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs) do
    attrs
    |> Map.new()
    |> new()
  end

  def new(attrs) when is_map(attrs) do
    kind = fetch_enum!(attrs, :kind, @kinds)
    auth = fetch_enum!(attrs, :auth, @auths)
    scope = fetch_enum!(attrs, :scope, @scopes)
    base_url = normalize_base_url!(fetch_required!(attrs, :base_url))
    advertised? = fetch_boolean!(attrs, :advertised?, true)

    %__MODULE__{
      kind: kind,
      base_url: base_url,
      auth: auth,
      scope: scope,
      advertised?: advertised?
    }
  end

  @doc "Loopback HTTP door (same host only)."
  @spec loopback(String.t(), keyword()) :: t()
  def loopback(base_url, opts \\ []) when is_binary(base_url) do
    new(
      kind: :loopback,
      base_url: base_url,
      auth: Keyword.get(opts, :auth, :session),
      scope: :same_host,
      advertised?: Keyword.get(opts, :advertised?, true)
    )
  end

  @doc "LAN door (same LAN only)."
  @spec lan(String.t(), keyword()) :: t()
  def lan(base_url, opts \\ []) when is_binary(base_url) do
    new(
      kind: :lan,
      base_url: base_url,
      auth: Keyword.get(opts, :auth, :session),
      scope: :same_lan,
      advertised?: Keyword.get(opts, :advertised?, true)
    )
  end

  @doc "Public HTTPS door (any network)."
  @spec public_https(String.t(), keyword()) :: t()
  def public_https(base_url, opts \\ []) when is_binary(base_url) do
    new(
      kind: :public_https,
      base_url: base_url,
      auth: Keyword.get(opts, :auth, :bearer),
      scope: :any,
      advertised?: Keyword.get(opts, :advertised?, true)
    )
  end

  @doc "SSH-forwarded loopback door (same host only)."
  @spec ssh_forward(String.t(), keyword()) :: t()
  def ssh_forward(base_url, opts \\ []) when is_binary(base_url) do
    new(
      kind: :ssh_forward,
      base_url: base_url,
      auth: Keyword.get(opts, :auth, :bearer),
      scope: :same_host,
      advertised?: Keyword.get(opts, :advertised?, true)
    )
  end

  @doc "Tailscale / MagicDNS door (same tailnet only)."
  @spec tailscale(String.t(), keyword()) :: t()
  def tailscale(base_url, opts \\ []) when is_binary(base_url) do
    new(
      kind: :tailscale,
      base_url: base_url,
      auth: Keyword.get(opts, :auth, :bearer),
      scope: :same_tailnet,
      advertised?: Keyword.get(opts, :advertised?, true)
    )
  end

  @doc """
  True when a client's locality is compatible with this endpoint's scope.

  Clients should call this *before* probing so a phone off the tailnet never
  tries a MagicDNS name, and a WAN client never tries a LAN IP.
  """
  @spec in_scope?(t(), map()) :: boolean()
  def in_scope?(%__MODULE__{scope: :any}, _client), do: true

  def in_scope?(%__MODULE__{scope: :same_host}, client),
    do: client_flag?(client, :same_host?)

  def in_scope?(%__MODULE__{scope: :same_lan}, client),
    do: client_flag?(client, :same_lan?)

  def in_scope?(%__MODULE__{scope: :same_tailnet}, client),
    do: client_flag?(client, :same_tailnet?)

  defp client_flag?(client, key) when is_map(client) do
    case Map.get(client, key) || Map.get(client, Atom.to_string(key)) do
      true -> true
      _ -> false
    end
  end

  defp fetch_required!(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} ->
        value

      :error ->
        case Map.fetch(attrs, Atom.to_string(key)) do
          {:ok, value} -> value
          :error -> raise ArgumentError, "Access.Endpoint requires #{inspect(key)}"
        end
    end
  end

  defp fetch_enum!(attrs, key, allowed) do
    value = fetch_required!(attrs, key)

    if value in allowed do
      value
    else
      raise ArgumentError,
            "Access.Endpoint #{key} must be one of #{inspect(allowed)}, got: #{inspect(value)}"
    end
  end

  defp fetch_boolean!(attrs, key, default) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_boolean(value) ->
        value

      {:ok, value} ->
        raise ArgumentError, "Access.Endpoint #{key} must be a boolean, got: #{inspect(value)}"

      :error ->
        case Map.fetch(attrs, Atom.to_string(key)) do
          {:ok, value} when is_boolean(value) ->
            value

          {:ok, value} ->
            raise ArgumentError,
                  "Access.Endpoint #{key} must be a boolean, got: #{inspect(value)}"

          :error ->
            default
        end
    end
  end

  defp normalize_base_url!(url) when is_binary(url) do
    trimmed = url |> String.trim() |> String.trim_trailing("/")

    if trimmed == "" do
      raise ArgumentError, "Access.Endpoint base_url must be a non-empty string"
    end

    case URI.parse(trimmed) do
      %URI{scheme: scheme, host: host}
      when is_binary(scheme) and scheme != "" and is_binary(host) and host != "" ->
        trimmed

      _ ->
        raise ArgumentError,
              "Access.Endpoint base_url must include scheme and host, got: #{inspect(url)}"
    end
  end

  defp normalize_base_url!(url) do
    raise ArgumentError, "Access.Endpoint base_url must be a string, got: #{inspect(url)}"
  end
end
