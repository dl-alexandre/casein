defmodule CaseinWeb.WorkspaceLive.Show.AgentApprovalEvents do
  @moduledoc false

  import Phoenix.LiveView, only: [put_flash: 3]

  alias Casein.AgentSessions
  alias Casein.AgentSessions.Provider.PendingRequest
  alias Casein.Audit
  alias CaseinWeb.WorkspaceLive.Show.Context
  alias CaseinWeb.WorkspaceLive.Show.{CodexEvents, GrokPermissionEvents}

  def handle_event("agent_approval:respond", params, socket) do
    with {:ok, provider_id} <- provider_id(params["provider-id"]),
         {:ok, request} <- find_request(socket, provider_id, params["request-id"]),
         {:ok, decision} <- decision(request, params),
         result <-
           safe_respond(provider_id, request.session_ref, request.request_id, decision),
         :ok <- response_result(result),
         :ok <- record_decision(socket, request, decision) do
      {:noreply,
       socket
       |> refresh_approvals()
       |> put_flash(:info, "Agent approval response sent.")}
    else
      {:error, reason} when reason in [:not_found, :permission_not_found, :already_resolved] ->
        {:noreply,
         socket
         |> refresh_approvals()
         |> put_flash(:info, "That request was already resolved.")}

      {:error, :invalid_option} ->
        {:noreply,
         socket
         |> refresh_approvals()
         |> put_flash(:error, "The agent no longer offers that response.")}

      {:error, {:runtime_not_running, _runtime_id, _component}} ->
        {:noreply,
         socket
         |> refresh_approvals()
         |> put_flash(:error, "The owning agent runtime is unavailable; no reply was sent.")}

      {:error, :invalid_response} ->
        {:noreply, put_flash(socket, :error, "That approval response was invalid.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> refresh_approvals()
         |> put_flash(:error, "Could not resolve agent approval: #{inspect(reason)}")}
    end
  end

  defp provider_id(value) when is_binary(value) do
    case Enum.find(AgentSessions.provider_ids(), &(Atom.to_string(&1) == value)) do
      nil -> {:error, :invalid_response}
      provider_id -> {:ok, provider_id}
    end
  end

  defp provider_id(_value), do: {:error, :invalid_response}

  defp find_request(socket, provider_id, request_id) when is_binary(request_id) do
    request =
      socket
      |> pending_requests()
      |> Enum.find(fn request ->
        request.provider_id == provider_id and to_string(request.request_id) == request_id
      end)

    if request, do: {:ok, request}, else: {:error, :not_found}
  end

  defp find_request(_socket, _provider_id, _request_id), do: {:error, :invalid_response}

  defp pending_requests(socket) do
    (socket.assigns[:codex_pending_requests] || []) ++
      (socket.assigns[:grok_permission_requests] || [])
  end

  defp decision(%PendingRequest{} = request, %{
         "decision-kind" => "choice",
         "option-id" => option_id
       })
       when is_binary(option_id) and option_id != "" do
    if PendingRequest.option_list?(request) and Enum.any?(request.options, &(&1.id == option_id)) do
      {:ok, {:choice, option_id}}
    else
      {:error, :invalid_response}
    end
  end

  defp decision(%PendingRequest{} = request, %{"decision-kind" => "cancel"}) do
    if PendingRequest.option_list?(request) do
      {:ok, {:choice, :cancel}}
    else
      {:error, :invalid_response}
    end
  end

  defp decision(%PendingRequest{} = request, %{"decision-kind" => kind})
       when kind in ["accept", "decline"] do
    if PendingRequest.option_list?(request) do
      {:error, :invalid_response}
    else
      {:ok, {:decision, String.to_existing_atom(kind)}}
    end
  end

  defp decision(%PendingRequest{} = request, %{
         "decision-kind" => "execpolicy_amendment",
         "execpolicy-amendment" => amendment
       })
       when is_binary(amendment) do
    prefixes =
      amendment
      |> String.split(~r/\R/u, trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if not PendingRequest.option_list?(request) and prefixes != [] do
      {:ok, {:decision, {:accept_with_execpolicy_amendment, prefixes}}}
    else
      {:error, :invalid_response}
    end
  end

  defp decision(%PendingRequest{} = request, %{
         "decision-kind" => "network_policy_amendment",
         "network-policy-amendment" => amendment
       })
       when is_binary(amendment) do
    with false <- PendingRequest.option_list?(request),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(amendment) do
      {:ok, {:decision, {:apply_network_policy_amendment, decoded}}}
    else
      _other -> {:error, :invalid_response}
    end
  end

  defp decision(_request, _params), do: {:error, :invalid_response}

  defp safe_respond(provider_id, session_ref, request_id, decision) do
    AgentSessions.respond_to_request(provider_id, session_ref, request_id, decision)
  catch
    :exit, _reason -> {:error, :runtime_unavailable}
  end

  defp response_result(:ok), do: :ok
  defp response_result({:ok, _response}), do: :ok
  defp response_result({:error, reason}), do: {:error, reason}
  defp response_result(other), do: {:error, {:unexpected_response, other}}

  defp record_decision(socket, request, decision) do
    {outcome, option_id} = decision_audit_fields(decision)

    metadata = %{
      source: Atom.to_string(request.provider_id),
      provider_id: request.provider_id,
      request_id: to_string(request.request_id),
      outcome: outcome
    }

    metadata = if option_id, do: Map.put(metadata, :option_id, option_id), else: metadata

    Audit.emit!(%{
      action: "agent.permission_decided",
      workspace_id: socket.assigns.workspace.id,
      actor_id: Context.current_actor_id(socket),
      target_type: "agent_permission",
      target_ref: "#{request.provider_id}:#{request.request_id}",
      metadata: metadata
    })

    :ok
  end

  defp decision_audit_fields({:choice, :cancel}), do: {"cancelled", nil}
  defp decision_audit_fields({:choice, option_id}), do: {"selected", option_id}
  defp decision_audit_fields({:decision, :decline}), do: {"denied", nil}
  defp decision_audit_fields({:decision, _decision}), do: {"accepted", nil}

  defp refresh_approvals(socket) do
    socket
    |> CodexEvents.refresh()
    |> GrokPermissionEvents.refresh()
  end
end
