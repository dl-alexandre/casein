defmodule DevIdeWeb.API.AgentCapabilityController do
  @moduledoc "HTTP lifecycle for managed Grok capability bearers."

  use DevIdeWeb, :controller

  alias DevIDE.Agents.{AgentCapabilityTokens, GrokCapabilityPolicy}
  alias DevIDE.Audit

  @digest ~r/\A[0-9a-f]{64}\z/
  @leader_id ~r/\A[0-9a-f]{24}\z/

  def create_grok(conn, %{"id" => workspace_id} = params) do
    with :ok <- require_workspace_token(conn, workspace_id),
         {:ok, tmux_session} <- required_string(params, "tmux_session_id"),
         true <- GrokCapabilityPolicy.valid_tmux_session?(workspace_id, tmux_session),
         {:ok, pane_id} <- matching_string(params, "pane_id", ~r/\A%[0-9]+\z/),
         {:ok, leader_id} <- matching_string(params, "leader_id", @leader_id),
         {:ok, bundle_digest} <- matching_string(params, "bundle_digest", @digest),
         {:ok, checkout_digest} <- optional_matching_string(params, "checkout_digest", @digest),
         snapshot <- GrokCapabilityPolicy.snapshot(workspace_id),
         true <- GrokCapabilityPolicy.classified?(),
         {:ok, raw_token, record} <-
           AgentCapabilityTokens.create_for_grok(%{
             workspace_id: workspace_id,
             tmux_session_id: tmux_session,
             pane_id: pane_id,
             leader_id: leader_id,
             bundle_digest: bundle_digest,
             checkout_digest: checkout_digest,
             workspace_mode: snapshot.mode,
             allowed_tools: snapshot.allowed_tools
           }) do
      _ =
        Audit.emit(%{
          workspace_id: workspace_id,
          action: "agent.capability_issued",
          target_type: "grok_leader",
          target_ref: leader_id,
          decision: :allow,
          metadata: %{
            capability_id: record.id,
            expires_at: record.expires_at,
            mode: snapshot.mode,
            mode_source: snapshot.mode_source,
            policy_version: snapshot.policy_version,
            write_enabled: snapshot.write_enabled,
            bundle_digest: bundle_digest,
            tmux_session_id: tmux_session
          }
        })

      conn
      |> put_status(:created)
      |> json(%{
        token: raw_token,
        capability_id: record.id,
        expires_at: record.expires_at,
        workspace_id: workspace_id,
        tmux_session_id: tmux_session,
        pane_id: pane_id,
        leader_id: leader_id,
        bundle_digest: bundle_digest,
        workspace_mode: snapshot.mode,
        policy_version: snapshot.policy_version,
        allowed_tools: snapshot.allowed_tools
      })
    else
      false -> invalid(conn, "invalid_grok_capability_scope")
      {:error, :forbidden} -> forbidden(conn)
      {:error, %Ecto.Changeset{} = changeset} -> invalid(conn, changeset_errors(changeset))
      {:error, reason} when is_binary(reason) -> invalid(conn, reason)
      {:error, reason} -> invalid(conn, inspect(reason))
    end
  end

  def current(%{assigns: %{api_agent_capability: claims}} = conn, _params) do
    {:ok, effective_tools, policy} = GrokCapabilityPolicy.effective_tools(claims)

    json(conn, %{
      capability_id: claims.id,
      workspace_id: claims.workspace_id,
      runtime: claims.runtime,
      tmux_session_id: claims.tmux_session_id,
      pane_id: claims.pane_id,
      leader_id: claims.leader_id,
      bundle_digest: claims.bundle_digest,
      checkout_digest: claims.checkout_digest,
      expires_at: claims.expires_at,
      effective_tools: effective_tools,
      current_workspace_mode: policy.mode,
      write_enabled: policy.write_enabled
    })
  end

  def current(conn, _params), do: forbidden(conn)

  def revoke_current(%{assigns: %{api_agent_capability: claims}} = conn, _params) do
    case AgentCapabilityTokens.revoke_current(claims.id) do
      {:ok, _record} ->
        _ =
          Audit.emit(%{
            workspace_id: claims.workspace_id,
            action: "agent.capability_revoked",
            target_type: "grok_leader",
            target_ref: claims.leader_id,
            decision: :allow,
            metadata: %{capability_id: claims.id, tmux_session_id: claims.tmux_session_id}
          })

        send_resp(conn, :no_content, "")

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "capability_not_found"})
    end
  end

  def revoke_current(conn, _params), do: forbidden(conn)

  defp require_workspace_token(conn, workspace_id) do
    if conn.assigns[:api_token_scope] == {:workspace, workspace_id},
      do: :ok,
      else: {:error, :forbidden}
  end

  defp required_string(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, "#{key}_required"}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, "#{key}_required"}
    end
  end

  defp matching_string(params, key, regex) do
    with {:ok, value} <- required_string(params, key),
         true <- Regex.match?(regex, value) do
      {:ok, value}
    else
      false -> {:error, "invalid_#{key}"}
      error -> error
    end
  end

  defp optional_matching_string(params, key, regex) do
    case Map.get(params, key) do
      nil ->
        {:ok, nil}

      "" ->
        {:ok, nil}

      value when is_binary(value) ->
        value = String.trim(value)
        if Regex.match?(regex, value), do: {:ok, value}, else: {:error, "invalid_#{key}"}

      _ ->
        {:error, "invalid_#{key}"}
    end
  end

  defp forbidden(conn) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "workspace_capability_issuer_required"})
  end

  defp invalid(conn, detail) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "invalid_grok_capability", detail: detail})
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end
end
