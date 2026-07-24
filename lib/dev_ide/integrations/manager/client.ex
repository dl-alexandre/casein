defmodule Casein.Integrations.Manager.Client do
  @moduledoc """
  Thin HTTP client for the milc-devbox Node manager API.

  Source of truth lives in `milc-devbox/manager`. We do not duplicate state.
  Configure base URL via `:casein, :manager_url` or env `MILC_DEVBOX_MANAGER_URL`.

  Errors are returned as typed tuples:
    {:error, {:http, status, body}}
    {:error, {:transport, reason}}     # connection refused, timeout, ...
    {:error, {:unexpected, term}}
  """

  require Logger

  alias Casein.Integrations.Manager.Workspace

  @type error ::
          {:http, pos_integer(), term()}
          | {:transport, term()}
          | {:unexpected, term()}

  @typedoc """
  Forward-auth identity to attribute the request to. An email string is sent
  as `X-Auth-Request-Email` (the manager derives the user from it); `nil`
  falls back to the static `:manager_user_email` config.
  """
  @type auth :: String.t() | nil

  @spec list(keyword(), auth()) :: {:ok, [Workspace.t()]} | {:error, error()}
  def list(opts \\ [], auth \\ nil) do
    case req(auth) |> Req.get(url: "/api/workspaces", params: opts) |> unwrap() do
      {:ok, list} when is_list(list) -> {:ok, Enum.map(list, &Workspace.from_payload/1)}
      {:ok, other} -> {:error, {:unexpected, other}}
      err -> err
    end
  end

  @spec get(String.t(), auth()) :: {:ok, Workspace.t()} | {:error, error()}
  def get(id, auth \\ nil) do
    case req(auth) |> Req.get(url: "/api/workspaces/#{id}/status") |> unwrap() do
      {:ok, map} when is_map(map) -> {:ok, Workspace.from_payload(map)}
      {:ok, other} -> {:error, {:unexpected, other}}
      err -> err
    end
  end

  @spec create(map(), auth()) :: {:ok, Workspace.t()} | {:error, error()}
  def create(params, auth \\ nil) do
    case req(auth) |> Req.post(url: "/api/workspaces", json: params) |> unwrap() do
      {:ok, map} when is_map(map) -> {:ok, Workspace.from_payload(map)}
      {:ok, other} -> {:error, {:unexpected, other}}
      err -> err
    end
  end

  def start(id, auth \\ nil),
    do: req(auth) |> Req.post(url: "/api/workspaces/#{id}/start") |> unwrap()

  def stop(id, auth \\ nil),
    do: req(auth) |> Req.post(url: "/api/workspaces/#{id}/stop") |> unwrap()

  def delete(id, opts \\ [], auth \\ nil) do
    req(auth) |> Req.delete(url: "/api/workspaces/#{id}", params: opts) |> unwrap()
  end

  @doc """
  Streams SSE log lines for a workspace service to `pid` as
  `{:source_log, ref, line}` and `{:source_log_done, ref}` when the connection ends.
  """
  def stream_logs(id, service, pid) do
    url = base_url() <> "/api/workspaces/#{id}/logs/#{service}"
    ref = make_ref()

    # The task is linked (Task.async) so it dies with the subscriber, but any
    # exception inside the pump must not propagate back through that link and
    # kill the subscribing LiveView — contain it and still signal done.
    task =
      Task.async(fn ->
        try do
          url
          |> Req.get(
            Keyword.merge(
              [receive_timeout: :infinity, into: sse_into(pid, ref)],
              manager_req_options()
            )
          )
        catch
          kind, reason ->
            Logger.warning("log stream pump failed: #{Exception.format(kind, reason)}")
        end

        send(pid, {:source_log_done, ref})
      end)

    {:ok, ref, task}
  end

  def base_url do
    Application.get_env(:casein, :manager_url) ||
      System.get_env("MILC_DEVBOX_MANAGER_URL") ||
      "http://localhost:9000"
  end

  defp parse_sse(chunk) do
    chunk
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn
      "data: " <> line -> [line]
      _ -> []
    end)
  end

  defp req(auth) do
    [
      base_url: base_url(),
      receive_timeout: 15_000,
      retry: false,
      headers: auth_headers(auth)
    ]
    |> Keyword.merge(manager_req_options())
    |> Req.new()
  end

  defp manager_req_options do
    Application.get_env(:casein, :manager_req_options, [])
  end

  defp sse_into(pid, ref) do
    fn {:data, chunk}, acc ->
      for line <- parse_sse(chunk), do: send(pid, {:source_log, ref, line})
      {:cont, acc}
    end
  end

  # An explicit forward-auth email wins; otherwise fall back to the static
  # config (set for non-LiveView callers / single-user deployments).
  defp auth_headers(email) when is_binary(email) and email != "",
    do: [{"x-auth-request-email", email}]

  defp auth_headers(_) do
    case Application.get_env(:casein, :manager_user_email) ||
           System.get_env("CASEIN_DEVBOX_USER_EMAIL") do
      nil -> []
      email -> [{"x-auth-request-email", email}]
    end
  end

  defp unwrap({:ok, %Req.Response{status: s, body: body}}) when s in 200..299, do: {:ok, body}
  defp unwrap({:ok, %Req.Response{status: s, body: body}}), do: {:error, {:http, s, body}}
  defp unwrap({:error, reason}), do: {:error, {:transport, reason}}
end
