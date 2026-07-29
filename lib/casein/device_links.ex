defmodule Casein.DeviceLinks do
  @moduledoc """
  Persistent links between an external device and a domain resource.

  Casein currently issues links for workspace-scoped mobile companion access,
  but the stored shape is intentionally origin/resource based so other domains
  can reuse the same bootstrap-and-exchange pattern.
  """

  import Ecto.Query

  alias Casein.Audit
  alias Casein.DeviceLinks.PairingHandle
  alias Casein.DeviceLinks.Token
  alias Casein.Origin
  alias Casein.RateLimit
  alias Casein.Repo
  alias Casein.Workspaces

  @resource_kind "workspace"
  @pairing_audience "casein_mobile"
  @pairing_handle_bytes 32
  @default_pairing_handle_ttl_seconds 300
  @default_pairing_issue_scale_ms 60_000
  @default_pairing_issue_limit 20
  @capabilities [
    "phoenix_socket",
    "casein.session",
    "casein.mobile_cards"
  ]

  @type exchange_result :: %{
          token: String.t(),
          link: Token.t(),
          workspace: map(),
          capabilities: [String.t()]
        }

  @type pairing_handle_result :: %{
          handle: String.t(),
          expires_at: DateTime.t(),
          expires_in: pos_integer()
        }

  @doc """
  Issue a compact, single-use pairing handle for an authorized workspace.

  Refreshing the pairing page revokes any older unconsumed handle for the same
  user, origin, and workspace. The raw handle is returned once and is never
  stored or emitted to audit.
  """
  @spec issue_pairing_handle(map(), String.t(), String.t()) ::
          {:ok, pairing_handle_result()} | {:error, atom() | Ecto.Changeset.t()}
  def issue_pairing_handle(user, workspace_id, origin_base_url)
      when is_map(user) and is_binary(workspace_id) and is_binary(origin_base_url) do
    subject_id = map_value(user, :id)

    with :ok <- ensure_present(subject_id),
         :ok <- ensure_present(workspace_id),
         :ok <- Origin.authorize_request_base(origin_base_url),
         {:ok, workspace} <- Workspaces.get(workspace_id),
         :ok <- authorize_workspace(workspace, user),
         :ok <- allow_pairing_handle_issue(subject_id, workspace_id) do
      raw_handle = generate_pairing_handle()
      now = DateTime.utc_now()
      ttl = pairing_handle_ttl_seconds()
      expires_at = DateTime.add(now, ttl, :second)
      origin_base_url = Origin.public_base_url(origin_base_url)

      attrs = %{
        handle_hash: token_hash(raw_handle),
        origin_id: Origin.id(),
        origin_base_url: origin_base_url,
        subject_id: subject_id,
        subject_email: map_value(user, :email),
        subject_role: role_to_string(map_value(user, :role)),
        resource_kind: @resource_kind,
        resource_id: workspace_id,
        resource_label: workspace_label(workspace),
        capabilities: @capabilities,
        audience: @pairing_audience,
        expires_at: expires_at
      }

      case Repo.transaction(fn ->
             lock_pairing_handle_scope(attrs)
             revoke_superseded_pairing_handles(attrs, now)

             case %PairingHandle{} |> PairingHandle.changeset(attrs) |> Repo.insert() do
               {:ok, pending} -> pending
               {:error, changeset} -> Repo.rollback(changeset)
             end
           end) do
        {:ok, pending} ->
          audit_pairing_handle(pending, "mobile.pairing_handle.issued", :allow, :issued)
          {:ok, %{handle: raw_handle, expires_at: expires_at, expires_in: ttl}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def issue_pairing_handle(_user, _workspace_id, _origin_base_url),
    do: {:error, :invalid_pairing_claims}

  @doc """
  Atomically exchange a compact pairing handle for a durable device link.

  The pending row—not client input—owns user, workspace, capabilities, origin,
  audience, and expiry. A row lock ensures concurrent scans have one winner.
  """
  @spec exchange_pairing_handle(String.t(), String.t(), map()) ::
          {:ok, exchange_result()} | {:error, atom() | Ecto.Changeset.t()}
  def exchange_pairing_handle(raw_handle, request_base_url, attrs)
      when is_binary(raw_handle) and is_binary(request_base_url) and is_map(attrs) do
    with :ok <- validate_pairing_handle_shape(raw_handle),
         :ok <- Origin.authorize_request_base(request_base_url) do
      result =
        Repo.transaction(fn ->
          pending =
            PairingHandle
            |> where([h], h.handle_hash == ^token_hash(raw_handle))
            |> lock("FOR UPDATE")
            |> Repo.one()

          case pending do
            nil ->
              Repo.rollback(:invalid_pairing_handle)

            %PairingHandle{} = handle ->
              with :ok <- validate_pending_handle(handle, request_base_url, attrs),
                   {:ok, workspace} <- Workspaces.get(handle.resource_id),
                   :ok <- authorize_workspace(workspace, pairing_handle_user(handle)),
                   {:ok, exchange} <- create_from_pairing_handle(handle, workspace, attrs),
                   {:ok, consumed} <-
                     handle
                     |> Ecto.Changeset.change(consumed_at: DateTime.utc_now())
                     |> Repo.update() do
                {exchange, consumed}
              else
                {:error, reason} ->
                  Repo.rollback({reason, pairing_handle_audit_context(handle)})
              end
          end
        end)

      finish_pairing_handle_exchange(result)
    end
  end

  def exchange_pairing_handle(_raw_handle, _request_base_url, _attrs),
    do: {:error, :invalid_pairing_handle}

  @doc false
  def pairing_handle_ttl_seconds do
    Application.get_env(
      :casein,
      :device_link_pairing_handle_ttl_seconds,
      @default_pairing_handle_ttl_seconds
    )
  end

  @doc """
  Create a persistent device credential from already-verified pairing claims.

  The short-lived pairing token is verified by the web layer. This function
  re-checks resource access before issuing a durable token.
  """
  @spec create_from_pairing_claims(map(), map()) ::
          {:ok, exchange_result()} | {:error, atom() | Ecto.Changeset.t()}
  def create_from_pairing_claims(claims, attrs \\ %{})

  def create_from_pairing_claims(%{workspace_id: workspace_id} = claims, attrs)
      when is_binary(workspace_id) and is_map(attrs) do
    user = claims_to_user(claims)

    with :ok <- ensure_present(workspace_id),
         {:ok, workspace} <- Workspaces.get(workspace_id),
         :ok <- authorize_workspace(workspace, user) do
      create_persistent_link(
        user,
        workspace,
        workspace_id,
        attrs,
        @capabilities,
        Origin.id(),
        optional_string(attrs, :origin_name) || Origin.display_name()
      )
    end
  end

  def create_from_pairing_claims(_claims, _attrs), do: {:error, :invalid_pairing_claims}

  @doc "Verify a persistent device token and return socket-ready claims."
  @spec verify_token(String.t()) :: {:ok, map()} | {:error, atom()}
  def verify_token(raw_token) when is_binary(raw_token) do
    raw_token = String.trim(raw_token)

    if raw_token == "" do
      {:error, :missing}
    else
      raw_token
      |> token_hash()
      |> fetch_token()
      |> verify_record(DateTime.utc_now())
    end
  end

  def verify_token(_raw_token), do: {:error, :missing}

  @doc "Revoke a persistent device token."
  @spec revoke_token(String.t()) :: {:ok, Token.t()} | {:error, atom() | Ecto.Changeset.t()}
  def revoke_token(raw_token) when is_binary(raw_token) do
    case fetch_token(token_hash(raw_token)) do
      nil ->
        {:error, :not_found}

      %Token{} = token ->
        token
        |> Ecto.Changeset.change(revoked_at: DateTime.utc_now())
        |> Repo.update()
    end
  end

  def revoke_token(_raw_token), do: {:error, :missing}

  @doc "List non-revoked device links for a subject, newest activity first."
  @spec list_for_subject(String.t()) :: [Token.t()]
  def list_for_subject(subject_id) when is_binary(subject_id) do
    Token
    |> where([t], t.subject_id == ^subject_id and is_nil(t.revoked_at))
    |> order_by([t], desc: t.last_seen_at, desc: t.inserted_at)
    |> Repo.all()
  end

  @doc "Revoke all active device links for a subject. Returns the number revoked."
  @spec revoke_all_for_subject(String.t()) :: non_neg_integer()
  def revoke_all_for_subject(subject_id) when is_binary(subject_id) do
    now = DateTime.utc_now()

    {count, _} =
      Token
      |> where([t], t.subject_id == ^subject_id and is_nil(t.revoked_at))
      |> Repo.update_all(set: [revoked_at: now])

    count
  end

  @doc false
  def ttl_seconds do
    Application.get_env(:casein, :device_link_ttl_seconds, 60 * 60 * 24 * 90)
  end

  @doc """
  Rotate a persistent device token: verify the current credential, re-check the
  actor still owns the resource, mint a fresh token, and revoke the old one
  atomically. Returns the same shape as `create_from_pairing_claims/2`.
  """
  @spec rotate_token(String.t()) ::
          {:ok, exchange_result()} | {:error, atom() | Ecto.Changeset.t()}
  def rotate_token(raw_token) when is_binary(raw_token) do
    case String.trim(raw_token) do
      "" -> {:error, :missing}
      trimmed -> rotate_verified(fetch_token(token_hash(trimmed)))
    end
  end

  def rotate_token(_raw_token), do: {:error, :missing}

  defp rotate_verified(nil), do: {:error, :invalid_token}

  defp rotate_verified(%Token{} = current) do
    with :ok <- ensure_active(current, DateTime.utc_now()),
         {:ok, workspace} <- Workspaces.get(current.resource_id),
         :ok <- authorize_workspace(workspace, token_user(current)) do
      do_rotate(current, workspace)
    end
  end

  defp ensure_active(%Token{revoked_at: revoked_at}, _now) when not is_nil(revoked_at),
    do: {:error, :revoked}

  defp ensure_active(%Token{} = token, now) do
    if expired?(token, now), do: {:error, :expired}, else: :ok
  end

  defp token_user(%Token{} = token) do
    %{
      id: token.subject_id,
      username: token.subject_id,
      email: token.subject_email,
      role: role_atom(token.subject_role)
    }
  end

  defp do_rotate(%Token{} = current, workspace) do
    raw_token = generate_token()

    token_attrs = %{
      origin_id: current.origin_id,
      origin_name: current.origin_name,
      subject_id: current.subject_id,
      subject_email: current.subject_email,
      subject_role: current.subject_role,
      token_hash: token_hash(raw_token),
      resource_kind: current.resource_kind,
      resource_id: current.resource_id,
      resource_label: current.resource_label,
      capabilities: current.capabilities || @capabilities,
      device_name: current.device_name,
      platform: current.platform,
      expires_at: current.expires_at
    }

    Repo.transaction(fn ->
      with {:ok, link} <- %Token{} |> Token.changeset(token_attrs) |> Repo.insert(),
           {:ok, _revoked} <-
             current |> Ecto.Changeset.change(revoked_at: DateTime.utc_now()) |> Repo.update() do
        %{
          token: raw_token,
          link: link,
          workspace: workspace,
          capabilities: current.capabilities || @capabilities
        }
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc false
  def token_hash(raw_token) when is_binary(raw_token) do
    :crypto.hash(:sha256, raw_token)
    |> Base.url_encode64(padding: false)
  end

  defp generate_token do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp generate_pairing_handle do
    @pairing_handle_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp fetch_token(hash), do: Repo.get_by(Token, token_hash: hash)

  defp verify_record(nil, _now), do: {:error, :invalid_token}

  defp verify_record(%Token{revoked_at: revoked_at}, _now) when not is_nil(revoked_at),
    do: {:error, :revoked}

  defp verify_record(%Token{} = token, now) do
    if expired?(token, now) do
      {:error, :expired}
    else
      touch_last_seen(token, now)
      {:ok, claims(token)}
    end
  end

  defp expired?(%Token{expires_at: nil}, _now), do: false

  defp expired?(%Token{expires_at: expires_at}, now) do
    DateTime.compare(expires_at, now) != :gt
  end

  defp touch_last_seen(%Token{} = token, now) do
    token
    |> Ecto.Changeset.change(last_seen_at: now)
    |> Repo.update()
  end

  defp claims(%Token{} = token) do
    %{
      id: token.subject_id,
      username: token.subject_id,
      email: token.subject_email,
      role: role_atom(token.subject_role),
      origin_id: token.origin_id,
      origin_name: token.origin_name,
      device_link_id: token.id,
      platform: token.platform,
      resource_kind: token.resource_kind,
      resource_id: token.resource_id,
      workspace_id: workspace_id(token),
      capabilities: token.capabilities || []
    }
  end

  defp workspace_id(%Token{resource_kind: @resource_kind, resource_id: resource_id}),
    do: resource_id

  defp workspace_id(_token), do: nil

  defp claims_to_user(claims) do
    %{
      id: Map.get(claims, :id),
      username: Map.get(claims, :username) || Map.get(claims, :id),
      email: Map.get(claims, :email),
      role: Map.get(claims, :role, :owner)
    }
  end

  defp revoke_superseded_pairing_handles(attrs, now) do
    PairingHandle
    |> where(
      [h],
      h.origin_id == ^attrs.origin_id and h.subject_id == ^attrs.subject_id and
        h.resource_kind == ^attrs.resource_kind and h.resource_id == ^attrs.resource_id and
        is_nil(h.consumed_at) and is_nil(h.revoked_at)
    )
    |> Repo.update_all(set: [revoked_at: now])
  end

  defp lock_pairing_handle_scope(attrs) do
    scope =
      Enum.join(
        [
          attrs.origin_id,
          attrs.subject_id,
          attrs.resource_kind,
          attrs.resource_id
        ],
        ":"
      )

    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
      [scope]
    )
  end

  defp validate_pairing_handle_shape(raw_handle) do
    trimmed = String.trim(raw_handle)

    if byte_size(trimmed) == 43 and Regex.match?(~r/\A[A-Za-z0-9_-]{43}\z/, trimmed),
      do: :ok,
      else: {:error, :invalid_pairing_handle}
  end

  defp validate_pending_handle(%PairingHandle{} = handle, request_base_url, attrs) do
    now = DateTime.utc_now()
    supplied_origin = optional_string(attrs, :origin)
    supplied_audience = optional_string(attrs, :audience)
    supplied_workspace = optional_string(attrs, :workspace_id)
    supplied_subject = optional_string(attrs, :subject_id)
    request_origin = Origin.public_base_url(request_base_url)

    cond do
      not is_nil(handle.revoked_at) ->
        {:error, :pairing_handle_revoked}

      not is_nil(handle.consumed_at) ->
        {:error, :pairing_handle_replayed}

      DateTime.compare(handle.expires_at, now) != :gt ->
        {:error, :pairing_handle_expired}

      handle.audience != @pairing_audience or supplied_audience != @pairing_audience ->
        {:error, :pairing_handle_audience_mismatch}

      handle.origin_id != Origin.id() or handle.origin_base_url != request_origin ->
        {:error, :origin_mismatch}

      is_binary(supplied_origin) and supplied_origin != handle.origin_base_url ->
        {:error, :origin_mismatch}

      is_binary(supplied_workspace) and supplied_workspace != handle.resource_id ->
        {:error, :resource_mismatch}

      is_binary(supplied_subject) and supplied_subject != handle.subject_id ->
        {:error, :unauthorized}

      handle.resource_kind != @resource_kind ->
        {:error, :invalid_pairing_claims}

      true ->
        :ok
    end
  end

  defp pairing_handle_user(%PairingHandle{} = handle) do
    %{
      id: handle.subject_id,
      username: handle.subject_id,
      email: handle.subject_email,
      role: role_atom(handle.subject_role)
    }
  end

  defp create_from_pairing_handle(%PairingHandle{} = handle, workspace, attrs) do
    create_persistent_link(
      pairing_handle_user(handle),
      workspace,
      handle.resource_id,
      attrs,
      handle.capabilities,
      handle.origin_id,
      optional_string(attrs, :origin_name) || Origin.display_name(handle.origin_base_url)
    )
  end

  defp create_persistent_link(
         user,
         workspace,
         workspace_id,
         attrs,
         capabilities,
         origin_id,
         origin_name
       ) do
    raw_token = generate_token()
    now = DateTime.utc_now()

    token_attrs = %{
      origin_id: origin_id,
      origin_name: origin_name,
      subject_id: user.id,
      subject_email: user.email,
      subject_role: role_to_string(user.role),
      token_hash: token_hash(raw_token),
      resource_kind: @resource_kind,
      resource_id: workspace_id,
      resource_label: workspace_label(workspace),
      capabilities: capabilities,
      device_name: optional_string(attrs, :device_name),
      platform: optional_string(attrs, :platform),
      expires_at: DateTime.add(now, ttl_seconds(), :second)
    }

    case %Token{} |> Token.changeset(token_attrs) |> Repo.insert() do
      {:ok, link} ->
        {:ok, %{token: raw_token, link: link, workspace: workspace, capabilities: capabilities}}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp finish_pairing_handle_exchange({:ok, {exchange, consumed}}) do
    audit_pairing_handle(consumed, "mobile.pairing_handle.exchanged", :allow, :consumed)
    {:ok, exchange}
  end

  defp finish_pairing_handle_exchange({:error, {reason, context}}) do
    audit_pairing_handle_context(
      context,
      "mobile.pairing_handle.rejected",
      :deny,
      normalize_pairing_reason(reason)
    )

    {:error, reason}
  end

  defp finish_pairing_handle_exchange({:error, reason}), do: {:error, reason}

  defp pairing_handle_audit_context(%PairingHandle{} = handle) do
    %{
      id: handle.id,
      workspace_id: handle.resource_id,
      actor_id: handle.subject_id,
      origin_id: handle.origin_id,
      audience: handle.audience
    }
  end

  defp audit_pairing_handle(handle, action, decision, reason) do
    handle
    |> pairing_handle_audit_context()
    |> audit_pairing_handle_context(action, decision, reason)
  end

  defp audit_pairing_handle_context(context, action, decision, reason) do
    Audit.emit!(%{
      workspace_id: context.workspace_id,
      actor_id: context.actor_id,
      action: action,
      source: "mobile_pairing",
      target_type: "device_link_pairing_handle",
      target_ref: context.id,
      decision: decision,
      reason: reason,
      metadata: %{
        "origin_id" => context.origin_id,
        "audience" => context.audience
      }
    })
  end

  defp normalize_pairing_reason(reason) when is_atom(reason), do: reason
  defp normalize_pairing_reason(_reason), do: :rejected

  defp allow_pairing_handle_issue(subject_id, workspace_id) do
    scale =
      Application.get_env(
        :casein,
        :device_link_pairing_handle_issue_scale_ms,
        @default_pairing_issue_scale_ms
      )

    limit =
      Application.get_env(
        :casein,
        :device_link_pairing_handle_issue_limit,
        @default_pairing_issue_limit
      )

    key = "device_link_pairing_issue:#{Origin.id()}:#{subject_id}:#{workspace_id}"

    case RateLimit.hit(key, scale, limit) do
      {:allow, _count} -> :ok
      {:deny, _retry_after_ms} -> {:error, :rate_limited}
    end
  end

  defp authorize_workspace(workspace, user) do
    if Workspaces.viewer_terminal_owner?(workspace, user), do: :ok, else: {:error, :unauthorized}
  end

  defp ensure_present(value) when is_binary(value) do
    if String.trim(value) == "", do: {:error, :invalid_pairing_claims}, else: :ok
  end

  defp workspace_label(workspace) when is_map(workspace) do
    Map.get(workspace, :name) || Map.get(workspace, "name") ||
      Map.get(workspace, :id) || Map.get(workspace, "id")
  end

  defp optional_string(attrs, key) when is_map(attrs) do
    value = Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

    if is_binary(value) do
      value
      |> String.trim()
      |> case do
        "" -> nil
        text -> String.slice(text, 0, 120)
      end
    end
  end

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp role_to_string(:admin), do: "admin"
  defp role_to_string("admin"), do: "admin"
  defp role_to_string(_role), do: "owner"

  defp role_atom("admin"), do: :admin
  defp role_atom(_role), do: :owner
end
