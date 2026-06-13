defmodule McpCtl.Params do
  @moduledoc """
  Reusable JSON-schema parameter fragments for MCP tool definitions.
  """

  alias McpCtl.Schema

  @spec session() :: map()
  def session, do: %{type: "string"}

  @spec pane() :: map()
  def pane do
    %{
      type: "string",
      description: "Pane id from terminal_topology (e.g. \"%3\"); default: active pane."
    }
  end

  @spec keys() :: map()
  def keys, do: %{type: "string"}

  @spec command() :: map()
  def command, do: %{type: "string"}

  @spec lines() :: map()
  def lines do
    %{
      type: "integer",
      description: "Return only the last N lines. Omit for full scrollback."
    }
  end

  @spec ansi() :: map()
  def ansi do
    %{
      type: "boolean",
      description: "Keep ANSI color/escape codes. Default false for plain text."
    }
  end

  @spec session_id() :: map()
  def session_id, do: %{type: "integer"}

  @spec actor_id() :: map()
  def actor_id, do: %{type: "string"}

  @spec assignment_id() :: map()
  def assignment_id, do: %{type: "string"}

  @spec surface() :: map()
  def surface, do: %{type: "string", default: "app"}

  @spec port() :: map()
  def port, do: %{type: "integer"}

  @spec path() :: map()
  def path, do: %{type: "string", default: "/"}

  @spec selector() :: map()
  def selector, do: %{type: "string"}

  @spec text() :: map()
  def text, do: %{type: "string"}

  @spec key() :: map()
  def key, do: %{type: "string"}

  @spec x() :: map()
  def x, do: %{type: "integer"}

  @spec y() :: map()
  def y, do: %{type: "integer"}

  @spec contains() :: map()
  def contains, do: %{type: "string"}

  @spec workspace_path_param() :: map()
  def workspace_path_param, do: Schema.workspace_path_param()

  @spec default_headers() :: map()
  def default_headers do
    %{
      type: "object",
      description:
        "Extra HTTP headers for preview fetches and the Playwright browser context, including " <>
          "WebSocket upgrade requests. Useful for forward-auth previews, e.g. " <>
          ~s({"X-Auth-Request-Email":"user@example.com"})
    }
  end

  @spec new_control_session() :: map()
  def new_control_session do
    %{
      type: "boolean",
      description:
        "When true, create a fresh browser/control runtime even if a compatible open " <>
          "session already exists for this preview."
    }
  end

  @spec isolation_key() :: map()
  def isolation_key do
    %{
      type: "string",
      description:
        "Optional caller-defined lane for keeping auth/storage/task state separate while " <>
          "still reusing the same workspace preview surface."
    }
  end

  @spec terminal_workspace_props() :: map()
  def terminal_workspace_props do
    %{workspace_id: Schema.workspace_id_param(:terminal)}
  end

  @spec preview_workspace_props(keyword()) :: map()
  def preview_workspace_props(opts \\ []) do
    include_path? = Keyword.get(opts, :include_path, true)

    props = %{workspace_id: Schema.workspace_id_param(:preview)}

    if include_path? do
      Map.put(props, :workspace_path, Schema.workspace_path_param())
    else
      props
    end
  end

  @spec tmux_session() :: map()
  def tmux_session do
    %{
      type: "string",
      description:
        "Workspace tmux session name (from terminal_list_sessions). Required when " <>
          "multiple sessions match the workspace; otherwise the attached session with " <>
          "the freshest activity is chosen."
    }
  end

  @spec preview_open_props() :: map()
  def preview_open_props do
    preview_workspace_props()
    |> Map.merge(%{
      tmux_session: tmux_session(),
      surface: surface(),
      default_headers: default_headers(),
      actor_id: actor_id(),
      assignment_id: assignment_id(),
      new_control_session: new_control_session(),
      isolation_key: isolation_key()
    })
  end
end
