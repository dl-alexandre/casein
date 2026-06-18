defmodule DevIDE.Previews.WorkspaceContext do
  @moduledoc """
  Prepares workspace values for agent preview control.

  Enriches manager workspaces with terminal-detected localhost ports so
  `preview_open_app`, `preview_open_localhost`, and `preview_surfaces` can
  see ad-hoc dev servers started in tmux panes.
  """

  alias DevIDE.Previews.{SocketDetector, TerminalOutput, Url}

  @doc """
  Enrich a workspace with terminal output and detected localhost ports.

  Detected ports are the union of two sources: listening sockets probed inside
  the workspace (`SocketDetector`, reliable) and regex hits in recent terminal
  scrollback (`TerminalOutput`, fallback for servers we can't probe).

  Idempotent: once a workspace carries both `terminal_output` and
  `detected_ports` it is returned untouched, so the socket probe and tmux
  capture run at most once even when callers re-`prepare/1` the same map.
  """
  @spec prepare(map()) :: map()
  def prepare(workspace) when is_map(workspace) do
    metadata = metadata_map(workspace)
    existing_output = metadata_value(metadata, :terminal_output)
    existing_ports = metadata_value(metadata, :detected_ports)

    if is_binary(existing_output) and existing_output != "" and is_list(existing_ports) do
      workspace
    else
      output =
        case existing_output do
          text when is_binary(text) and text != "" -> text
          _ -> TerminalOutput.gather(workspace)
        end

      detected_ports =
        (SocketDetector.discover_ports(workspace) ++ TerminalOutput.ports_from_text(output))
        |> Enum.uniq()
        |> Enum.sort()

      metadata =
        metadata
        |> Map.put("terminal_output", output)
        |> Map.put("detected_ports", detected_ports)

      put_metadata(workspace, metadata)
    end
  end

  @doc "Allowed origins including terminal-detected localhost ports."
  @spec allowed_origins(map()) :: [String.t()]
  def allowed_origins(workspace) when is_map(workspace),
    do: Url.allowed_origins(prepare(workspace))

  @doc "True when `port` may be opened or navigated for this workspace."
  @spec port_allowed?(map(), integer()) :: boolean()
  def port_allowed?(workspace, port) when is_map(workspace) and is_integer(port),
    do: Url.port_allowed?(port, prepare(workspace))

  @doc "Validate a localhost port before opening a preview session."
  @spec validate_port(map(), integer()) :: :ok | {:error, map()}
  def validate_port(workspace, port) when is_map(workspace) and is_integer(port) do
    if port_allowed?(workspace, port) do
      :ok
    else
      {:error,
       %{
         error: :port_not_allowed,
         port: port,
         allowed_ports: allowed_ports(workspace),
         message: "Port #{port} is not allowed for preview control"
       }}
    end
  end

  @doc "Allowed localhost ports for a workspace."
  @spec allowed_ports(map()) :: [integer()]
  def allowed_ports(workspace) when is_map(workspace),
    do: workspace |> prepare() |> Url.allowed_ports()

  @doc "Build a normalized localhost URL for server-side preview control."
  @spec localhost_url(integer(), String.t()) :: String.t()
  def localhost_url(port, path \\ "/") when is_integer(port) and is_binary(path) do
    path = normalize_path(path)
    "http://localhost:#{port}#{path}"
  end

  defp normalize_path(path) do
    cond do
      path == "" -> "/"
      String.starts_with?(path, "/") -> path
      true -> "/" <> path
    end
  end

  defp metadata_map(workspace) do
    case Map.get(workspace, :metadata) || Map.get(workspace, "metadata") do
      m when is_map(m) -> m
      _ -> %{}
    end
  end

  defp metadata_value(metadata, key) when is_map(metadata) and is_atom(key) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp put_metadata(%DevIDE.Workspace{} = ws, metadata), do: %{ws | metadata: metadata}

  defp put_metadata(workspace, metadata) when is_map(workspace),
    do: Map.put(workspace, :metadata, metadata)
end
