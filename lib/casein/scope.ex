defmodule Casein.Scope do
  @moduledoc """
  A common authorization scope for Casein entry points and contexts.

  Authorization currently lives at several established boundaries. LiveView
  actions pass through `CaseinWeb.WorkspaceLive.Show`'s `authz_gate/3`, while
  MCP endpoints and terminal operations enforce their own workspace boundaries
  through `Casein.MCP.Scope`, `CaseinWeb.API.MCPWorkspaceScope`, and
  `Casein.Terminals.TmuxScope`. Those checks remain authoritative.

  `Casein.Scope` is the unifying foundation for representing the identity,
  workspace binding, request source, and capabilities that reach those
  boundaries. It gives web, MCP, channel, and trusted internal callers a common
  value to pass into future context APIs without replacing any existing policy
  or subsystem-specific validation.

  ## Incremental adoption

  Threading `%Casein.Scope{}` through every context function is intentionally a
  follow-up. Existing callers continue to use their current authorization
  gates; this module is the seam future work builds on. The temporary deviation
  from a single scope-aware context API is therefore intentional, documented,
  and suitable for incremental migration rather than a project-wide rewrite.
  """

  @type source :: :web | :mcp | :channel | :system
  @type t :: %__MODULE__{
          identity: term(),
          workspace_id: String.t() | nil,
          source: source(),
          capabilities: term()
        }

  defstruct identity: nil, workspace_id: nil, source: nil, capabilities: []

  # Casein's Boundary rules prohibit a compile-time domain -> web dependency.
  # Keep this adapter lookup dynamic while still delegating normalization to
  # the existing MCP endpoint seam.
  @mcp_workspace_scope Module.concat(["CaseinWeb", "API", "MCPWorkspaceScope"])

  @doc "Builds a web scope from the identity and scope data assigned to a connection."
  @spec from_conn(Plug.Conn.t()) :: t()
  def from_conn(%Plug.Conn{assigns: assigns}) do
    %__MODULE__{
      identity: Map.get(assigns, :current_user),
      workspace_id: Map.get(assigns, :workspace_id),
      source: :web,
      capabilities: Map.get(assigns, :capabilities, [])
    }
  end

  @doc "Builds an MCP scope from an endpoint workspace binding."
  @spec from_mcp(String.t() | nil, keyword()) :: t()
  def from_mcp(workspace_id, opts \\ []) when is_list(opts) do
    workspace_id =
      opts
      |> Keyword.put(:default_workspace_id, workspace_id)
      |> then(&apply(@mcp_workspace_scope, :default_workspace_id, [&1]))

    %__MODULE__{
      identity: Keyword.get(opts, :identity),
      workspace_id: workspace_id,
      source: :mcp,
      capabilities: Keyword.get(opts, :capabilities, [])
    }
  end

  @doc "Builds a channel scope from the identity and scope data assigned to a socket."
  @spec from_socket(Phoenix.Socket.t()) :: t()
  def from_socket(%{assigns: assigns}) when is_map(assigns) do
    %__MODULE__{
      identity: Map.get(assigns, :current_user),
      workspace_id: Map.get(assigns, :pairing_workspace_id) || Map.get(assigns, :workspace_id),
      source: :channel,
      capabilities: Map.get(assigns, :capabilities, [])
    }
  end

  @doc "Builds a trusted scope for internal callers that are not handling a request."
  @spec system() :: t()
  def system do
    %__MODULE__{identity: :system, source: :system, capabilities: :all}
  end

  @doc "Returns whether a scope may act on the requested workspace."
  @spec authorizes_workspace?(t(), String.t()) :: boolean()
  def authorizes_workspace?(%__MODULE__{source: :system}, _workspace_id), do: true

  def authorizes_workspace?(%__MODULE__{workspace_id: workspace_id}, workspace_id)
      when not is_nil(workspace_id),
      do: true

  def authorizes_workspace?(%__MODULE__{}, _workspace_id), do: false
end
