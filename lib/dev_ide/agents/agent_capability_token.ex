defmodule DevIDE.Agents.AgentCapabilityToken do
  @moduledoc """
  A short-lived, session-bound bearer credential for a managed agent runtime.

  Only the SHA-256 token hash is persisted. Session, workspace, mode, bundle,
  and exact tool grants are immutable claims captured when the token is minted.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @identifier ~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{0,239}\z/
  @leader_id ~r/\A[0-9a-f]{24}\z/
  @pane_id ~r/\A%[0-9]+\z/
  @digest ~r/\A[0-9a-f]{64}\z/
  @tool_name ~r/\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,119}\z/
  @surfaces ~w(terminal preview artifact)
  @workspace_modes ~w(manual review agent_write_locked shared_stage_guarded)
  @max_tools_per_surface 128
  @max_total_tools 256

  @type t :: %__MODULE__{}

  schema "agent_capability_tokens" do
    field :token_hash, :string
    field :workspace_id, :string
    field :runtime, :string
    field :tmux_session_id, :string
    field :pane_id, :string
    field :leader_id, :string
    field :bundle_digest, :string
    field :workspace_mode, :string
    field :allowed_tools, :map, default: %{}
    field :checkout_digest, :string
    field :revoked_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(token, attrs) do
    token
    |> cast(attrs, [
      :token_hash,
      :workspace_id,
      :runtime,
      :tmux_session_id,
      :pane_id,
      :leader_id,
      :bundle_digest,
      :workspace_mode,
      :allowed_tools,
      :checkout_digest,
      :revoked_at,
      :last_seen_at,
      :expires_at
    ])
    |> validate_required([
      :token_hash,
      :workspace_id,
      :runtime,
      :tmux_session_id,
      :pane_id,
      :leader_id,
      :bundle_digest,
      :workspace_mode,
      :allowed_tools,
      :expires_at
    ])
    |> validate_length(:token_hash, max: 96)
    |> validate_format(:workspace_id, @identifier)
    |> validate_inclusion(:runtime, ["grok"])
    |> validate_format(:tmux_session_id, @identifier)
    |> validate_format(:pane_id, @pane_id)
    |> validate_format(:leader_id, @leader_id)
    |> validate_format(:bundle_digest, @digest)
    |> validate_inclusion(:workspace_mode, @workspace_modes)
    |> validate_allowed_tools()
    |> validate_format(:checkout_digest, @digest)
    |> unique_constraint(:token_hash)
    |> unique_constraint(:leader_id, name: :agent_capability_tokens_active_leader_index)
  end

  defp validate_allowed_tools(changeset) do
    if valid_allowed_tools?(get_field(changeset, :allowed_tools)) do
      changeset
    else
      add_error(
        changeset,
        :allowed_tools,
        "must grant exact tool names on terminal, preview, or artifact surfaces within size limits"
      )
    end
  end

  defp valid_allowed_tools?(tools) when is_map(tools) and map_size(tools) > 0 do
    surfaces = Map.keys(tools)
    tool_lists = Map.values(tools)

    length(surfaces) <= length(@surfaces) and
      Enum.all?(surfaces, &(&1 in @surfaces)) and
      Enum.all?(tool_lists, &valid_tool_list?/1) and
      Enum.sum(Enum.map(tool_lists, &length/1)) <= @max_total_tools
  end

  defp valid_allowed_tools?(_tools), do: false

  defp valid_tool_list?(tools)
       when is_list(tools) and tools != [] and length(tools) <= @max_tools_per_surface do
    length(Enum.uniq(tools)) == length(tools) and
      Enum.all?(tools, &(is_binary(&1) and Regex.match?(@tool_name, &1)))
  end

  defp valid_tool_list?(_tools), do: false
end
