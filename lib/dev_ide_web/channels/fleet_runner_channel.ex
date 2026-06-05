defmodule DevIdeWeb.FleetRunnerChannel do
  @moduledoc """
  Phoenix Channel transport for controller ↔ runner protocol messages.

  This is transport only. All execution state changes still pass through
  `DevIDE.Fleet.Protocol.send_to_controller/1`.
  """

  use Phoenix.Channel

  alias DevIDE.Fleet
  alias DevIDE.Fleet.LongPollTransport
  alias DevIDE.Fleet.Protocol

  @protocol "devide.fleet.channel.v1"
  @version 1

  @impl true
  def join("runner:" <> runner_id, params, socket) do
    with :ok <- negotiate(params),
         {:ok, _runner} <- fetch_runner(runner_id) do
      socket = assign(socket, :runner_id, runner_id)

      {:ok,
       %{
         transport: @protocol,
         protocol_version: @version,
         runner_id: runner_id,
         resumable: true
       }, socket}
    else
      {:error, reason} -> {:error, %{reason: error_reason(reason)}}
    end
  end

  @impl true
  def handle_in("poll_offer", params, socket) do
    timeout_ms = int_param(params, "timeout_ms", 0)

    case LongPollTransport.poll_offer(socket.assigns.runner_id, timeout_ms: timeout_ms) do
      {:ok, offer} ->
        {:reply,
         {:ok,
          %{
            transport: @protocol,
            envelope: offer.envelope,
            lease: lease_payload(offer.lease),
            assignment: assignment_payload(offer.assignment)
          }}, socket}

      :none ->
        {:reply, {:ok, %{transport: @protocol, offer: nil}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  def handle_in("message", %{"envelope" => envelope}, socket) when is_map(envelope) do
    with {:ok, decoded} <- Protocol.deserialize(envelope),
         true <- decoded.runner_id == socket.assigns.runner_id || {:error, :runner_mismatch},
         {:ok, result} <- Protocol.send_to_controller(decoded) do
      {:reply, {:ok, %{transport: @protocol, result: result_payload(result)}}, socket}
    else
      {:error, reason} -> {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  def handle_in("heartbeat", _params, socket) do
    case Fleet.heartbeat(socket.assigns.runner_id) do
      {:ok, runner} -> {:reply, {:ok, %{runner: runner_payload(runner)}}, socket}
      :error -> {:reply, {:error, %{reason: "runner_not_found"}}, socket}
    end
  end

  def handle_in("resume", %{"assignment_id" => assignment_id}, socket) do
    executions = DevIDE.Fleet.ExecutionProjectionStore.for_assignment(assignment_id)

    if Enum.any?(executions, &(&1.runner_id == socket.assigns.runner_id)) do
      artifacts =
        executions
        |> Enum.flat_map(fn execution ->
          execution.id
          |> DevIDE.Fleet.ArtifactStore.chunks()
          |> Enum.map(&Map.put(&1, :execution_id, execution.id))
        end)

      {:reply,
       {:ok,
        %{
          assignment_id: assignment_id,
          executions: Enum.map(executions, &Map.from_struct/1),
          artifacts: artifacts
        }}, socket}
    else
      {:reply, {:error, %{reason: "resume_not_authorized"}}, socket}
    end
  end

  defp negotiate(params) do
    requested = int_param(params, "protocol_version", @version)

    if requested == @version do
      :ok
    else
      {:error, {:unsupported_protocol_version, requested, @version}}
    end
  end

  defp fetch_runner(runner_id) do
    with :ok <- runner_not_revoked(runner_id) do
      case Fleet.get_runner(runner_id) do
        {:ok, runner} -> {:ok, runner}
        :error -> {:error, :runner_not_found}
      end
    end
  end

  defp runner_not_revoked(runner_id) do
    case Fleet.runner_identity(runner_id) do
      {:ok, %{trust_state: :revoked}} -> {:error, :runner_revoked}
      _ -> :ok
    end
  end

  defp error_reason({:unsupported_protocol_version, requested, supported}) do
    "unsupported_protocol_version: requested #{requested}, supported #{supported}"
  end

  defp error_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp result_payload(%DevIDE.Assignments.Assignment{} = assignment),
    do: %{assignment: assignment_payload(assignment)}

  defp result_payload(:observational_accepted), do: %{accepted: true, kind: "observational"}
  defp result_payload(value) when is_atom(value), do: %{result: Atom.to_string(value)}
  defp result_payload(value), do: %{result: inspect(value)}

  defp runner_payload(runner) do
    %{
      id: runner.id,
      hostname: runner.hostname,
      state: runner.state,
      capabilities: runner.capabilities || [],
      active_assignment_id: runner.active_assignment_id
    }
  end

  defp lease_payload(lease) do
    %{
      id: lease.id,
      runner_id: lease.runner_id,
      assignment_id: lease.assignment_id,
      state: lease.state,
      acquired_at: lease.acquired_at,
      expires_at: lease.expires_at
    }
  end

  defp assignment_payload(assignment) do
    %{
      id: assignment.id,
      workspace_id: assignment.workspace_id,
      state: assignment.state,
      metadata: assignment.metadata || %{}
    }
  end

  defp int_param(map, key, fallback) do
    case Map.get(map, key) do
      value when is_integer(value) -> value
      value when is_binary(value) -> value |> Integer.parse() |> parse_int(fallback)
      _ -> fallback
    end
  end

  defp parse_int({value, ""}, _fallback), do: value
  defp parse_int(_other, fallback), do: fallback
end
