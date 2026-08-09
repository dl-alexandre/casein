defmodule Casein.Paths do
  @moduledoc """
  Portable filesystem anchors for Casein.

  Product code must not hard-code operator home directories. Resolve the
  home directory from the process environment (or a test override) so a
  fresh clone, container image, or desktop host works without MILC topology
  baked into defaults.
  """

  @doc """
  Resolve the current user's home directory.

  Order:

  1. `:casein, :home_dir` application env (tests / managed overlays)
  2. `$HOME`
  3. `$USERPROFILE` (Windows)
  4. `System.user_home/0`

  Returns `nil` when none is available.
  """
  @spec home() :: String.t() | nil
  def home do
    cond do
      present?(Application.get_env(:casein, :home_dir)) ->
        Application.get_env(:casein, :home_dir)

      present?(System.get_env("HOME")) ->
        System.get_env("HOME")

      present?(System.get_env("USERPROFILE")) ->
        System.get_env("USERPROFILE")

      true ->
        case System.user_home() do
          home when is_binary(home) and home != "" -> home
          _ -> nil
        end
    end
  end

  @doc """
  Like `home/0`, but raises when no home directory can be resolved.

  Portable container/desktop profiles always set `HOME` (the production image
  uses `/home/casein`). Failing closed here is preferable to inventing a
  host-specific path.
  """
  @spec home!() :: String.t()
  def home! do
    case home() do
      home when is_binary(home) ->
        home

      nil ->
        raise ArgumentError,
              "HOME or USERPROFILE is required; Casein does not default to a host-specific path"
    end
  end

  defp present?(value) when is_binary(value), do: value != ""
  defp present?(_), do: false
end
