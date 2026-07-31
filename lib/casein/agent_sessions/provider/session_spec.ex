defmodule Casein.AgentSessions.Provider.SessionSpec do
  @moduledoc """
  What a caller asks for when starting an agent session.

  Deliberately thin. Anything runtime-specific rides in `opts` so adding a
  provider does not widen this struct — the struct is the shared vocabulary, not
  a union of every runtime's options.

  `workspace_mode` is carried explicitly rather than left to `opts` because it
  is a **sandbox boundary**: `Casein.Codex.AppServer.security_defaults/1` maps it
  to `approvalPolicy` and `sandbox`, where `:unrestricted` means
  `danger-full-access`. A mode that goes missing in transit does not fail
  loudly — it silently changes what the agent may do. Making it a named,
  required-by-convention field keeps it visible at every call site.
  """

  @enforce_keys [:workspace_id, :cwd]
  defstruct [
    :workspace_id,
    :cwd,
    :workspace_mode,
    :session_id,
    :runtime_id,
    opts: []
  ]

  @type t :: %__MODULE__{
          workspace_id: String.t(),
          cwd: String.t(),
          workspace_mode: atom() | nil,
          session_id: String.t() | nil,
          runtime_id: String.t() | nil,
          opts: keyword()
        }

  @doc """
  Build a spec.

  `workspace_id` and `cwd` are required. `workspace_mode` defaults to `:manual`,
  matching `security_defaults/1`'s own default, so an omitted mode lands on the
  conservative `on-request` / `workspace-write` pair rather than anything
  permissive.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(%{} = attrs) do
    workspace_id = fetch_required(attrs, :workspace_id)
    cwd = fetch_required(attrs, :cwd)

    %__MODULE__{
      workspace_id: workspace_id,
      cwd: cwd,
      workspace_mode: Map.get(attrs, :workspace_mode) || :manual,
      session_id: Map.get(attrs, :session_id),
      runtime_id: Map.get(attrs, :runtime_id),
      opts: Map.get(attrs, :opts, [])
    }
  end

  @doc "True when the spec asks to resume an existing session rather than create one."
  @spec resume?(t()) :: boolean()
  def resume?(%__MODULE__{session_id: session_id}),
    do: is_binary(session_id) and session_id != ""

  defp fetch_required(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" ->
        value

      other ->
        raise ArgumentError,
              "#{inspect(key)} must be a non-empty binary, got: #{inspect(other)}"
    end
  end
end
