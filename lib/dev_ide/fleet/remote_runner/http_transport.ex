defmodule DevIDE.Fleet.RemoteRunner.HttpTransport do
  @moduledoc """
  Req-backed HTTP transport for standalone fleet runners.
  """

  @behaviour DevIDE.Fleet.RemoteRunner.Transport

  alias DevIDE.Fleet.Protocol
  alias FleetCtl.Protocol.Envelope

  @impl true
  def init(opts) do
    endpoint = opts |> Keyword.fetch!(:endpoint) |> String.trim_trailing("/")

    {:ok,
     %{
       endpoint: endpoint,
       token: Keyword.fetch!(opts, :token),
       runner_id: Keyword.get(opts, :runner_id) || Ecto.UUID.generate(),
       hostname: Keyword.get(opts, :hostname) || hostname(),
       capabilities: Keyword.get(opts, :capabilities, ["workspace-command:v1"]),
       metadata: Keyword.get(opts, :metadata, %{}),
       protocol_versions: Keyword.get(opts, :protocol_versions, [1]),
       transports: ["http"]
     }}
  end

  @impl true
  def register(state) do
    body = %{
      id: state.runner_id,
      hostname: state.hostname,
      capabilities: state.capabilities,
      metadata: state.metadata,
      protocol_versions: state.protocol_versions,
      transports: state.transports
    }

    with {:ok, response} <- post(state, "/api/fleet/v1/runners/register", body),
         true <- response.status in [200, 201] || {:error, {:http_status, response.status}} do
      {:ok, Map.put(state, :runner, response.body["runner"])}
    end
  end

  @impl true
  def heartbeat(state) do
    path = "/api/fleet/v1/runners/#{state.runner_id}/heartbeat"

    with {:ok, response} <- post(state, path, %{}),
         true <- response.status == 200 || {:error, {:http_status, response.status}} do
      {:ok, Map.put(state, :runner, response.body["runner"])}
    end
  end

  @impl true
  def drain(state) do
    path = "/api/fleet/v1/runners/#{state.runner_id}/drain"

    with {:ok, response} <- post(state, path, %{}),
         true <- response.status == 200 || {:error, {:http_status, response.status}} do
      {:ok, Map.put(state, :identity, response.body["identity"])}
    end
  end

  @impl true
  def shutdown(state) do
    path = "/api/fleet/v1/runners/#{state.runner_id}/shutdown"

    with {:ok, response} <- post(state, path, %{}),
         true <- response.status == 200 || {:error, {:http_status, response.status}} do
      {:ok, Map.put(state, :runner, response.body["runner"])}
    end
  end

  @impl true
  def poll_offer(state, opts) do
    path = "/api/fleet/v1/runners/#{state.runner_id}/offers/poll"
    body = %{"timeout_ms" => Keyword.get(opts, :timeout_ms, 0)}

    case post(state, path, body) do
      {:ok, %{status: 204}} ->
        :none

      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_status, status, body}}

      {:error, _reason} = error ->
        error
    end
  end

  @impl true
  def send_envelope(state, %Envelope{} = envelope) do
    body = %{"envelope" => Protocol.serialize(envelope)}

    with {:ok, response} <- post(state, "/api/fleet/v1/messages", body),
         true <-
           response.status == 200 || {:error, {:http_status, response.status, response.body}} do
      {:ok, response.body}
    end
  end

  defp post(state, path, body) do
    Req.post(state.endpoint <> path,
      json: body,
      headers: [{"authorization", "Bearer " <> state.token}]
    )
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> List.to_string(name)
      _ -> "runner"
    end
  end
end
