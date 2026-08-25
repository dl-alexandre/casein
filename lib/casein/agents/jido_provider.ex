defmodule Casein.Agents.JidoProvider do
  @moduledoc """
  Provider boundary for Casein-owned headless Jido workers.

  The configured adapter is called in-process. Provider credentials stay behind
  the adapter and must never be accepted from model-authored input, stored in
  application configuration, or included in provider errors.
  """

  @type error :: %{
          required(:error) => :provider_unavailable,
          required(:reason) => atom(),
          required(:retryable) => boolean(),
          required(:provider) => String.t(),
          required(:model) => String.t()
        }

  @callback generate(term(), keyword()) :: {:ok, term()} | {:error, error()}
  @callback configured?() :: boolean()
  @callback info() :: map()

  @spec generate(term(), keyword()) :: {:ok, term()} | {:error, error()}
  def generate(input, opts \\ []) when is_list(opts) do
    adapter().generate(input, opts)
  end

  @spec configured?() :: boolean()
  def configured?, do: adapter().configured?()

  @spec info() :: map()
  def info, do: adapter().info()

  defp adapter do
    Application.get_env(
      :casein,
      :jido_provider_adapter,
      Casein.Agents.JidoProvider.OpenCodeZen
    )
  end
end
