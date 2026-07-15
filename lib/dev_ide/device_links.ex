defmodule DevIDE.DeviceLinks do
  @moduledoc """
  Persistent links between an external device and a domain resource.

  DevIDE currently issues links for workspace-scoped mobile companion access,
  but the stored shape is intentionally origin/resource based so other domains
  can reuse the same bootstrap-and-exchange pattern.
  """

  import Ecto.Query

  alias DevIDE.DeviceLinks.Token
  alias DevIDE.Repo
  alias DevIDE.Workspaces

  @origin_id "dev_ide"
  @origin_name "DevIDE"
  @resource_kind "workspace"
  @capabilities [
    "phoenix_socket",
    "dev_ide.session",
    "dev_ide.mobile_cards"
  ]

  @type exchange_result :: %{
          token: String.t(),
          link: Token.t(),
          workspace: map(),
          capabilities: [String.t()]
        }

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
      raw_token = generate_token()

      now = DateTime.utc_now()

      token_attrs = %{
        origin_id: @origin_id,
        origin_name: @origin_name,
        subject_id: user.id,
        subject_email: user.email,
        subject_role: role_to_string(user.role),
        token_hash: token_hash(raw_token),
        resource_kind: @resource_kind,
        resource_id: workspace_id,
        resource_label: workspace_label(workspace),
        capabilities: @capabilities,
        device_name: optional_string(attrs, :device_name),
        platform: optional_string(attrs, :platform),
        expires_at: DateTime.add(now, ttl_seconds(), :second)
      }

      case %Token{} |> Token.changeset(token_attrs) |> Repo.insert() do
        {:ok, link} ->
          {:ok,
           %{token: raw_token, link: link, workspace: workspace, capabilities: @capabilities}}

        {:error, changeset} ->
          {:error, changeset}
      end
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
    Application.get_env(:dev_ide, :device_link_ttl_seconds, 60 * 60 * 24 * 90)
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

  defp role_to_string(:admin), do: "admin"
  defp role_to_string("admin"), do: "admin"
  defp role_to_string(_role), do: "owner"

  defp role_atom("admin"), do: :admin
  defp role_atom(_role), do: :owner
end
