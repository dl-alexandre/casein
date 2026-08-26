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
         true <- runtime_matches?(conn, claims),
         {:ok, workspace} <- Workspaces.get(claims["workspace_id"], claims["email"]),
         user <- ForwardAuth.user_from_email(claims["email"]),
         true <- Workspaces.viewer_can_access_workspace?(workspace, user),
         true <- workspace_owned_by?(workspace, claims["email"]),
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
         true <- runtime_matches?(conn, claims, require_header: true),
         true <- claims["workspace_id"] == workspace_id,
         {:ok, workspace} <- Workspaces.get(workspace_id, claims["email"]),
         true <- v3_workspace?(workspace),
         user <- ForwardAuth.user_from_email(claims["email"]),
         true <- Workspaces.viewer_can_access_workspace?(workspace, user),
         true <- workspace_owned_by?(workspace, claims["email"]),
         principal when is_binary(principal) <- identity_principal(user),
         {:ok, payload} <- TerminalTools.list_sessions(%{"workspace_id" => workspace_id}) do
      sessions = Map.get(payload, :sessions) || Map.get(payload, "sessions") || []
      visible = Enum.filter(sessions, &session_visible_to_principal?(&1, principal))
      bootstrap = if visible == [], do: Enum.filter(sessions, &bootstrap_session?/1), else: []

      json(conn, %{
        workspace_id: workspace_id,
        identity: %{principal: principal, email: claims["email"]},
        session_scope: "identity",
        sessions: visible,
        bootstrap_sessions: bootstrap
      })
    else
      _ -> unauthorized(conn)
    end
  end

  @spec inventory(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def inventory(conn, _params) do
    with :ok <- require_global_operator_token(conn),
         assertion when is_binary(assertion) <- actor_assertion(conn),
         {:ok, claims} <- SuperadminHandoff.verify_actor(assertion),
         true <- runtime_matches?(conn, claims, require_header: true),
         principal when is_binary(principal) <-
           identity_principal(ForwardAuth.user_from_email(claims["email"])),
         {:ok, workspaces} <- identity_v3_inventory(claims["email"], principal) do
      sessions =
        Enum.flat_map(workspaces, fn workspace ->
          workspace.sessions ++ workspace.bootstrap_sessions
        end)

      json(conn, %{
        identity: %{principal: principal, email: claims["email"]},
        session_scope: "identity",
        workspaces: workspaces,
        sessions: sessions
      })
    else
      {:error, :operator_token_required} ->
        conn |> put_status(:forbidden) |> json(%{error: "operator_token_required"})

      {:error, {:inventory_unavailable, reason}} ->
        conn |> put_status(:service_unavailable) |> json(%{error: inspect(reason)})

      _ ->
        unauthorized(conn)
    end
  end

  defp identity_v3_inventory(email, principal) do
    with {:ok, workspaces} <- Workspaces.list([], email),
         v3_workspaces <-
           Enum.filter(workspaces, fn workspace ->
             v3_workspace?(workspace) and workspace_owned_by?(workspace, email)
           end),
         {:ok, inventory} <- inventory_workspaces(v3_workspaces, principal) do
      {:ok, inventory}
    else
      {:error, reason} -> {:error, {:inventory_unavailable, reason}}
      other -> {:error, {:inventory_unavailable, other}}
    end
  end

  defp inventory_workspaces(workspaces, principal) do
    Enum.reduce_while(workspaces, {:ok, []}, fn workspace, {:ok, acc} ->
      case inventory_workspace(workspace, principal) do
        {:ok, entry} -> {:cont, {:ok, acc ++ [entry]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp inventory_workspace(workspace, principal) do
    workspace_id = Map.get(workspace, :id) || Map.get(workspace, "id")

    with workspace_id when is_binary(workspace_id) and workspace_id != "" <- workspace_id,
         {:ok, payload} <- TerminalTools.list_sessions(%{"workspace_id" => workspace_id}) do
      listed = payload_list(payload, "sessions")

      candidates =
        payload_list(payload, "candidate_sessions") ++ payload_list(payload, "bootstrap_sessions")

      visible = Enum.filter(listed, &session_visible_to_principal?(&1, principal))

      bootstrap =
        if visible == [], do: Enum.filter(candidates ++ listed, &bootstrap_session?/1), else: []

      {:ok,
       %{
         workspace_id: workspace_id,
         workspace_name: Map.get(workspace, :name) || workspace_id,
         workspace_type: "v3",
         workspace_status: workspace_status(workspace),
         sessions: Enum.map(visible, &enrich_inventory_session(&1, workspace)),
         bootstrap_sessions: Enum.map(bootstrap, &enrich_inventory_session(&1, workspace))
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_workspace}
    end
  end

  defp enrich_inventory_session(session, workspace) when is_map(session) do
    session
    |> Map.put_new(:workspace_id, Map.get(workspace, :id))
    |> Map.put_new(:workspace_name, Map.get(workspace, :name))
    |> Map.put_new(:workspace_type, "v3")
  end

  defp enrich_inventory_session(session, _), do: session

  defp payload_list(payload, "sessions") when is_map(payload),
    do: list_values(Map.get(payload, :sessions) || Map.get(payload, "sessions"))

  defp payload_list(payload, "candidate_sessions") when is_map(payload),
    do:
      list_values(Map.get(payload, :candidate_sessions) || Map.get(payload, "candidate_sessions"))

  defp payload_list(payload, "bootstrap_sessions") when is_map(payload),
    do:
      list_values(Map.get(payload, :bootstrap_sessions) || Map.get(payload, "bootstrap_sessions"))

  defp payload_list(_, _), do: []

  defp list_values(values) when is_list(values), do: Enum.filter(values, &is_map/1)
  defp list_values(_), do: []

  defp workspace_owned_by?(workspace, email) when is_map(workspace) and is_binary(email) do
    owner = Map.get(workspace, :user) || Map.get(workspace, "user")
    principal = email |> String.downcase() |> String.split("@", parts: 2) |> List.first()

    is_binary(owner) and String.downcase(owner) in [String.downcase(email), principal]
  end

  defp workspace_owned_by?(_, _), do: false

  defp workspace_status(%{status: status}) when is_atom(status), do: Atom.to_string(status)
  defp workspace_status(%{"status" => status}) when is_binary(status), do: status
  defp workspace_status(_), do: "unknown"

  defp v3_workspace?(workspace) when is_map(workspace) do
    metadata = Map.get(workspace, :metadata) || Map.get(workspace, "metadata") || %{}

    type =
      Map.get(workspace, :type) || Map.get(workspace, "type") || metadata_value(metadata, :type)

    type in [:v3, "v3"]
  end

  defp v3_workspace?(_), do: false

  defp metadata_value(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp metadata_value(_, _), do: nil

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    with :ok <- require_global_operator_token(conn),
         "v3" <- Map.get(params, "kind", "v3"),
         workspace_id when is_binary(workspace_id) and workspace_id != "" <-
           Map.get(params, "workspace_id"),
         assertion when is_binary(assertion) <- actor_assertion(conn),
         {:ok, claims} <- SuperadminHandoff.verify_actor(assertion),
         true <- runtime_matches?(conn, claims, require_header: true),
         true <- claims["workspace_id"] == workspace_id,
         {:ok, workspace} <- Workspaces.get(workspace_id, claims["email"]),
         true <- v3_workspace?(workspace),
         user <- ForwardAuth.user_from_email(claims["email"]),
         true <- Workspaces.viewer_can_access_workspace?(workspace, user),
         true <- workspace_owned_by?(workspace, claims["email"]),
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
         true <- runtime_matches?(conn, claims, require_header: true),
         true <- claims["workspace_id"] == workspace_id,
         {:ok, workspace} <- Workspaces.get(workspace_id, claims["email"]),
         true <- v3_workspace?(workspace),
         user <- ForwardAuth.user_from_email(claims["email"]),
         true <- Workspaces.viewer_can_access_workspace?(workspace, user),
         true <- workspace_owned_by?(workspace, claims["email"]),
         principal when is_binary(principal) <- identity_principal(user),
         true <- Terminals.tmux_session_in_workspace?(session_id, workspace),
         adapter <- Terminals.tmux_adapter(),
         {:ok, session} <- find_session(adapter, session_id),
         true <- session_visible_to_principal?(session, principal),
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

  defp runtime_matches?(conn, claims, opts \\ []) do
    case configured_runtime_id() do
      runtime_id when is_binary(runtime_id) and runtime_id != "" ->
        claim_matches? = claims["runtime_id"] == runtime_id

        header_matches? =
          List.first(get_req_header(conn, "x-onebackend-runtime-id")) == runtime_id

        claim_matches? and (not Keyword.get(opts, :require_header, false) or header_matches?)

      _ ->
        true
    end
  end

  defp configured_runtime_id do
    Application.get_env(:casein, :runtime_id) || System.get_env("CASEIN_RUNTIME_ID")
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

  defp session_visible_to_principal?(session, principal) when is_binary(principal) do
    case session_actor(session) do
      actor when actor in [nil, ""] -> true
      actor when is_binary(actor) -> normalize_actor(actor) == normalize_actor(principal)
      _ -> false
    end
  end

  defp session_visible_to_principal?(_, _), do: false

  defp normalize_actor(actor) do
    actor = String.downcase(String.trim(actor))

    case String.split(actor, "@", parts: 2) do
      [principal, _domain] -> principal
      _ -> actor
    end
  end

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
