defmodule DevideMob.SessionConfig do
  @moduledoc """
  Device-local settings for the session companion: the host pairing
  (`{url, token}`), the set of pinned workspace ids the dashboard watches, and
  the last workspace/session context the dashboard can offer to resume.

  Backed by `Mob.State` so it survives screen navigation. The pairing is
  provisioned by QR scan (web cockpit → camera bridge) or manual entry; see
  `DevideMob.SessionClient`. A `config :devide_mob, :session` block can seed a
  dev default so the app connects without pairing on the emulator.

  Simulator/dev launches may also pass `DEVIDE_MOB_DEV_PAIRING_URL` and
  `DEVIDE_MOB_DEV_PAIRING_TOKEN` (plus optional
  `DEVIDE_MOB_DEV_PINNED_WORKSPACES`, comma-separated) as runtime environment
  overrides. This is deliberately prefixed as a dev hook; real pairing state
  still comes from QR/manual pairing.
  """

  @pairing_key :session_pairing
  @pinned_key :session_pinned_workspaces
  @resume_key :session_resume_context

  @doc "Returns `{:ok, url, token}` if a pairing exists, else `:error`."
  @spec pairing() :: {:ok, String.t(), String.t()} | :error
  def pairing do
    case runtime_default_pairing() || Mob.State.get(@pairing_key, config_default_pairing()) do
      %{url: url, token: token} when is_binary(url) and is_binary(token) -> {:ok, url, token}
      _ -> :error
    end
  end

  @spec put_pairing(String.t(), String.t()) :: :ok
  def put_pairing(url, token) when is_binary(url) and is_binary(token) do
    Mob.State.put(@pairing_key, %{url: url, token: token})
    :ok
  end

  @spec clear_pairing() :: :ok
  def clear_pairing do
    Mob.State.put(@pairing_key, nil)
    :ok
  end

  @doc "Clear all session companion state stored on this device."
  @spec clear_all() :: :ok
  def clear_all do
    clear_pairing()
    Mob.State.put(@pinned_key, [])
    clear_resume_context()
    :ok
  end

  @doc "Workspace ids pinned to the dashboard."
  @spec pinned_workspaces() :: [String.t()]
  def pinned_workspaces do
    runtime_default_pinned() || Mob.State.get(@pinned_key, config_default_pinned())
  end

  @spec pin_workspace(String.t()) :: :ok
  def pin_workspace(workspace_id) when is_binary(workspace_id) do
    pinned = pinned_workspaces()
    unless workspace_id in pinned, do: Mob.State.put(@pinned_key, pinned ++ [workspace_id])
    :ok
  end

  @spec pinned?(String.t()) :: boolean()
  def pinned?(workspace_id) when is_binary(workspace_id) do
    workspace_id in pinned_workspaces()
  end

  @spec unpin_workspace(String.t()) :: :ok
  def unpin_workspace(workspace_id) when is_binary(workspace_id) do
    Mob.State.put(@pinned_key, pinned_workspaces() -- [workspace_id])
    clear_resume_context(workspace_id)
    :ok
  end

  @doc "Last workspace/session context the dashboard can offer to resume."
  @spec resume_context() :: map() | nil
  def resume_context do
    case Mob.State.get(@resume_key, nil) do
      %{workspace_id: workspace_id} = context
      when is_binary(workspace_id) and workspace_id != "" ->
        context

      %{"workspace_id" => workspace_id} = context
      when is_binary(workspace_id) and workspace_id != "" ->
        Map.new(context, fn {key, value} -> {normalize_key(key), value} end)

      _ ->
        nil
    end
  end

  @spec put_resume_context(String.t(), keyword()) :: :ok
  def put_resume_context(workspace_id, opts \\ []) when is_binary(workspace_id) do
    if String.trim(workspace_id) == "" do
      :ok
    else
      context =
        %{
          workspace_id: workspace_id,
          session_id: Keyword.get(opts, :session_id),
          source: Keyword.get(opts, :source, :workspace)
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
        |> Map.new()

      Mob.State.put(@resume_key, context)
      :ok
    end
  end

  @spec clear_resume_context() :: :ok
  def clear_resume_context do
    Mob.State.put(@resume_key, nil)
    :ok
  end

  @spec clear_resume_context(String.t()) :: :ok
  def clear_resume_context(workspace_id) when is_binary(workspace_id) do
    case resume_context() do
      %{workspace_id: ^workspace_id} -> clear_resume_context()
      _ -> :ok
    end
  end

  def clear_resume_context(_workspace_id) do
    :ok
  end

  defp config_default_pairing do
    case Application.get_env(:devide_mob, :session, [])[:pairing] do
      %{url: url, token: token} when is_binary(url) and is_binary(token) ->
        %{url: url, token: token}

      _ ->
        nil
    end
  end

  defp config_default_pinned do
    Application.get_env(:devide_mob, :session, [])[:pinned_workspaces] || []
  end

  defp runtime_default_pairing do
    with url when is_binary(url) <- present_env("DEVIDE_MOB_DEV_PAIRING_URL"),
         token when is_binary(token) <- present_env("DEVIDE_MOB_DEV_PAIRING_TOKEN") do
      %{url: url, token: token}
    else
      _ -> nil
    end
  end

  defp runtime_default_pinned do
    case present_env("DEVIDE_MOB_DEV_PINNED_WORKSPACES") do
      nil ->
        nil

      value ->
        value
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end

  defp present_env(name) do
    case System.get_env(name) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  defp normalize_key("workspace_id"), do: :workspace_id
  defp normalize_key("session_id"), do: :session_id
  defp normalize_key("source"), do: :source
  defp normalize_key(key), do: key
end
