defmodule DevIdeWeb.API.FleetRunnerController do
  use DevIdeWeb, :controller

  alias DevIDE.Assignments.Assignment
  alias DevIDE.Fleet
  alias DevIDE.Fleet.Lease
  alias DevIDE.Fleet.LongPollTransport
  alias DevIDE.Fleet.Protocol
  alias DevIDE.Fleet.Runner

  def register(conn, params) do
    with {:ok, attrs} <- runner_attrs(params) do
      case Fleet.register(attrs) do
        {:ok, %Runner{} = runner} ->
          conn
          |> put_status(:created)
          |> json(%{transport: LongPollTransport.protocol(), runner: runner_payload(runner)})

        {:error, :duplicate_id} ->
          rejected(conn, :conflict, :duplicate_runner)

        {:error, :runner_revoked} ->
          rejected(conn, :forbidden, :runner_revoked)
      end
    else
      {:error, reason} -> rejected(conn, :bad_request, reason)
    end
  end

  def heartbeat(conn, %{"runner_id" => runner_id}) do
    case Fleet.heartbeat(runner_id) do
      {:ok, %Runner{} = runner} ->
        json(conn, %{transport: LongPollTransport.protocol(), runner: runner_payload(runner)})

      {:error, :runner_revoked} ->
        rejected(conn, :forbidden, :runner_revoked)

      :error ->
        not_found(conn)
    end
  end

  def drain(conn, %{"runner_id" => runner_id}) do
    case Fleet.drain_runner(runner_id, actor_id: "runner") do
      {:ok, identity} ->
        json(conn, %{
          transport: LongPollTransport.protocol(),
          identity: identity_payload(identity)
        })

      :error ->
        not_found(conn)
    end
  end

  def shutdown(conn, %{"runner_id" => runner_id}) do
    case Fleet.shutdown_runner(runner_id, actor_id: "runner") do
      {:ok, %Runner{} = runner} ->
        json(conn, %{transport: LongPollTransport.protocol(), runner: runner_payload(runner)})

      :error ->
        not_found(conn)
    end
  end

  def poll_offer(conn, %{"runner_id" => runner_id} = params) do
    case Fleet.poll_transport_offer(runner_id, timeout_ms: int_param(params, "timeout_ms", 0)) do
      {:ok, offer} ->
        json(conn, %{
          transport: LongPollTransport.protocol(),
          envelope: offer.envelope,
          lease: lease_payload(offer.lease),
          assignment: assignment_payload(offer.assignment)
        })

      :none ->
        send_resp(conn, :no_content, "")

      {:error, :runner_not_found} ->
        not_found(conn)

      {:error, :runner_revoked} ->
        rejected(conn, :forbidden, :runner_revoked)

      {:error, reason} ->
        rejected(conn, :unprocessable_entity, reason)
    end
  end

  def message(conn, %{"envelope" => envelope}) when is_map(envelope) do
    with {:ok, decoded} <- Protocol.deserialize(envelope),
         {:ok, result} <- Protocol.send_to_controller(decoded) do
      json(conn, %{
        transport: LongPollTransport.protocol(),
        result: result_payload(result)
      })
    else
      {:error, reason} -> rejected(conn, :bad_request, reason)
    end
  end

  def message(conn, _params), do: rejected(conn, :bad_request, :envelope_required)

  defp runner_attrs(params) do
    hostname = string_param(params, "hostname")

    if hostname in [nil, ""] do
      {:error, :hostname_required}
    else
      {:ok,
       %{
         id: string_param(params, "id") || string_param(params, "runner_id"),
         hostname: hostname,
         capabilities: string_list_param(params, "capabilities"),
         protocol_versions: int_list_param(params, "protocol_versions"),
         transports: string_list_param(params, "transports"),
         metadata: map_param(params, "metadata")
       }
       |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
       |> Map.new()}
    end
  end

  defp result_payload(%Assignment{} = assignment) do
    %{assignment: assignment_payload(assignment)}
  end

  defp result_payload(:observational_accepted), do: %{accepted: true, kind: "observational"}
  defp result_payload(value) when is_atom(value), do: %{result: Atom.to_string(value)}
  defp result_payload(value) when is_binary(value), do: %{result: value}
  defp result_payload(value), do: %{result: inspect(value)}

  defp runner_payload(%Runner{} = runner) do
    %{
      id: runner.id,
      hostname: runner.hostname,
      state: runner.state,
      capabilities: runner.capabilities || [],
      active_assignment_id: runner.active_assignment_id,
      registered_at: runner.registered_at,
      last_heartbeat_at: runner.last_heartbeat_at,
      metadata: runner.metadata || %{}
    }
  end

  defp identity_payload(identity) do
    %{
      id: identity.id,
      hostname: identity.hostname,
      trust_state: identity.trust_state,
      capabilities: identity.capabilities || [],
      manifest: identity.manifest || %{},
      updated_at: identity.updated_at,
      revoked_at: identity.revoked_at
    }
  end

  defp lease_payload(%Lease{} = lease) do
    %{
      id: lease.id,
      runner_id: lease.runner_id,
      assignment_id: lease.assignment_id,
      state: lease.state,
      acquired_at: lease.acquired_at,
      expires_at: lease.expires_at,
      released_at: lease.released_at
    }
  end

  defp assignment_payload(%Assignment{} = assignment) do
    %{
      id: assignment.id,
      workspace_id: assignment.workspace_id,
      run_id: assignment.run_id,
      state: assignment.state,
      lease_owner: assignment.lease_owner,
      lease_expires_at: assignment.lease_expires_at,
      completed_at: assignment.completed_at,
      failure_reason: assignment.failure_reason,
      metadata: assignment.metadata || %{}
    }
  end

  defp string_param(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> String.trim(value)
      _ -> nil
    end
  end

  defp string_list_param(map, key) do
    case Map.get(map, key) do
      values when is_list(values) ->
        values
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  defp int_list_param(map, key) do
    case Map.get(map, key) do
      values when is_list(values) ->
        values
        |> Enum.map(&int_value/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp int_value(value) when is_integer(value), do: value

  defp int_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp int_value(_value), do: nil

  defp map_param(map, key) do
    case Map.get(map, key) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp int_param(map, key, fallback) do
    case Map.get(map, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, ""} -> int
          _ -> fallback
        end

      _ ->
        fallback
    end
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "not_found"})
  end

  defp rejected(conn, status, reason) do
    conn
    |> put_status(status)
    |> json(%{error: to_string(reason)})
  end
end
