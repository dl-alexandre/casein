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

  @spec nth() :: map()
  def nth,
    do: %{
      type: "integer",
      minimum: 0,
      description:
        "0-based index to disambiguate when the selector matches multiple elements; defaults to the first visible match."
    }

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
          "session already exists for this preview. This does not create another tmux " <>
          "preview pane; panes are reused by surface/origin."
    }
  end

  @spec force_new_pane() :: map()
  def force_new_pane do
    %{
      type: "boolean",
      description:
        "Explicitly split a new tmux preview pane after the target URL passes the " <>
          "reachability preflight. Avoid this for normal retries; failed preflight opens " <>
          "no pane."
    }
  end

  @spec share_session() :: map()
  def share_session do
    %{
      type: "boolean",
      description:
        "When true, split a new preview pane that attaches to an existing preview " <>
          "pane's browser/control session. Fails with no_shared_preview_found when no " <>
          "source pane is available."
    }
  end

  @spec attach_to_pane_id() :: map()
  def attach_to_pane_id do
    %{
      type: "string",
      description:
        "Optional source preview pane id to share exactly when share_session is true. " <>
          "When omitted, DevIDE attaches to an active same-origin preview pane."
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

  @spec storage_profile() :: map()
  def storage_profile do
    %{
      type: "string",
      enum: ["ephemeral", "workspace", "profile"],
      default: "ephemeral",
      description:
        "Preview browser storage persistence mode. Use ephemeral for no durable auth " <>
          "state, workspace to remember cookies/localStorage per workspace and origin, " <>
          "or profile with storage_profile_name for a named reusable login state."
    }
  end

  @spec storage_profile_name() :: map()
  def storage_profile_name do
    %{
      type: "string",
      description:
        "Required when storage_profile is profile. Names a reusable per-workspace, " <>
          "per-origin browser storage profile, such as staging-admin or demo-user."
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
      force_new_pane: force_new_pane(),
      share_session: share_session(),
      attach_to_pane_id: attach_to_pane_id(),
      isolation_key: isolation_key(),
      storage_profile: storage_profile(),
      storage_profile_name: storage_profile_name()
    })
  end
end
