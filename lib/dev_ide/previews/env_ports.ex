defmodule DevIDE.Previews.EnvPorts do
  @moduledoc """
  Ephemeral preview-environment port helpers.

  Mirrors `scripts/preview-env.sh` defaults (`DEVIDE_PREVIEW_PORT_BASE` /
  `DEVIDE_PREVIEW_PORT_MAX`). Preview envs boot `MIX_ENV=dev mix phx.server` on
  an allocated port in this range, which is where the `:tidewave` dependency is
  available.
  """

  @default_min 41_000
  @default_max 41_099

  @doc "Configured inclusive `{min, max}` port range for preview environments."
  @spec port_range() :: {integer(), integer()}
  def port_range do
    case Application.get_env(:dev_ide, :preview_env_port_range, {@default_min, @default_max}) do
      {min, max} when is_integer(min) and is_integer(max) and min <= max -> {min, max}
      _ -> {@default_min, @default_max}
    end
  end

  @doc "True when `port` falls in the preview-env ephemeral range."
  @spec preview_env_port?(integer()) :: boolean()
  def preview_env_port?(port) when is_integer(port) do
    {min, max} = port_range()
    port >= min and port <= max
  end

  def preview_env_port?(_), do: false

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
end
