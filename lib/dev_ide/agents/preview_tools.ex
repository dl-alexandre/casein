defmodule DevIDE.Agents.PreviewTools do
  @moduledoc """
  Narrow agent-facing preview operations.

  Agents can open workspace surfaces, observe pages, interact with trusted
  previews, and capture evidence — without arbitrary browser or external URL
  access.
  """

  alias DevIDE.Agents.BrowserControl
  alias DevIDE.PreviewControl
  alias DevIDE.Previews
  alias DevIDE.Previews.{Surface, Url, WorkspaceContext}
  alias DevIDE.Workspaces
  alias DevIDE.Workspaces.Aliases, as: WorkspaceAliases

  @workspace_id_param McpCtl.Schema.workspace_id_param(:preview)
  @workspace_path_param McpCtl.Schema.workspace_path_param()

  @default_headers_param %{
    type: "object",
    description:
      "Extra HTTP headers for preview fetches and the Playwright browser context, including " <>
        "WebSocket upgrade requests. Useful for forward-auth previews, e.g. " <>
        ~s({"X-Auth-Request-Email":"user@example.com"})
  }

  @new_control_session_param %{
    type: "boolean",
    description:
      "When true, create a fresh browser/control runtime even if a compatible open " <>
        "session already exists for this preview."
  }

  @isolation_key_param %{
    type: "string",
    description:
      "Optional caller-defined lane for keeping auth/storage/task state separate while " <>
        "still reusing the same workspace preview surface."
  }

  @type tool :: %{
          name: String.t(),
          description: String.t(),
          parameters: map()
        }

  @doc "Tool definitions exposed to agent runtimes."
  @spec definitions() :: [tool()]
  def definitions do
    [
      %{
        name: "preview_resolve_workspace",
        description:
          "Resolve a workspace_id from a manager id or a folder path. Use this when a preview " <>
            "tool reports workspace_not_found or when working from an attached local folder.",
        parameters: %{
          type: "object",
          properties: %{
            workspace_id: @workspace_id_param,
            workspace_path: @workspace_path_param,
            path: @workspace_path_param,
            cwd: @workspace_path_param
          },
          required: []
        }
      },
      %{
        name: "preview_surfaces",
        description:
          "List discoverable preview surfaces for a workspace (manager URLs, " <>
            "metadata localhost ports, and ports detected from tmux terminal output). " <>
            "Call before preview_open_app to pick a surface name.",
        parameters: %{
          type: "object",
          properties: %{
            workspace_id: @workspace_id_param,
            workspace_path: @workspace_path_param
          },
          required: ["workspace_id"]
        }
      },
      %{
        name: "preview_open_current_workspace",
        description:
          "Open the pre-scoped current workspace app preview, auto-navigate to the DevIDE " <>
            "workspace viewer on loopback when available, and return the control session. " <>
            "On loopback, returns navigated_to on success or navigation_failed when open " <>
            "succeeded but viewer navigation was blocked. " <>
            "Prefer this when the MCP endpoint initialize response says it is pre-scoped.",
        parameters: %{
          type: "object",
          properties: %{
            surface: %{type: "string", default: "app"},
            default_headers: @default_headers_param,
            actor_id: %{type: "string"},
            assignment_id: %{type: "string"},
            new_control_session: @new_control_session_param,
            isolation_key: @isolation_key_param
          },
          required: []
        }
      },
      %{
        name: "preview_open_app",
        description:
          "Open the workspace app preview surface in a controllable session. On loopback " <>
            "DevIDE (app-local), auto-navigates to the workspace viewer route and returns " <>
            "navigated_to on success or navigation_failed when open succeeded but viewer " <>
            "navigation was blocked.",
        parameters: %{
          type: "object",
          properties: %{
            workspace_id: @workspace_id_param,
            workspace_path: @workspace_path_param,
            surface: %{type: "string", default: "app"},
            default_headers: @default_headers_param,
            actor_id: %{type: "string"},
            assignment_id: %{type: "string"},
            new_control_session: @new_control_session_param,
            isolation_key: @isolation_key_param
          },
          required: ["workspace_id"]
        }
      },
      %{
        name: "preview_open_localhost",
        description:
          "Open a localhost preview on a specific port (e.g. after serving static " <>
            "HTML with python -m http.server). When port is the DevIDE loopback port " <>
            "and path is /, opens /workspaces instead. Port must be in workspace metadata, " <>
            "a common dev port, or detected from terminal output.",
        parameters: %{
          type: "object",
          properties: %{
            workspace_id: @workspace_id_param,
            workspace_path: @workspace_path_param,
            port: %{type: "integer"},
            path: %{type: "string", default: "/"},
            default_headers: @default_headers_param,
            actor_id: %{type: "string"},
            assignment_id: %{type: "string"},
            new_control_session: @new_control_session_param,
            isolation_key: @isolation_key_param
          },
          required: ["workspace_id", "port"]
        }
      },
      %{
        name: "preview_navigate",
        description:
          "Navigate within the allowed preview origin (relative path or same-origin URL).",
        parameters: %{
          type: "object",
          properties: %{
            session_id: %{type: "integer"},
            path: %{type: "string"}
          },
          required: ["session_id", "path"]
        }
      },
      %{
        name: "preview_observe",
        description: "Observe the current preview page with static HTTP HTML fetch.",
        parameters: %{
          type: "object",
          properties: %{session_id: %{type: "integer"}},
          required: ["session_id"]
        }
      },
      %{
        name: "preview_observe_live",
        description:
          "Observe the current preview page through browser automation for post-hydration DOM state.",
        parameters: %{
          type: "object",
          properties: %{session_id: %{type: "integer"}},
          required: ["session_id"]
        }
      },
      %{
        name: "preview_click",
        description: "Click an element by CSS selector or viewport coordinates.",
        parameters: %{
          type: "object",
          properties: %{
            session_id: %{type: "integer"},
            selector: %{type: "string"},
            x: %{type: "integer"},
            y: %{type: "integer"}
          },
          required: ["session_id"]
        }
      },
      %{
        name: "preview_type",
        description: "Type text into an input matched by CSS selector.",
        parameters: %{
          type: "object",
          properties: %{
            session_id: %{type: "integer"},
            selector: %{type: "string"},
            text: %{type: "string"}
          },
          required: ["session_id", "selector", "text"]
        }
      },
      %{
        name: "preview_press",
        description: "Press a keyboard key in the preview session.",
        parameters: %{
          type: "object",
          properties: %{
            session_id: %{type: "integer"},
            key: %{type: "string"}
          },
          required: ["session_id", "key"]
        }
      },
      %{
        name: "preview_screenshot",
        description: "Capture a screenshot artifact from the current preview page.",
        parameters: %{
          type: "object",
          properties: %{session_id: %{type: "integer"}},
          required: ["session_id"]
        }
      },
      %{
        name: "preview_close",
        description: "Close a preview control session and release browser resources.",
        parameters: %{
          type: "object",
          properties: %{session_id: %{type: "integer"}},
          required: ["session_id"]
        }
      },
      %{
        name: "preview_get_storage",
        description: "Return localStorage and sessionStorage for the current preview origin.",
        parameters: %{
          type: "object",
          properties: %{session_id: %{type: "integer"}},
          required: ["session_id"]
        }
      },
      %{
        name: "preview_report_errors",
        description: "Return console and network errors from the latest observation.",
        parameters: %{
          type: "object",
          properties: %{session_id: %{type: "integer"}},
          required: ["session_id"]
        }
      },
      %{
        name: "preview_reload_iframe",
        description:
          "Ask connected DevIDE viewers for this workspace to reload the active embedded " <>
            "preview iframe. Best-effort broadcast; does not mutate the preview control session.",
        parameters: %{
          type: "object",
          properties: %{
            workspace_id: @workspace_id_param,
            workspace_path: @workspace_path_param,
            actor_id: %{type: "string"},
            reason: %{type: "string"}
          },
          required: ["workspace_id"]
        }
      },
      %{
        name: "devide_reload_page",
        description:
          "Ask connected DevIDE viewers for this workspace to reload the whole workspace page. " <>
            "The terminal should reattach through DevIDE's per-tab tmux session id.",
        parameters: %{
          type: "object",
          properties: %{
            workspace_id: @workspace_id_param,
            workspace_path: @workspace_path_param,
            actor_id: %{type: "string"},
            reason: %{type: "string"}
          },
          required: ["workspace_id"]
        }
      }
    ]
  end

  @doc "Dispatch a named agent preview tool."
  @spec invoke(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def invoke(tool_name, workspace, params) when is_map(workspace) and is_map(params) do
    case tool_name do
      "preview_resolve_workspace" -> resolve_workspace(params)
      "preview_surfaces" -> surfaces(workspace)
      "preview_open_current_workspace" -> open_app_preview(workspace, params)
      "preview_open_app" -> open_app_preview(workspace, params)
      "preview_open_localhost" -> open_localhost_preview(workspace, params)
      "preview_navigate" -> navigate(params)
      "preview_observe" -> observe(params)
      "preview_observe_live" -> observe_live(params)
      "preview_click" -> click(params)
      "preview_type" -> type(params)
      "preview_press" -> press(params)
      "preview_screenshot" -> screenshot(params)
      "preview_close" -> close(params)
      "preview_get_storage" -> get_storage(params)
      "preview_report_errors" -> report_errors(params)
      "preview_reload_iframe" -> reload_iframe(workspace, params)
      "devide_reload_page" -> reload_page(workspace, params)
      _ -> {:error, :unknown_tool}
    end
  end

  @doc "List discoverable preview surfaces for agent planning."
  @spec surfaces(map()) :: {:ok, map()} | {:error, term()}
  def surfaces(workspace) when is_map(workspace) do
    workspace = WorkspaceContext.prepare(workspace)

    payload =
      workspace
      |> Previews.discover_surfaces()
      |> Enum.map(&surface_payload/1)

    {:ok, %{surfaces: payload}}
  end

  @doc "Open the app (or named) preview surface for agent feedback."
  @spec open_app_preview(map(), map()) :: {:ok, map()} | {:error, term()}
  def open_app_preview(workspace, params \\ %{}) do
    surface = Map.get(params, "surface", Map.get(params, :surface, "app"))
    opts = tool_opts(params, workspace)

    with {:ok, session} <- PreviewControl.open_session(workspace, surface, opts),
         {:ok, navigation} <- maybe_navigate_to_workspace(workspace, session) do
      {:ok, session_payload(session, navigation)}
    end
  end

  @doc "Open a localhost preview on an allowed port."
  @spec open_localhost_preview(map(), map()) :: {:ok, map()} | {:error, term()}
  def open_localhost_preview(workspace, params \\ %{}) when is_map(workspace) do
    with {:ok, port} <- parse_port(Map.get(params, "port") || Map.get(params, :port)),
         path <- localhost_path(workspace, port, params),
         opts <- tool_opts(params, workspace) |> Keyword.put(:path, path),
         {:ok, session} <- PreviewControl.open_localhost_session(workspace, port, opts) do
      {:ok, session_payload(session)}
    end
  end

  @doc "Navigate within the allowed preview origin."
  @spec navigate(map()) :: {:ok, map()} | {:error, term()}
  def navigate(params) when is_map(params) do
    with {:ok, id} <- parse_id(Map.get(params, "session_id") || Map.get(params, :session_id)),
         path when is_binary(path) <-
           Map.get(params, "path") || Map.get(params, :path) ||
             {:error, {:missing_argument, "path"}} do
      PreviewControl.navigate(id, path)
    end
  end

  @doc "Observe the current preview page."
  @spec observe(map() | integer()) :: {:ok, map()} | {:error, term()}
  def observe(%{"session_id" => id}),
    do: with({:ok, id} <- parse_id(id), do: PreviewControl.observe(id))

  def observe(%{session_id: id}),
    do: with({:ok, id} <- parse_id(id), do: PreviewControl.observe(id))

  def observe(id) when is_integer(id), do: PreviewControl.observe(id)

  @doc "Observe the current preview page through the browser runtime."
  @spec observe_live(map() | integer()) :: {:ok, map()} | {:error, term()}
  def observe_live(%{"session_id" => id}),
    do: with({:ok, id} <- parse_id(id), do: PreviewControl.observe_live(id))

  def observe_live(%{session_id: id}),
    do: with({:ok, id} <- parse_id(id), do: PreviewControl.observe_live(id))

  def observe_live(id) when is_integer(id), do: PreviewControl.observe_live(id)

  @doc "Click in the preview session."
  @spec click(map()) :: {:ok, map()} | {:error, term()}
  def click(params) when is_map(params) do
    with {:ok, id} <- parse_id(Map.get(params, "session_id") || Map.get(params, :session_id)) do
      target =
        cond do
          selector = Map.get(params, "selector") || Map.get(params, :selector) ->
            %{selector: selector}

          x = Map.get(params, "x") || Map.get(params, :x) ->
            y = Map.get(params, "y") || Map.get(params, :y)
            %{x: x, y: y}

          true ->
            %{}
        end

      PreviewControl.click(id, target)
    end
  end

  @doc "Type into a preview input."
  @spec type(map()) :: {:ok, map()} | {:error, term()}
  def type(params) when is_map(params) do
    with {:ok, id} <- parse_id(Map.get(params, "session_id") || Map.get(params, :session_id)) do
      selector = Map.get(params, "selector") || Map.get(params, :selector)
      text = Map.get(params, "text") || Map.get(params, :text)
      PreviewControl.type(id, selector, text)
    end
  end

  @doc "Press a key in the preview session."
  @spec press(map()) :: {:ok, map()} | {:error, term()}
  def press(params) when is_map(params) do
    with {:ok, id} <- parse_id(Map.get(params, "session_id") || Map.get(params, :session_id)) do
      key = Map.get(params, "key") || Map.get(params, :key)
      PreviewControl.press(id, key)
    end
  end

  @doc "Capture a screenshot from the preview session."
  @spec screenshot(map() | integer()) :: {:ok, map()} | {:error, term()}
  def screenshot(%{"session_id" => id}),
    do: with({:ok, id} <- parse_id(id), do: PreviewControl.screenshot(id))

  def screenshot(%{session_id: id}),
    do: with({:ok, id} <- parse_id(id), do: PreviewControl.screenshot(id))

  def screenshot(id) when is_integer(id), do: PreviewControl.screenshot(id)

  @doc "Close a preview control session."
  @spec close(map() | integer()) :: {:ok, map()} | {:error, term()}
  def close(%{"session_id" => id}),
    do: with({:ok, id} <- parse_id(id), do: do_close(id))

  def close(%{session_id: id}),
    do: with({:ok, id} <- parse_id(id), do: do_close(id))

  def close(id) when is_integer(id), do: do_close(id)

  @doc "Return preview origin localStorage and sessionStorage."
  @spec get_storage(map() | integer()) :: {:ok, map()} | {:error, term()}
  def get_storage(%{"session_id" => id}),
    do: with({:ok, id} <- parse_id(id), do: PreviewControl.get_storage(id))

  def get_storage(%{session_id: id}),
    do: with({:ok, id} <- parse_id(id), do: PreviewControl.get_storage(id))

  def get_storage(id) when is_integer(id), do: PreviewControl.get_storage(id)

  @doc "Report browser console/network errors from the latest observation."
  @spec report_errors(map() | integer()) :: {:ok, map()} | {:error, term()}
  def report_errors(%{"session_id" => id}),
    do: with({:ok, id} <- parse_id(id), do: do_report_errors(id))

  def report_errors(%{session_id: id}),
    do: with({:ok, id} <- parse_id(id), do: do_report_errors(id))

  def report_errors(id) when is_integer(id), do: do_report_errors(id)

  @doc "Ask connected workspace viewers to reload the active preview iframe."
  @spec reload_iframe(map(), map()) :: {:ok, map()} | {:error, term()}
  def reload_iframe(workspace, params) when is_map(workspace) and is_map(params) do
    BrowserControl.reload_preview_iframe(workspace, browser_control_opts(params))
  end

  @doc "Ask connected workspace viewers to reload the whole DevIDE page."
  @spec reload_page(map(), map()) :: {:ok, map()} | {:error, term()}
  def reload_page(workspace, params) when is_map(workspace) and is_map(params) do
    BrowserControl.reload_page(workspace, browser_control_opts(params))
  end

  defp do_report_errors(session_id) do
    case PreviewControl.latest_errors(session_id) do
      %{console_errors: [], network_errors: []} ->
        report_errors_from_observation(session_id)

      errors ->
        {:ok, errors}
    end
  end

  defp report_errors_from_observation(session_id) do
    case PreviewControl.latest_observation(session_id) do
      nil ->
        with {:ok, observation} <- PreviewControl.observe(session_id) do
          {:ok, errors_payload(observation)}
        end

      obs ->
        {:ok, errors_payload(obs.data)}
    end
  end

  defp do_close(session_id) do
    with {:ok, session} <- PreviewControl.close_session(session_id) do
      {:ok, %{session_id: session.id, status: session.status}}
    end
  end

  defp errors_payload(data) when is_map(data) do
    %{
      console_errors:
        Map.get(data, "console_errors") || Map.get(data, :console_errors) ||
          Map.get(data, "errors") || Map.get(data, :errors) || [],
      network_errors: Map.get(data, "network_errors") || Map.get(data, :network_errors) || []
    }
  end

  defp session_payload(session, navigation \\ %{}) do
    navigation = navigation || %{}
    navigated_to = Map.get(navigation, :navigated_to)

    payload = %{
      session_id: session.id,
      workspace_id: session.workspace_id,
      preview_id: session.preview_id,
      surface: session.surface,
      current_url: navigated_to || session.current_url,
      display_url: session.metadata["display_url"],
      adapter: session.adapter
    }

    payload
    |> maybe_put_navigated_to(Map.get(navigation, :navigated_to))
    |> maybe_put_navigation_failed(Map.get(navigation, :navigation_failed))
  end

  defp maybe_put_navigated_to(payload, navigated_to)
       when is_binary(navigated_to) and navigated_to != "" do
    Map.put(payload, :navigated_to, navigated_to)
  end

  defp maybe_put_navigated_to(payload, _), do: payload

  defp maybe_put_navigation_failed(payload, failed) when not is_nil(failed) do
    Map.put(payload, :navigation_failed, navigation_failure_payload(failed))
  end

  defp maybe_put_navigation_failed(payload, _), do: payload

  defp maybe_navigate_to_workspace(workspace, session) do
    if loopback_devide_session?(session) do
      route = workspace_viewer_route(workspace)

      case PreviewControl.navigate(session.id, route) do
        {:ok, observation} ->
          {:ok,
           %{
             navigated_to: Map.get(observation, :url) || Map.get(observation, "url") || route,
             navigation_failed: nil
           }}

        {:error, reason} ->
          {:ok, %{navigated_to: nil, navigation_failed: reason}}
      end
    else
      {:ok, %{navigated_to: nil, navigation_failed: nil}}
    end
  end

  defp navigation_failure_payload({:redirect_blocked, status, location}) do
    %{error: :redirect_blocked, status: status, location: location}
  end

  defp navigation_failure_payload({:http_status, status, body}) do
    %{error: :http_status, status: status, body: body}
  end

  defp navigation_failure_payload(reason) when is_map(reason), do: reason

  defp navigation_failure_payload(reason) when is_atom(reason), do: %{error: reason}

  defp navigation_failure_payload(reason), do: %{error: :navigation_failed, reason: reason}

  defp loopback_devide_session?(%{current_url: url}) when is_binary(url),
    do: devide_loopback_url?(url)

  defp loopback_devide_session?(_), do: false

  defp devide_loopback_url?(url) do
    port = Application.get_env(:dev_ide, :preview_loopback_port, 4000)

    Url.localhost_url?(url) and
      case URI.parse(url) do
        %URI{port: ^port} -> true
        %URI{port: nil} when port in [80, 443] -> true
        _ -> false
      end
  end

  defp workspace_viewer_route(workspace) do
    case workspace_id(workspace) do
      id when is_binary(id) and id != "" -> WorkspaceAliases.viewer_route_id(id)
      _ -> "/workspaces"
    end
  end

  defp workspace_id(workspace) do
    Map.get(workspace, :id) || Map.get(workspace, "id")
  end

  defp localhost_path(_workspace, port, params) do
    path = Map.get(params, "path", Map.get(params, :path, "/"))
    loopback_port = Application.get_env(:dev_ide, :preview_loopback_port, 4000)

    if port == loopback_port and path in ["/", ""] do
      "/workspaces"
    else
      path
    end
  end

  defp tool_opts(params, workspace) do
    [
      actor_id: Map.get(params, "actor_id") || Map.get(params, :actor_id),
      assignment_id: Map.get(params, "assignment_id") || Map.get(params, :assignment_id),
      default_headers: default_headers(params, workspace),
      new_control_session: boolean_param(params, :new_control_session),
      isolation_key: string_param(params, :isolation_key)
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp boolean_param(params, key) when is_map(params) and is_atom(key) do
    value = Map.get(params, Atom.to_string(key)) || Map.get(params, key)

    case value do
      value when value in [true, false] -> value
      value when value in ["true", "1", "yes"] -> true
      value when value in ["false", "0", "no"] -> false
      _ -> nil
    end
  end

  defp string_param(params, key) when is_map(params) and is_atom(key) do
    case Map.get(params, Atom.to_string(key)) || Map.get(params, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp browser_control_opts(params) do
    [
      actor_id: Map.get(params, "actor_id") || Map.get(params, :actor_id),
      reason: Map.get(params, "reason") || Map.get(params, :reason)
    ]
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
  end

  defp resolve_workspace(params) when is_map(params) do
    cond do
      id = Map.get(params, "workspace_id") || Map.get(params, :workspace_id) ->
        workspace_payload(id)

      path = workspace_path(params) ->
        path
        |> Workspaces.attach_folder()
        |> case do
          {:ok, workspace} -> {:ok, workspace_resolution_payload(workspace)}
          {:error, reason} -> {:error, workspace_path_error(path, reason)}
        end

      true ->
        {:error,
         %{
           error: :missing_workspace_reference,
           message:
             "Pass workspace_id or workspace_path. Generated DevIDE MCP URLs inject workspace_id automatically.",
           folder_id_format: "folder:<base64url-absolute-path>"
         }}
    end
  end

  defp workspace_payload(id) when is_binary(id) do
    case Workspaces.get(id) do
      {:ok, workspace} -> {:ok, workspace_resolution_payload(workspace)}
      {:error, reason} -> {:error, workspace_id_error(id, reason)}
    end
  end

  defp workspace_resolution_payload(workspace) do
    %{
      workspace_id: workspace.id,
      name: workspace.name,
      path: workspace.path,
      attached_folder: get_in(workspace.metadata || %{}, [:attached_folder]) == true,
      folder_id_format: "folder:<base64url-absolute-path>"
    }
  end

  defp workspace_path(params),
    do:
      Map.get(params, "workspace_path") || Map.get(params, :workspace_path) ||
        Map.get(params, "path") || Map.get(params, :path) || Map.get(params, "cwd") ||
        Map.get(params, :cwd)

  defp workspace_id_error(id, reason) do
    %{
      error: :workspace_not_found,
      workspace_id: id,
      reason: reason,
      message:
        "Workspace #{inspect(id)} was not found. For attached folders, pass workspace_path or use folder:<base64url-absolute-path>.",
      folder_id_format: "folder:<base64url-absolute-path>"
    }
  end

  defp workspace_path_error(path, reason) do
    %{
      error: :workspace_path_not_resolved,
      path: path,
      reason: reason,
      message: "Workspace path #{inspect(path)} could not be attached or is outside allowed roots"
    }
  end

  defp default_headers(params, workspace) do
    case Map.get(params, "default_headers") || Map.get(params, :default_headers) do
      headers when is_map(headers) ->
        sanitize_headers(headers)

      _ ->
        case workspace do
          ws when is_map(ws) -> Workspaces.forward_auth_headers(ws)
          _ -> nil
        end
    end
  end

  defp sanitize_headers(headers) do
    headers
    |> Enum.flat_map(fn {key, value} ->
      key = to_string(key)

      cond do
        key == "" -> []
        String.contains?(key, ["\r", "\n", ":"]) -> []
        not is_binary(value) -> []
        String.contains?(value, ["\r", "\n"]) -> []
        true -> [{key, value}]
      end
    end)
    |> Enum.take(20)
    |> Map.new()
  end

  defp parse_id(id) when is_integer(id), do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> {:ok, int}
      _ -> {:error, :invalid_session_id}
    end
  end

  defp parse_id(_), do: {:error, :invalid_session_id}

  defp parse_port(port) when is_integer(port), do: {:ok, port}

  defp parse_port(port) when is_binary(port) do
    case Integer.parse(port) do
      {int, ""} -> {:ok, int}
      _ -> {:error, :invalid_port}
    end
  end

  defp parse_port(_), do: {:error, :invalid_port}

  defp surface_payload(%Surface{} = surface) do
    %{
      name: surface.name,
      url: surface.url,
      title: surface.title,
      port: surface.port,
      source: Atom.to_string(surface.source)
    }
  end

  @doc "List discoverable surfaces for agent planning."
  def list_surfaces(workspace),
    do: Previews.discover_surfaces(WorkspaceContext.prepare(workspace))
end
