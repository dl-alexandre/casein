defmodule DevIDE.Agents.PreviewTools do
  @moduledoc """
  Narrow agent-facing preview operations.

  Agents can open workspace surfaces, observe pages, interact with trusted
  previews, and capture evidence — without arbitrary browser or external URL
  access.
  """

  alias DevIDE.PreviewControl
  alias DevIDE.Previews

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
        name: "preview_open_app",
        description: "Open the workspace app preview surface in a controllable session.",
        parameters: %{
          type: "object",
          properties: %{
            workspace_id: %{type: "string"},
            surface: %{type: "string", default: "app"},
            actor_id: %{type: "string"},
            assignment_id: %{type: "string"}
          },
          required: ["workspace_id"]
        }
      },
      %{
        name: "preview_observe",
        description: "Observe the current preview page (URL, DOM summary, browser errors).",
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
        name: "preview_report_errors",
        description: "Return console and network errors from the latest observation.",
        parameters: %{
          type: "object",
          properties: %{session_id: %{type: "integer"}},
          required: ["session_id"]
        }
      }
    ]
  end

  @doc "Dispatch a named agent preview tool."
  @spec invoke(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def invoke(tool_name, workspace, params) when is_map(workspace) and is_map(params) do
    case tool_name do
      "preview_open_app" -> open_app_preview(workspace, params)
      "preview_observe" -> observe(params)
      "preview_click" -> click(params)
      "preview_type" -> type(params)
      "preview_press" -> press(params)
      "preview_screenshot" -> screenshot(params)
      "preview_close" -> close(params)
      "preview_report_errors" -> report_errors(params)
      _ -> {:error, :unknown_tool}
    end
  end

  @doc "Open the app (or named) preview surface for agent feedback."
  @spec open_app_preview(map(), map()) :: {:ok, map()} | {:error, term()}
  def open_app_preview(workspace, params \\ %{}) do
    surface = Map.get(params, "surface", Map.get(params, :surface, "app"))
    opts = tool_opts(params)

    with {:ok, session} <- PreviewControl.open_session(workspace, surface, opts) do
      {:ok, session_payload(session)}
    end
  end

  @doc "Observe the current preview page."
  @spec observe(map() | integer()) :: {:ok, map()} | {:error, term()}
  def observe(%{"session_id" => id}),
    do: with({:ok, id} <- parse_id(id), do: PreviewControl.observe(id))

  def observe(%{session_id: id}),
    do: with({:ok, id} <- parse_id(id), do: PreviewControl.observe(id))

  def observe(id) when is_integer(id), do: PreviewControl.observe(id)

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

  @doc "Report browser console/network errors from the latest observation."
  @spec report_errors(map() | integer()) :: {:ok, map()} | {:error, term()}
  def report_errors(%{"session_id" => id}),
    do: with({:ok, id} <- parse_id(id), do: do_report_errors(id))

  def report_errors(%{session_id: id}),
    do: with({:ok, id} <- parse_id(id), do: do_report_errors(id))

  def report_errors(id) when is_integer(id), do: do_report_errors(id)

  defp do_report_errors(session_id) do
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
      console_errors: Map.get(data, "errors") || Map.get(data, :errors) || [],
      network_errors: []
    }
  end

  defp session_payload(session) do
    %{
      session_id: session.id,
      workspace_id: session.workspace_id,
      preview_id: session.preview_id,
      surface: session.surface,
      current_url: session.current_url,
      adapter: session.adapter
    }
  end

  defp tool_opts(params) do
    [
      actor_id: Map.get(params, "actor_id") || Map.get(params, :actor_id),
      assignment_id: Map.get(params, "assignment_id") || Map.get(params, :assignment_id)
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp parse_id(id) when is_integer(id), do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> {:ok, int}
      _ -> {:error, :invalid_session_id}
    end
  end

  defp parse_id(_), do: {:error, :invalid_session_id}

  @doc "List discoverable surfaces for agent planning."
  def list_surfaces(workspace), do: Previews.discover_surfaces(workspace)
end
