defmodule Casein.Agents.JidoProvider.OpenCodeZen do
  @moduledoc """
  Jido.AI adapter for Grok 4.6 through OpenCode Zen.

  The model and endpoint are fixed at the trusted adapter boundary. The existing
  OpenCode credential is resolved immediately before each request and passed to
  Jido.AI/ReqLLM only as a per-request option.
  """

  @behaviour Casein.Agents.JidoProvider

  alias Casein.Agents.JidoProvider.OpenCodeAuth

  @provider "opencode"
  @model "opencode/grok-4.6"
  @api_model "grok-4.6"
  @base_url "https://opencode.ai/zen/v1"
  @generation_options [
    :max_tokens,
    :parallel_tool_calls,
    :reasoning_effort,
    :system_prompt,
    :temperature,
    :timeout,
    :tool_choice,
    :tools
  ]

  @model_spec %{
    provider: :openai,
    id: @api_model,
    provider_model_id: @api_model,
    base_url: @base_url,
    extra: %{wire: %{protocol: "openai_responses"}}
  }

  @impl true
  def generate(input, opts \\ []) when is_list(opts) do
    with {:ok, api_key} <- fetch_api_key() do
      call_client(input, generation_opts(opts, api_key))
    else
      {:error, reason} -> provider_error(reason, false)
    end
  end

  @impl true
  def configured? do
    match?({:ok, _api_key}, fetch_api_key())
  end

  @impl true
  def info do
    %{
      provider: @provider,
      model: @model,
      api_model: @api_model,
      base_url: @base_url,
      wire_protocol: :openai_responses,
      credential_source: :opencode_runtime
    }
  end

  @doc "Returns the secret-free ReqLLM model specification used for Zen."
  @spec model_spec() :: map()
  def model_spec, do: @model_spec

  defp fetch_api_key do
    resolver = Application.get_env(:casein, :jido_auth_resolver, OpenCodeAuth)

    if Code.ensure_loaded?(resolver) and function_exported?(resolver, :fetch_api_key, 0) do
      case resolver.fetch_api_key() do
        {:ok, api_key} when is_binary(api_key) and byte_size(api_key) > 0 ->
          {:ok, api_key}

        {:error, reason}
        when reason in [
               :credential_not_found,
               :credential_invalid,
               :credential_type_unsupported,
               :credential_source_unavailable,
               :credential_unreadable
             ] ->
          {:error, reason}

        _other ->
          {:error, :credential_unreadable}
      end
    else
      {:error, :credential_source_unavailable}
    end
  rescue
    _exception -> {:error, :credential_unreadable}
  catch
    _kind, _reason -> {:error, :credential_unreadable}
  end

  defp generation_opts(opts, api_key) do
    opts
    |> Keyword.take(@generation_options)
    |> Keyword.put(:model, @model_spec)
    |> Keyword.put(:api_key, api_key)
  end

  defp call_client(input, opts) do
    client = Application.get_env(:casein, :jido_ai_client, Jido.AI)

    if Code.ensure_loaded?(client) and function_exported?(client, :generate_text, 2) do
      case client.generate_text(input, opts) do
        {:ok, response} -> {:ok, response}
        {:error, _reason} -> provider_error(:request_failed, true)
        _other -> provider_error(:invalid_provider_response, false)
      end
    else
      provider_error(:client_unavailable, false)
    end
  rescue
    _exception -> provider_error(:request_failed, true)
  catch
    _kind, _reason -> provider_error(:request_failed, true)
  end

  defp provider_error(reason, retryable?) do
    {:error,
     %{
       error: :provider_unavailable,
       reason: reason,
       retryable: retryable?,
       provider: @provider,
       model: @model
     }}
  end
end
