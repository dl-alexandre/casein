defmodule Casein.Mobile.TerminalPolicy do
  @moduledoc """
  Deployment and rollout admission for the elevated mobile terminal.

  Mobile terminal access is disabled by default and guarded by a kill switch
  that wins over every allowlist. Enabling the deployment flag alone is not
  sufficient: the authenticated user, durable device link, and workspace must
  each be explicitly allowlisted.

  This module grants no terminal capability. It is only the first policy gate;
  later phases must also validate the child grant and exact lifecycle identity.
  """

  @config_key :mobile_terminal

  @type context :: %{
          required(:user_id) => String.t(),
          required(:device_link_id) => String.t(),
          required(:workspace_id) => String.t()
        }

  @type denial_reason ::
          :kill_switch_active
          | :feature_disabled
          | :user_not_allowlisted
          | :device_not_allowlisted
          | :workspace_not_allowlisted
          | :invalid_context

  @spec authorize(context()) :: :ok | {:error, denial_reason()}
  def authorize(context) when is_map(context) do
    config = config()

    with :ok <- valid_context(context),
         false <- Keyword.get(config, :kill_switch, true) != false,
         true <- Keyword.get(config, :enabled, false) == true,
         true <- allowlisted?(config, :user_ids, context.user_id),
         true <- allowlisted?(config, :device_link_ids, context.device_link_id),
         true <- allowlisted?(config, :workspace_ids, context.workspace_id) do
      :ok
    else
      {:error, :invalid_context} -> {:error, :invalid_context}
      true -> {:error, :kill_switch_active}
      false -> denial_after_enabled_check(config, context)
    end
  end

  def authorize(_context), do: {:error, :invalid_context}

  @spec enabled_for?(context()) :: boolean()
  def enabled_for?(context), do: authorize(context) == :ok

  @spec kill_switch_active?() :: boolean()
  def kill_switch_active? do
    config()
    |> Keyword.get(:kill_switch, true)
    |> Kernel.!=(false)
  end

  defp denial_after_enabled_check(config, context) do
    cond do
      Keyword.get(config, :enabled, false) != true ->
        {:error, :feature_disabled}

      not allowlisted?(config, :user_ids, context.user_id) ->
        {:error, :user_not_allowlisted}

      not allowlisted?(config, :device_link_ids, context.device_link_id) ->
        {:error, :device_not_allowlisted}

      true ->
        {:error, :workspace_not_allowlisted}
    end
  end

  defp valid_context(%{
         user_id: user_id,
         device_link_id: device_link_id,
         workspace_id: workspace_id
       }) do
    if Enum.all?([user_id, device_link_id, workspace_id], &present_string?/1),
      do: :ok,
      else: {:error, :invalid_context}
  end

  defp valid_context(_context), do: {:error, :invalid_context}

  defp allowlisted?(config, key, value) do
    config
    |> Keyword.get(key, [])
    |> List.wrap()
    |> Enum.any?(&(&1 == value))
  end

  defp present_string?(value), do: is_binary(value) and value != ""

  defp config do
    case Application.get_env(:casein, @config_key, []) do
      value when is_list(value) -> value
      _malformed -> []
    end
  end
end
