defmodule DevIDE.Agents.PreviewTools.Helpers do
  @moduledoc """
  Shared JSON-Schema fragments and MCP metadata for preview tool actions.
  Wire shapes are served on tools/list — keep them aligned with the previous
  hand-rolled `PreviewTools.definitions/0` output.
  """

  alias McpCtl.{Params, Tool}

  @doc false
  def workspace_props, do: Params.preview_workspace_props()

  @doc false
  def surface_props do
    Map.put(workspace_props(), :tmux_session, Params.tmux_session())
  end

  @doc false
  def open_props do
    Params.preview_open_props()
    |> Map.put(:port, Params.port())
    |> Map.put(:anchor_pane_id, %{type: "string"})
  end

  @doc false
  def mode_param do
    %{
      type: "string",
      enum: ["app", "localhost", "here"],
      default: "app",
      description:
        "Which surface to open: \"app\" (the workspace app surface), \"localhost\" " <>
          "(a specific dev-server port — requires port), or \"here\" (the app surface " <>
          "beside the calling agent — requires tmux_session)."
    }
  end

  @doc false
  def open_unified_props, do: Map.put(open_props(), :mode, mode_param())

  @doc false
  def session_only, do: Tool.object(%{session_id: Params.session_id()}, [:session_id])

  @doc false
  def visible_mutation_props do
    %{
      session_id: Params.session_id(),
      element_id: Params.element_id(),
      allow_headless: %{
        type: "boolean",
        description:
          "Allow the action to run only in the automation browser when no visible pane is registered."
      }
    }
  end

  @doc false
  def close_props do
    Tool.object(%{
      session_id: Params.session_id(),
      pane_id: %{type: "string"},
      tmux_session: Params.session()
    })
  end

  @doc false
  def compare_props do
    Tool.object(
      Map.merge(workspace_props(), %{
        artifact_a: %{
          type: "string",
          description:
            "First preview-artifact path (e.g. /preview-artifacts/ws-1/100.png) " <>
              "returned by preview_screenshot. A full URL is accepted; only its path is used."
        },
        artifact_b: %{
          type: "string",
          description: "Second preview-artifact path to diff against artifact_a."
        }
      }),
      [:artifact_a, :artifact_b]
    )
  end

  @doc false
  def playback_props do
    Tool.object(
      Map.merge(workspace_props(), %{
        artifact_path: %{
          type: "string",
          description:
            "Recording artifact path returned by preview_record_stop, for example " <>
              "/preview-artifacts/ws-1/rec-123.webm. A full artifact URL is accepted " <>
              "but only its path is used."
        },
        tmux_session: Params.tmux_session(),
        actor_id: Params.actor_id(),
        assignment_id: Params.assignment_id(),
        anchor_pane_id: %{type: "string"},
        anchor_window_id: %{type: "string"},
        placement: %{type: "string"},
        viewport: %{type: "string"},
        loop: %{
          type: "boolean",
          default: true,
          description: "When true, the playback video loops in the opened preview pane."
        }
      }),
      [:workspace_id, :artifact_path]
    )
  end

  @doc false
  def observe_pane_limit_param do
    %{type: "integer", minimum: 1, maximum: 50}
  end

  @doc false
  def elements_query_param do
    %{
      type: "string",
      description: "Optional case-insensitive filter over role, name, and selector."
    }
  end

  @doc false
  def reload_reason_param, do: %{type: "string"}

  @doc false
  def navigate_path_param, do: %{type: "string"}

  @doc false
  def pane_id_param, do: %{type: "string"}

  @doc false
  def workspace_schema_fields do
    [
      workspace_id: [type: :string],
      workspace_path: [type: :string]
    ]
  end

  @doc false
  def open_schema_fields do
    workspace_schema_fields() ++
      [
        tmux_session: [type: :string],
        surface: [type: :string],
        actor_id: [type: :string],
        assignment_id: [type: :string],
        port: [type: {:or, [:integer, :string]}],
        path: [type: :string],
        mode: [type: :string],
        anchor_pane_id: [type: :string],
        anchor_window_id: [type: :string],
        placement: [type: :string],
        viewport: [type: :string],
        new_control_session: [type: :boolean],
        force_new_pane: [type: :boolean],
        share_session: [type: :boolean],
        attach_to_pane_id: [type: :string],
        isolation_key: [type: :string],
        storage_profile: [type: :string],
        storage_profile_name: [type: :string],
        runtime_id: [type: :string],
        runtime_required: [type: :boolean],
        cwd: [type: :string],
        default_headers: [type: :map],
        loop: [type: :boolean]
      ]
  end

  @doc false
  def session_schema_fields do
    [session_id: [type: {:or, [:integer, :string]}]]
  end

  @doc false
  def mutation_schema_fields do
    session_schema_fields() ++
      [
        element_id: [type: :string],
        selector: [type: :string],
        nth: [type: :integer],
        x: [type: {:or, [:integer, :float]}],
        y: [type: {:or, [:integer, :float]}],
        text: [type: :string],
        key: [type: :string],
        allow_headless: [type: :boolean],
        diff: [type: :boolean]
      ]
  end


  def metadata(name)
       when name in [
              "preview_resolve_workspace",
              "preview_surfaces",
              "preview_observe_pane",
              "preview_observe",
              "preview_observe_live",
              "preview_elements",
              "preview_screenshot",
              "preview_get_storage",
              "preview_report_errors"
            ] do
    %{
      mutation?: false,
      danger_level: :low,
      capabilities: [:preview_read],
      recovery_hints: ["Call preview_surfaces before opening when the target surface is unclear."]
    }
  end

  def metadata(name)
       when name in [
              "preview_open",
              "preview_open_current_workspace",
              "preview_open_here",
              "preview_ensure_server_here",
              "preview_open_app",
              "preview_open_localhost"
            ] do
    %{
      mutation?: true,
      danger_level: :medium,
      capabilities: [:preview_control],
      policy_tags: [:opens_preview_surface],
      recovery_hints: [
        "Use preview_surfaces to choose a surface or port.",
        "Use preview_observe or preview_observe_live with the returned session_id."
      ],
      examples: [
        %{
          arguments: %{"workspace_id" => "ws-1", "mode" => "app"},
          structured_content: %{"session_id" => 123}
        }
      ]
    }
  end

  def metadata(name)
       when name in [
              "preview_navigate",
              "preview_navigate_pane",
              "preview_click",
              "preview_type",
              "preview_press",
              "preview_reload_iframe",
              "devide_reload_page"
            ] do
    %{
      mutation?: true,
      danger_level: :medium,
      capabilities: [:preview_control],
      policy_tags: [:visible_preview_mutation],
      recovery_hints: ["Use preview_observe_live after UI actions to verify the hydrated state."]
    }
  end

  def metadata("preview_clear_storage") do
    %{
      mutation?: true,
      danger_level: :high,
      capabilities: [:preview_storage],
      policy_tags: [:storage_mutation],
      recovery_hints: [
        "Use preview_get_storage before clearing when storage state needs inspection."
      ]
    }
  end

  def metadata(name) when name in ["preview_record_start", "preview_record_stop"] do
    %{
      mutation?: true,
      danger_level: :low,
      capabilities: [:preview_control],
      policy_tags: [:records_preview_session],
      recovery_hints: [
        "preview_record_start before driving the flow; preview_record_stop to finalize.",
        "Recording captures the headless agent session, not a human's on-screen view."
      ]
    }
  end

  def metadata("preview_playback_open") do
    %{
      mutation?: true,
      danger_level: :low,
      capabilities: [:preview_control],
      policy_tags: [:opens_preview_surface, :plays_recording_artifact],
      recovery_hints: [
        "Call preview_record_stop first and pass the returned artifact_path.",
        "Use preview_observe_pane with the returned pane_id to inspect the playback surface."
      ]
    }
  end

  def metadata("preview_close") do
    %{
      mutation?: true,
      danger_level: :low,
      capabilities: [:preview_control],
      policy_tags: [:closes_preview_surface],
      recovery_hints: ["Prefer pane_id when cleaning up a visible or stale preview pane."]
    }
  end

  def metadata(_name), do: %{}

  @spec to_impl_args(term()) :: map()
  def to_impl_args(%{__struct__: _} = params), do: to_impl_args(Map.from_struct(params))

  def to_impl_args(params) when is_map(params) do
    Map.new(params, fn {key, value} -> {to_string(key), value} end)
  end
end
