defmodule DevIDE.Agents.AnnotationTools.Helpers do
  @moduledoc """
  Shared JSON-Schema fragments and MCP metadata for annotation tool actions.
  """

  alias McpCtl.{Params, Tool}

  @default_limit 20
  @max_limit 100

  @doc false
  def workspace_props, do: Params.terminal_workspace_props()

  @doc false
  def limit_param do
    %{
      type: "integer",
      description: "Maximum annotations to return (default #{@default_limit}, max #{@max_limit})."
    }
  end

  @doc false
  def approval_state_param do
    %{
      type: "string",
      enum: ["pending", "approved", "rejected"],
      description: "Filter by approval state."
    }
  end

  @doc false
  def author_type_param do
    %{
      type: "string",
      enum: ["human", "agent_grok", "agent_codex", "agent_claude"]
    }
  end

  @doc false
  def visibility_param do
    %{
      type: "string",
      enum: ["private", "shared", "per_agent"],
      description: "Defaults to shared for agent proposals."
    }
  end

  @doc false
  def metadata("annotation_list") do
    %{
      mutation?: false,
      danger_level: :low,
      capabilities: [:terminal_read],
      recovery_hints: ["Call terminal_list_sessions first when session is unknown."]
    }
  end

  def metadata("annotation_propose") do
    %{
      mutation?: true,
      danger_level: :low,
      capabilities: [:annotation_write],
      policy_tags: [:human_review],
      recovery_hints: [
        "Include at least one anchor such as file_path, terminal_range, or preview_id."
      ]
    }
  end

  def metadata(_name), do: %{}

  @doc false
  def list_parameters do
    Tool.object(
      Map.merge(workspace_props(), %{
        limit: limit_param(),
        approval_state: approval_state_param(),
        file_path: %{type: "string"},
        session_id: %{type: "string"},
        pane_id: Params.pane()
      }),
      ["workspace_id"]
    )
  end

  @doc false
  def propose_parameters do
    Tool.object(
      Map.merge(workspace_props(), %{
        content: %{type: "string"},
        author_type: author_type_param(),
        visibility: visibility_param(),
        session_id: %{type: "string"},
        pane_id: Params.pane(),
        preview_id: %{type: "string"},
        file_path: %{type: "string"},
        file_range: %{type: "object"},
        terminal_range: %{type: "object"},
        linked_entities: %{type: "array", items: %{type: "object"}},
        metadata: %{type: "object"},
        actor_id: Params.actor_id()
      }),
      ["workspace_id", "content", "author_type"]
    )
  end

  @spec to_impl_args(term()) :: map()
  def to_impl_args(%{__struct__: _} = params), do: to_impl_args(Map.from_struct(params))

  def to_impl_args(params) when is_map(params) do
    Map.new(params, fn {key, value} -> {to_string(key), value} end)
  end
end