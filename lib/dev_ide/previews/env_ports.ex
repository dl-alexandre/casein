defmodule DevIDE.Previews.EnvPorts do
  @moduledoc """
  Preview infrastructure port helpers.

  Mirrors `scripts/preview-env.sh` defaults (`DEVIDE_PREVIEW_PORT_BASE` /
  `DEVIDE_PREVIEW_PORT_MAX`). Preview envs boot `MIX_ENV=dev mix phx.server` on
  an allocated port in this range, which is where the `:tidewave` dependency is
  available.

  The broader `41000..41099` block is intentionally partitioned:

    * `41000..41049` - ephemeral preview environments
    * `41050..41079` - runtime-owned preview servers
    * `41080` - preview router listener
    * `41081` - preview router admin listener

  Keeping these sub-bands disjoint prevents preview envs and runtime previews
  from squatting each other's stable URLs or exhausting the other's allocator.
  """

  @default_preview_env_min 41_000
  @default_preview_env_max 41_049
  @default_runtime_preview_min 41_050
  @default_runtime_preview_max 41_079
  @default_router_port 41_080
  @default_router_admin_port 41_081

  defguardp valid_port?(port) when is_integer(port) and port > 0 and port < 65_536

  @doc "Configured inclusive `{min, max}` port range for preview environments."
  @spec port_range() :: {integer(), integer()}
  def port_range do
    configured_range(
      :preview_env_port_range,
      {@default_preview_env_min, @default_preview_env_max}
    )
  end

  @doc "Configured inclusive `{min, max}` port range for runtime preview servers."
  @spec runtime_port_range() :: {integer(), integer()}
  def runtime_port_range do
    configured_range(
      :runtime_preview_port_range,
      {@default_runtime_preview_min, @default_runtime_preview_max}
    )
  end

  @doc "Default loopback listener for the preview router."
  @spec router_port() :: integer()
  def router_port do
    configured_port(:preview_router_port, @default_router_port)
  end

  @doc "Default Caddy admin listener for the preview router."
  @spec router_admin_port() :: integer()
  def router_admin_port do
    configured_port(:preview_router_admin_port, @default_router_admin_port)
  end

  @doc "True when `port` falls in the preview-env ephemeral range."
  @spec preview_env_port?(integer()) :: boolean()
  def preview_env_port?(port) when is_integer(port) do
    {min, max} = port_range()
    port >= min and port <= max
  end

  def preview_env_port?(_), do: false

  @doc "True when `port` falls in the runtime preview-server range."
  @spec runtime_preview_port?(integer()) :: boolean()
  def runtime_preview_port?(port) when is_integer(port) do
    {min, max} = runtime_port_range()
    port >= min and port <= max
  end

  def runtime_preview_port?(_), do: false

  @doc """
  Loopback port for the running DevIDE HTTP endpoint.

  Prefer `:preview_loopback_port` (set from `PORT` in `runtime.exs`), then
  parse `PORT` from the environment, then default to 4000.
  """
  @spec current_port() :: integer()
  def current_port do
    Application.get_env(:dev_ide, :preview_loopback_port) ||
      parse_port(System.get_env("PORT")) ||
      4_000
  end

  @doc "True when this BEAM instance is serving on a preview-env ephemeral port."
  @spec preview_env_instance?() :: boolean()
  def preview_env_instance?, do: preview_env_port?(current_port())

  defp parse_port(port) when is_binary(port) do
    case Integer.parse(port) do
      {value, ""} -> value
      _ -> nil
    end
  end

  defp parse_port(_), do: nil

  defp configured_range(key, default) do
    case Application.get_env(:dev_ide, key, default) do
      {min, max}
      when is_integer(min) and is_integer(max) and valid_port?(min) and
             valid_port?(max) and min <= max ->
        {min, max}

      _ ->
        default
    end
  end

  defp configured_port(key, default) do
    case Application.get_env(:dev_ide, key, default) do
      port when is_integer(port) and valid_port?(port) -> port
      _ -> default
    end
  end
end
