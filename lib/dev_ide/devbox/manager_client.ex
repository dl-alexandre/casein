defmodule DevIDE.Devbox.ManagerClient do
  @moduledoc """
  Thin HTTP client for the milc-devbox Node manager API.

  Source of truth lives in `milc-devbox/manager`. We do not duplicate state.
  Configure base URL via `:dev_ide, :manager_url` or env `MILC_DEVBOX_MANAGER_URL`.

  Errors are returned as typed tuples:
    {:error, {:http, status, body}}
    {:error, {:transport, reason}}     # connection refused, timeout, ...
    {:error, {:unexpected, term}}
  """

  alias DevIDE.Devbox.Workspace

  @type error ::
          {:http, pos_integer(), term()}
          | {:transport, term()}
          | {:unexpected, term()}

  @spec list(keyword()) :: {:ok, [Workspace.t()]} | {:error, error()}
  def list(opts \\ []) do
    case req() |> Req.get(url: "/api/workspaces", params: opts) |> unwrap() do
      {:ok, list} when is_list(list) -> {:ok, Enum.map(list, &Workspace.from_payload/1)}
      {:ok, other} -> {:error, {:unexpected, other}}
      err -> err
    end
  end

  @spec get(String.t()) :: {:ok, Workspace.t()} | {:error, error()}
  def get(id) do
    case req() |> Req.get(url: "/api/workspaces/#{id}/status") |> unwrap() do
      {:ok, map} when is_map(map) -> {:ok, Workspace.from_payload(map)}
      {:ok, other} -> {:error, {:unexpected, other}}
      err -> err
    end
  end

  @spec create(map()) :: {:ok, Workspace.t()} | {:error, error()}
  def create(params) do
    case req() |> Req.post(url: "/api/workspaces", json: params) |> unwrap() do
      {:ok, map} when is_map(map) -> {:ok, Workspace.from_payload(map)}
      {:ok, other} -> {:error, {:unexpected, other}}
      err -> err
    end
  end

  def start(id), do: req() |> Req.post(url: "/api/workspaces/#{id}/start") |> unwrap()
  def stop(id), do: req() |> Req.post(url: "/api/workspaces/#{id}/stop") |> unwrap()

  def delete(id, opts \\ []) do
    req() |> Req.delete(url: "/api/workspaces/#{id}", params: opts) |> unwrap()
  end

  @doc """
  Streams SSE log lines for a workspace service to `pid` as
  `{:devbox_log, ref, line}` and `{:devbox_log_done, ref}` when the connection ends.
  """
  def stream_logs(id, service, pid) do
    url = base_url() <> "/api/workspaces/#{id}/logs/#{service}"
    ref = make_ref()

    task =
      Task.async(fn ->
        Req.get(url,
          receive_timeout: :infinity,
          into: fn {:data, chunk}, acc ->
            for line <- parse_sse(chunk), do: send(pid, {:devbox_log, ref, line})
            {:cont, acc}
          end
        )

        send(pid, {:devbox_log_done, ref})
      end)

    {:ok, ref, task}
  end

  def base_url do
    Application.get_env(:dev_ide, :manager_url) ||
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

  defp req do
    Req.new(base_url: base_url(), receive_timeout: 15_000, retry: false, headers: auth_headers())
  end

  defp auth_headers do
    case Application.get_env(:dev_ide, :manager_user_email) ||
           System.get_env("DEV_IDE_DEVBOX_USER_EMAIL") do
      nil -> []
      email -> [{"x-auth-request-email", email}]
    end
  end

  defp unwrap({:ok, %Req.Response{status: s, body: body}}) when s in 200..299, do: {:ok, body}
  defp unwrap({:ok, %Req.Response{status: s, body: body}}), do: {:error, {:http, s, body}}
  defp unwrap({:error, reason}), do: {:error, {:transport, reason}}
end
