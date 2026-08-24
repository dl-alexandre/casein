defmodule Casein.Agents.McpTickets do
  @moduledoc """
  Issues and atomically consumes short-lived MCP tickets.

  Tickets are opaque, hash-at-rest, single-use credentials bound to the
  presenting agent capability's workspace, one MCP surface, and an exact tool
  subset. Consumption locks the server-side row so concurrent replays have one
  winner.
  """

  import Ecto.Query

  alias Casein.Agents.McpTicket
  alias Casein.Repo

  @ticket_bytes 32
  @surfaces ~w(terminal preview artifact code)

  @type result :: %{
          ticket: String.t(),
          id: Ecto.UUID.t(),
          workspace_id: String.t(),
          surface: String.t(),
          scopes: [String.t()],
          expires_at: DateTime.t(),
          expires_in: pos_integer()
        }

  @doc "Issue a ticket containing only a requested subset of capability scopes."
  @spec issue(map(), String.t(), [String.t()]) ::
          {:ok, result()} | {:error, atom() | Ecto.Changeset.t()}
  def issue(claims, surface, scopes)
      when is_map(claims) and surface in @surfaces and is_list(scopes) do
    with {:ok, granted} <- granted_scopes(claims, surface),
         :ok <- validate_requested_subset(scopes, granted) do
      raw_ticket = generate_ticket()
      now = now()
      ttl = ttl_seconds()
      expires_at = DateTime.add(now, ttl, :second)

      attrs = %{
        ticket_hash: token_hash(raw_ticket),
        capability_id: claims.id,
        workspace_id: claims.workspace_id,
        surface: surface,
        scopes: scopes,
        runtime: claims.runtime,
        tmux_session_id: claims.tmux_session_id,
        pane_id: claims.pane_id,
        leader_id: claims.leader_id,
        bundle_digest: claims.bundle_digest,
        workspace_mode: claims.workspace_mode,
        checkout_digest: claims.checkout_digest,
        expires_at: expires_at
      }

      case %McpTicket{} |> McpTicket.changeset(attrs) |> Repo.insert() do
        {:ok, record} ->
          {:ok,
           %{
             ticket: raw_ticket,
             id: record.id,
             workspace_id: record.workspace_id,
             surface: record.surface,
             scopes: record.scopes,
             expires_at: record.expires_at,
             expires_in: ttl
           }}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  def issue(_claims, _surface, _scopes), do: {:error, :invalid_ticket_request}

  @doc "Atomically consume a ticket for the exact workspace and MCP surface."
  @spec consume(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def consume(raw_ticket, workspace_id, surface)
      when is_binary(raw_ticket) and is_binary(workspace_id) and surface in @surfaces do
    with :ok <- validate_ticket_shape(raw_ticket) do
      result =
        Repo.transaction(fn ->
          McpTicket
          |> where([ticket], ticket.ticket_hash == ^token_hash(String.trim(raw_ticket)))
          |> lock("FOR UPDATE")
          |> Repo.one()
          |> consume_record(workspace_id, surface, now())
          |> case do
            {:ok, record} -> record
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

      case result do
        {:ok, record} -> {:ok, claims(record)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def consume(_raw_ticket, _workspace_id, _surface), do: {:error, :invalid_ticket}

  @doc false
  def ttl_seconds, do: Application.fetch_env!(:casein, :mcp_ticket_ttl_seconds)

  @doc false
  def token_hash(raw_ticket) when is_binary(raw_ticket) do
    :crypto.hash(:sha256, raw_ticket) |> Base.url_encode64(padding: false)
  end

  defp consume_record(nil, _workspace_id, _surface, _now), do: {:error, :invalid_ticket}

  defp consume_record(%McpTicket{consumed_at: consumed_at}, _workspace_id, _surface, _now)
       when not is_nil(consumed_at),
       do: {:error, :ticket_replayed}

  defp consume_record(%McpTicket{} = record, workspace_id, surface, now) do
    cond do
      DateTime.compare(record.expires_at, now) != :gt ->
        {:error, :ticket_expired}

      record.workspace_id != workspace_id ->
        {:error, :ticket_workspace_mismatch}

      record.surface != surface ->
        {:error, :ticket_surface_mismatch}

      true ->
        record
        |> Ecto.Changeset.change(consumed_at: now)
        |> Repo.update()
    end
  end

  defp claims(record) do
    %{
      id: record.capability_id,
      ticket_id: record.id,
      workspace_id: record.workspace_id,
      surface: record.surface,
      runtime: record.runtime,
      tmux_session_id: record.tmux_session_id,
      pane_id: record.pane_id,
      leader_id: record.leader_id,
      bundle_digest: record.bundle_digest,
      workspace_mode: record.workspace_mode,
      allowed_tools: %{record.surface => record.scopes},
      checkout_digest: record.checkout_digest,
      expires_at: record.expires_at
    }
  end

  defp granted_scopes(%{allowed_tools: grants}, surface) when is_map(grants) do
    case Map.get(grants, surface) do
      scopes when is_list(scopes) -> {:ok, scopes}
      _ -> {:error, :surface_not_granted}
    end
  end

  defp granted_scopes(_claims, _surface), do: {:error, :invalid_capability_claims}

  defp validate_requested_subset(scopes, granted) do
    if scopes != [] and length(scopes) == length(Enum.uniq(scopes)) and
         Enum.all?(scopes, &(is_binary(&1) and &1 in granted)) do
      :ok
    else
      {:error, :scope_escalation}
    end
  end

  defp validate_ticket_shape(raw_ticket) do
    case String.trim(raw_ticket) do
      "mcptkt_" <> encoded when byte_size(encoded) == 43 ->
        if Regex.match?(~r/\A[A-Za-z0-9_-]{43}\z/, encoded),
          do: :ok,
          else: {:error, :invalid_ticket}

      _ ->
        {:error, :invalid_ticket}
    end
  end

  defp generate_ticket do
    "mcptkt_" <>
      (@ticket_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
  end

  defp now do
    case Application.fetch_env!(:casein, :mcp_ticket_clock) do
      fun when is_function(fun, 0) -> fun.()
      {module, function} -> apply(module, function, [])
    end
  end
end
