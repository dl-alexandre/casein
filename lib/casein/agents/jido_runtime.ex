defmodule Casein.Agents.JidoRuntime do
  @moduledoc """
  Canonical runtime/provider profile for Casein-owned Jido work.

  `jido` is the headless runtime. Its default provider is OpenCode Zen with
  the `opencode/grok-4.6` model. `opencode` remains the pane-backed fallback;
  it is a provider/runtime choice, not a second headless worker engine.

  The profile is deliberately secret-free. Credentials are resolved only by
  the provider adapter at request time and never become part of a Workcell
  resource, worker identity, or receipt.
  """

  alias Casein.ProcessEnv

  @default_runtime "jido"
  @default_provider "opencode"
  @default_model "opencode/grok-4.6"
  @false_values ~w(0 false FALSE no NO off OFF)

  @type profile :: %{
          runtime: String.t(),
          runtime_name: String.t(),
          provider: String.t(),
          model: String.t(),
          api_model: String.t(),
          launcher: String.t() | nil,
          headless: boolean()
        }

  @spec profile(keyword() | map()) :: profile()
  def profile(opts \\ %{}) do
    opts = if is_list(opts), do: Map.new(opts), else: opts

    runtime = value(opts, :runtime) || configured(:jido_runtime, @default_runtime)
    provider = value(opts, :provider) || configured(:jido_default_provider, @default_provider)
    model = value(opts, :model) || configured(:jido_default_model, @default_model)

    with {:ok, runtime} <- normalize_runtime(runtime),
         {:ok, provider} <- normalize_provider(provider),
         {:ok, model} <- normalize_model(model) do
      %{
        runtime: runtime,
        runtime_name: runtime,
        provider: provider,
        model: model,
        api_model: api_model(provider, model),
        launcher: if(runtime == "opencode", do: "opencode", else: nil),
        headless: runtime == "jido"
      }
    else
      _ ->
        %{
          runtime: @default_runtime,
          runtime_name: @default_runtime,
          provider: @default_provider,
          model: @default_model,
          api_model: "grok-4.6",
          launcher: nil,
          headless: true
        }
    end
  end

  @doc "Normalize the only runtime identities understood by the launcher boundary."
  @spec normalize_runtime(term()) :: {:ok, String.t()} | {:error, :invalid_runtime}
  def normalize_runtime(value) when value in [:jido, "jido"], do: {:ok, "jido"}
  def normalize_runtime(value) when value in [:opencode, "opencode"], do: {:ok, "opencode"}
  def normalize_runtime(_value), do: {:error, :invalid_runtime}

  @doc "Normalize a provider name without accepting a model as a runtime."
  @spec normalize_provider(term()) :: {:ok, String.t()} | {:error, :invalid_provider}
  def normalize_provider(value) when is_atom(value), do: normalize_provider(Atom.to_string(value))

  def normalize_provider(value) when is_binary(value) do
    provider = String.trim(value) |> String.downcase()

    if provider in ["opencode"], do: {:ok, provider}, else: {:error, :invalid_provider}
  end

  def normalize_provider(_value), do: {:error, :invalid_provider}

  @doc "Normalize the provider-qualified model spelling used by both paths."
  @spec normalize_model(term()) :: {:ok, String.t()} | {:error, :invalid_model}
  def normalize_model(value) when is_binary(value) do
    model = String.trim(value)

    if model == "" or String.contains?(model, <<0>>) or String.contains?(model, "\n"),
      do: {:error, :invalid_model},
      else: {:ok, model}
  end

  def normalize_model(_value), do: {:error, :invalid_model}

  @doc "Whether the Casein-owned headless lane is globally enabled."
  @spec casein_enabled?() :: boolean()
  def casein_enabled? do
    case System.get_env("CASEIN_ENABLED") do
      value when is_binary(value) and value != "" -> value not in @false_values
      _ -> ProcessEnv.get(:casein, :casein_enabled, true) != false
    end
  end

  @doc "Return a launcher-facing profile without turning Jido into a shell runtime."
  @spec launcher_profile(term()) :: {:ok, map()} | {:error, :invalid_runtime}
  def launcher_profile(value) do
    with {:ok, runtime} <- normalize_runtime(value) do
      profile = profile(runtime: runtime)

      {:ok,
       %{
         runtime: runtime,
         provider: profile.provider,
         model: profile.model,
         headless: profile.headless,
         launcher: profile.launcher
       }}
    end
  end

  defp configured(key, default), do: ProcessEnv.get(:casein, key, default)

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp value(_map, _key), do: nil

  defp api_model(provider, model) do
    prefix = provider <> "/"

    if String.starts_with?(model, prefix),
      do: String.replace_prefix(model, prefix, ""),
      else: model
  end
end
