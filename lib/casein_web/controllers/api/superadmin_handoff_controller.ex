defmodule CaseinWeb.API.SuperadminHandoffController do
  @moduledoc "Browser handoff and forward-auth bridge for the OneBackend superadmin shell."

  use CaseinWeb, :controller

  alias Casein.Workspaces
  alias Casein.Agents.TerminalTools
  alias Casein.Identity
  alias Casein.Terminals
  alias CaseinWeb.Plugs.ForwardAuth
  alias CaseinWeb.SuperadminHandoff

  @session_key "current_user"

  @spec exchange(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def exchange(conn, %{"token" => token}) do
    with {:ok, claims} <- SuperadminHandoff.verify(token),
         {:ok, workspace} <- Workspaces.get(claims["workspace_id"]),
         user <- ForwardAuth.user_from_email(claims["email"]),
         true <- Workspaces.viewer_can_access_workspace?(workspace, user),
         :ok <- bind_session(claims, workspace, user) do
      conn
      |> put_session(@session_key, user)
      |> put_session("superadmin_handoff", true)
      |> redirect(to: workspace_path(claims))
    else
      _ -> unauthorized(conn)
    end
  end

  def exchange(conn, _), do: unauthorized(conn)
  @spec current(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def current(conn, _params) do
    conn = fetch_query_params(conn)
    workspace_id = conn.assigns[:api_workspace_id] || conn.query_params["workspace_id"]

    with workspace_id when is_binary(workspace_id) and workspace_id != "" <- workspace_id,
         assertion when is_binary(assertion) <- actor_assertion(conn),
         {:ok, claims} <- SuperadminHandoff.verify_actor(assertion),
         true <- claims["workspace_id"] == workspace_id,
         {:ok, workspace} <- Workspaces.get(workspace_id),
         user <- ForwardAuth.user_from_email(claims["email"]),
         true <- Workspaces.viewer_can_access_workspace?(workspace, user),
         principal when is_binary(principal) <- identity_principal(user),
         {:ok, payload} <- TerminalTools.list_sessions(%{"workspace_id" => workspace_id}) do
      sessions = Map.get(payload, :sessions) || Map.get(payload, "sessions") || []
      bound = Enum.filter(sessions, &(session_actor(&1) == principal))
      bootstrap = if bound == [], do: Enum.filter(sessions, &bootstrap_session?/1), else: []

      json(conn, %{
        workspace_id: workspace_id,
        identity: %{principal: principal, email: claims["email"]},
        session_scope: "identity",
        sessions: bound,
        bootstrap_sessions: bootstrap
      })
    else
      _ -> unauthorized(conn)
    end
  end

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    with :ok <- require_global_operator_token(conn),
         "v3" <- Map.get(params, "kind", "v3"),
         workspace_id when is_binary(workspace_id) and workspace_id != "" <-
           Map.get(params, "workspace_id"),
         assertion when is_binary(assertion) <- actor_assertion(conn),
         {:ok, claims} <- SuperadminHandoff.verify_actor(assertion),
         true <- claims["workspace_id"] == workspace_id,
         {:ok, workspace} <- Workspaces.get(workspace_id),
         user <- ForwardAuth.user_from_email(claims["email"]),
         true <- Workspaces.viewer_can_access_workspace?(workspace, user),
         principal when is_binary(principal) <- identity_principal(user),
         {:ok, cwd} <- workspace_cwd(workspace),
         label <- Map.get(params, "label"),
         {:ok, session} <- provision_session(workspace, cwd, principal, label) do
      json(conn, %{
        workspace_id: workspace_id,
        identity: %{principal: principal, email: claims["email"]},
        session_scope: "identity",
        session: session
      })
    else
      {:error, :operator_token_required} ->
        conn |> put_status(:forbidden) |> json(%{error: "operator_token_required"})

      {:error, :workspace_path_unavailable} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "workspace_path_unavailable"})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})

      _ ->
        unauthorized(conn)
    end
  end

  @spec rename(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def rename(conn, %{"session_id" => session_id} = params) do
    conn = fetch_query_params(conn)
    workspace_id = conn.assigns[:api_workspace_id] || params["workspace_id"]

    with :ok <- require_global_operator_token(conn),
         workspace_id when is_binary(workspace_id) and workspace_id != "" <- workspace_id,
         {:ok, label} <- normalize_requested_session_alias(Map.get(params, "label")),
         assertion when is_binary(assertion) <- actor_assertion(conn),
         {:ok, claims} <- SuperadminHandoff.verify_actor(assertion),
         true <- claims["workspace_id"] == workspace_id,
         {:ok, workspace} <- Workspaces.get(workspace_id),
         user <- ForwardAuth.user_from_email(claims["email"]),
         true <- Workspaces.viewer_can_access_workspace?(workspace, user),
         principal when is_binary(principal) <- identity_principal(user),
         true <- Terminals.tmux_session_in_workspace?(session_id, workspace),
         adapter <- Terminals.tmux_adapter(),
         {:ok, session} <- find_session(adapter, session_id),
         ^principal <- session_actor(session),
         :ok <- set_session_alias(adapter, session_id, label) do
      json(conn, %{
        workspace_id: workspace_id,
        identity: %{principal: principal, email: claims["email"]},
        session_scope: "identity",
        session: Map.put(session, :session_alias, label)
      })
    else
      {:error, :operator_token_required} ->
        conn |> put_status(:forbidden) |> json(%{error: "operator_token_required"})

      {:error, :invalid_session_alias} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid_session_alias"})

      _ ->
        unauthorized(conn)
    end
  end

  def rename(conn, _params), do: unauthorized(conn)

  @spec authz(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def authz(conn, _params) do
    case get_session(conn, @session_key) do
      %{email: email} when is_binary(email) and email != "" ->
        conn
        |> put_resp_header("x-auth-request-email", email)
        |> send_resp(204, "")

      %{"email" => email} when is_binary(email) and email != "" ->
        conn
        |> put_resp_header("x-auth-request-email", email)
        |> send_resp(204, "")

      _ ->
        unauthorized(conn)
    end
  end

  defp actor_assertion(conn) do
    case get_req_header(conn, "x-onebackend-actor-assertion") do
      [assertion | _] -> assertion
      _ -> nil
    end
  end

  defp require_global_operator_token(%{assigns: %{api_token_scope: :global}}), do: :ok
  defp require_global_operator_token(_conn), do: {:error, :operator_token_required}

  defp workspace_cwd(workspace) do
    case Workspaces.safe_host_path(workspace) do
      {:ok, cwd} when is_binary(cwd) and cwd != "" -> {:ok, cwd}
      _ -> {:error, :workspace_path_unavailable}
    end
  end

  defp provision_session(workspace, cwd, principal, requested_label) do
    sid = "v3-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    adapter = Terminals.tmux_adapter()

    with {:ok, workspace_name} <- workspace_name(workspace),
         tmux_session <- Terminals.tmux_session_name(workspace_name, sid),
         {:ok, session_alias} <- requested_session_alias(requested_label, principal, sid),
         :ok <- reject_existing_session(adapter, tmux_session),
         :ok <- adapter.ensure_session(tmux_session, cwd) do
      case bind_session(adapter, tmux_session, principal, session_alias) do
        :ok ->
          {:ok,
           %{
             session: tmux_session,
             session_alias: session_alias,
             actor: principal,
             attached: false,
             activity: System.system_time(:second),
             status: "idle",
             role: "v3"
           }}

        {:error, reason} ->
          _ = adapter.kill(tmux_session)
          {:error, reason}

        other ->
          _ = adapter.kill(tmux_session)
          {:error, other}
      end
    else
      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, other}
    end
  end

  defp workspace_name(workspace) do
    case Map.get(workspace, :name) || Map.get(workspace, "name") || Map.get(workspace, :id) do
      name when is_binary(name) and name != "" -> {:ok, name}
      _ -> {:error, :workspace_name_unavailable}
    end
  end

  defp reject_existing_session(adapter, tmux_session) do
    if function_exported?(adapter, :session_exists?, 1) and adapter.session_exists?(tmux_session) do
      {:error, :session_already_exists}
    else
      :ok
    end
  end

  defp bind_session(adapter, tmux_session, principal, session_alias) do
    with :ok <- set_session_actor(adapter, tmux_session, principal) do
      set_session_alias(adapter, tmux_session, session_alias)
    end
  end

  defp set_session_actor(adapter, tmux_session, principal) do
    if function_exported?(adapter, :set_session_actor, 2) do
      adapter.set_session_actor(tmux_session, principal)
    else
      {:error, :session_actor_unsupported}
    end
  end

  defp set_session_alias(adapter, tmux_session, session_alias) do
    if function_exported?(adapter, :set_session_alias, 2) do
      adapter.set_session_alias(tmux_session, session_alias)
    else
      {:error, :session_alias_unsupported}
    end
  end

  defp session_alias(principal, sid) do
    principal =
      principal
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9._-]/, "-")
      |> String.trim("-")
      |> String.slice(0, 24)

    principal = if principal == "", do: "operator", else: principal
    "v3-#{principal}-#{String.replace_prefix(sid, "v3-", "")}"
  end

  defp requested_session_alias(nil, principal, sid), do: {:ok, session_alias(principal, sid)}

  defp requested_session_alias(label, _principal, _sid) when is_binary(label) do
    normalize_requested_session_alias(label)
  end

  defp requested_session_alias(_, _, _), do: {:error, :invalid_session_alias}

  defp normalize_requested_session_alias(label) when is_binary(label) do
    label = String.trim(label)

    cond do
      label == "" ->
        {:error, :invalid_session_alias}

      String.length(label) > 80 ->
        {:error, :invalid_session_alias}

      String.contains?(label, "\n") or String.contains?(label, "\r") ->
        {:error, :invalid_session_alias}

      true ->
        {:ok, label}
    end
  end

  defp normalize_requested_session_alias(_), do: {:error, :invalid_session_alias}

  defp identity_principal(user), do: Identity.resolve(viewer: user, env: false).principal

  defp session_actor(session) when is_map(session) do
    Map.get(session, :actor) || Map.get(session, "actor")
  end

  defp session_actor(_), do: nil

  defp bootstrap_session?(session) when is_map(session) do
    session_actor(session) in [nil, ""] and
      (Map.get(session, :role) || Map.get(session, "role")) == "operator_candidate"
  end

  defp bootstrap_session?(_), do: false

  defp bind_session(
         %{"workspace_id" => workspace_id, "tmux_session" => tmux_session},
         workspace,
         user
       )
       when is_binary(workspace_id) and is_binary(tmux_session) do
    adapter = Terminals.tmux_adapter()

    with principal when is_binary(principal) <- identity_principal(user),
         true <- Terminals.tmux_session_in_workspace?(tmux_session, workspace),
         true <- adapter.session_exists?(tmux_session),
         {:ok, session} <- find_session(adapter, tmux_session),
         :ok <- bind_actor(adapter, tmux_session, session, principal) do
      :ok
    else
      _ -> {:error, :invalid_session_binding}
    end
  end

  defp bind_session(_, _, _), do: {:error, :invalid_session_binding}

  defp find_session(adapter, tmux_session) do
    case Enum.find(adapter.list_sessions(), fn session ->
           (Map.get(session, :session) || Map.get(session, "session")) == tmux_session
         end) do
      nil -> {:error, :session_not_found}
      session -> {:ok, session}
    end
  end

  defp bind_actor(adapter, tmux_session, session, principal) do
    case session_actor(session) do
      actor when actor in [nil, ""] ->
        if function_exported?(adapter, :set_session_actor, 2) do
          adapter.set_session_actor(tmux_session, principal)
        else
          {:error, :session_actor_unsupported}
        end

      ^principal ->
        :ok

      _ ->
        {:error, :session_owned_by_another_actor}
    end
  end

  defp workspace_path(claims) do
    "/workspaces/" <>
      URI.encode_www_form(claims["workspace_id"]) <>
      "?" <>
      URI.encode_query(%{
        "session" => claims["session_id"],
        "surface" => "terminal",
        "tmux_session" => claims["tmux_session"]
      })
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(401, "Not authenticated")
    |> halt()
  end
end
