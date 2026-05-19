defmodule DevIdeWeb.TerminalChannel do
  @moduledoc """
  Bidirectional terminal stream for any session — workspace shell or fleet
  execution. Topic: `terminal:<workspace_id>:<sid>`.

  The channel is now a thin transport for session owners. It resolves the
  logical session and delegates attachment/input/resize behavior to
  `DevIDE.Terminals.SessionOwner`.

  Authorization: the underlying Phoenix.Socket already authenticated the user
  token. Every join re-checks workspace path safety against the manager.
  """

  use Phoenix.Channel

  alias DevIDE.Terminals
  alias DevIDE.Terminals.Boundary
  alias DevIDE.Terminals.Session.Info
  alias DevIdeWeb.ChannelAuth
  alias DevIDE.Workspaces
  alias DevIdeWeb.Plugs.ForwardAuth

  @fast_path_cache_table :dev_ide_terminal_fast_path_cache
  @fast_path_cache_ttl_ms 60_000
  @workspace_fast_path_sid :workspace

  @impl true
  def join("terminal:" <> rest, params, socket) do
    user = socket.assigns[:current_user] || %{}
    host_id = host_id(params)
    mode = Boundary.normalize_mode(params["mode"])
    fast_cache = socket.assigns[:terminal_fast_path_cache] || %{}

    with [workspace_id, sid] <- String.split(rest, ":", parts: 2),
         true <- workspace_id != "" and sid != "",
         {:ok, %{mode: mode, ws: ws, fast_path: fast_path}, next_fast_cache} <-
           resolve_workspace_context(
             user,
             workspace_id,
             sid,
             host_id,
             mode,
             fast_cache,
             params["terminal_capability"]
           ),
         {:ok, %Info{} = info} <- Terminals.resolve(sid),
         {:ok, mode} <- Terminals.attachment_policy(info, mode) do
      socket =
        socket
        |> assign(:terminal_fast_path_cache, next_fast_cache)
        |> assign(:workspace_id, workspace_id)
        |> assign(:host_id, host_id)
        |> assign(:terminal_sid, sid)
        |> assign(:terminal_mode, mode)
        |> assign(:terminal_fast_path, fast_path)

      attach_owner_mode(info, mode, ws, socket)
    else
      :error -> {:error, %{reason: "invalid session"}}
      {:error, reason} -> {:error, %{reason: format(reason)}}
      _ -> {:error, %{reason: "invalid session"}}
    end
  end

  # Workspace ownership gate — see WorkspaceLive.Show.authorize_owner/2.
  defp authorize_owner(ws, user) do
    if not ForwardAuth.enabled?() or Workspaces.owns?(ws, user[:username]),
      do: :ok,
      else: {:error, :forbidden}
  end

  defp resolve_workspace_context(
         user,
         workspace_id,
         sid,
         host_id,
         mode,
         fast_cache,
         terminal_capability
       ) do
    case fast_capability_context(
           user,
           workspace_id,
           sid,
           host_id,
           mode,
           fast_cache,
           terminal_capability
         ) do
      {:ok, claims} ->
        cache_fast_path_claims(user, workspace_id, sid, host_id, mode, claims)

        {:ok, %{mode: mode, ws: synthetic_workspace(claims), fast_path: true},
         cache_fast_claim_in_socket(fast_cache, user, workspace_id, sid, host_id, mode, claims)}

      :fallback ->
        with {:ok, ws} <- Workspaces.get(workspace_id, user[:email]),
             :ok <- authorize_owner(ws, user) do
          claims = synthetic_claim(user, ws, sid, host_id, mode)

          if claims do
            claims = Map.put(claims, :_fast_mode, mode)
            cache_fast_path_claims(user, workspace_id, sid, host_id, mode, claims)

            next_cache =
              cache_fast_claim_in_socket(
                fast_cache,
                user,
                workspace_id,
                sid,
                host_id,
                mode,
                claims
              )

            fast_path = terminal_capability == nil and mode != :raw

            {:ok, %{mode: mode, ws: synthetic_workspace(claims), fast_path: fast_path},
             next_cache}
          else
            {:ok, %{mode: mode, ws: ws, fast_path: false}, fast_cache}
          end
        else
          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fast_capability_context(user, workspace_id, sid, host_id, mode, fast_cache, nil) do
    case cached_fast_claim_from_socket(fast_cache, user, workspace_id, sid, host_id, mode) do
      {:ok, claims} ->
        {:ok, claims}

      _ ->
        cached_fast_claim(user, workspace_id, sid, host_id, mode)
    end
  end

  defp fast_capability_context(user, workspace_id, sid, host_id, mode, fast_cache, token) do
    case cached_fast_claim_from_socket(fast_cache, user, workspace_id, sid, host_id, mode) do
      {:ok, claims} ->
        {:ok, claims}

      _ ->
        case ChannelAuth.verify_terminal_capability(token) do
          {:ok, claims} ->
            with {:ok, mode} <- fast_mode_allowed?(mode, claims),
                 :ok <- ensure_capability_match(mode, claims, user),
                 :ok <- ensure_workspace_match(workspace_id, sid, claims, host_id) do
              claims =
                claims
                |> Map.put(:_fast_mode, mode)

              {:ok, claims}
            else
              :fallback -> :fallback
              {:error, reason} -> {:error, reason}
              _ -> :fallback
            end

          _ ->
            :fallback
        end
    end
  end

  defp cached_fast_claim_from_socket(fast_cache, user, workspace_id, sid, host_id, mode) do
    actor = actor_id(%{current_user: user})
    actor_key = actor_key_to_string(actor)

    if actor_key do
      mode_key = cache_key(actor_key, workspace_id, sid, host_id, mode)
      wildcard_key = cache_key(actor_key, workspace_id, sid, host_id, :any)

      workspace_mode_key =
        cache_key(actor_key, workspace_id, @workspace_fast_path_sid, host_id, mode)

      workspace_wildcard_key =
        cache_key(actor_key, workspace_id, @workspace_fast_path_sid, host_id, :any)

      now = System.system_time(:millisecond)

      case Map.get(fast_cache, mode_key) do
        {claims, expires_at} when is_integer(expires_at) ->
          if now < expires_at do
            validate_cached_claim(mode, claims)
          else
            fast_cache = Map.delete(fast_cache, mode_key)

            cached_fast_claim_from_socket_wildcard(
              fast_cache,
              [wildcard_key, workspace_mode_key, workspace_wildcard_key],
              now,
              mode
            )
          end

        _ ->
          cached_fast_claim_from_socket_wildcard(
            fast_cache,
            [wildcard_key, workspace_mode_key, workspace_wildcard_key],
            now,
            mode
          )
      end
    else
      :fallback
    end
  end

  defp cached_fast_claim_from_socket_wildcard(_fast_cache, [], _now, _mode), do: :fallback

  defp cached_fast_claim_from_socket_wildcard(fast_cache, [key | rest], now, mode) do
    case Map.get(fast_cache, key) do
      {claims, expires_at} when is_integer(expires_at) ->
        if now < expires_at do
          validate_cached_claim(mode, claims)
        else
          fast_cache = Map.delete(fast_cache, key)
          cached_fast_claim_from_socket_wildcard(fast_cache, rest, now, mode)
        end

      _ ->
        cached_fast_claim_from_socket_wildcard(fast_cache, rest, now, mode)
    end
  end

  defp cache_fast_claim_in_socket(fast_cache, user, workspace_id, sid, host_id, mode, claims) do
    actor = actor_id(%{current_user: user})
    actor_key = actor_key_to_string(actor)

    if actor_key do
      mode_key = cache_key(actor_key, workspace_id, sid, host_id, mode)
      wildcard_key = cache_key(actor_key, workspace_id, sid, host_id, :any)
      workspace_claim = Map.delete(claims, :terminal_sid)

      workspace_mode_key =
        cache_key(actor_key, workspace_id, @workspace_fast_path_sid, host_id, mode)

      workspace_wildcard_key =
        cache_key(actor_key, workspace_id, @workspace_fast_path_sid, host_id, :any)

      expires_at = System.system_time(:millisecond) + @fast_path_cache_ttl_ms

      fast_cache
      |> Map.put(mode_key, {claims, expires_at})
      |> Map.put(wildcard_key, {claims, expires_at})
      |> Map.put(workspace_mode_key, {workspace_claim, expires_at})
      |> Map.put(workspace_wildcard_key, {workspace_claim, expires_at})
    else
      fast_cache
    end
  end

  defp cached_fast_claim(user, workspace_id, sid, host_id, mode) do
    actor = actor_id(%{current_user: user})
    actor_key = actor_key_to_string(actor)

    if actor_key do
      mode_key = cache_key(actor_key, workspace_id, sid, host_id, mode)
      wildcard_key = cache_key(actor_key, workspace_id, sid, host_id, :any)

      workspace_mode_key =
        cache_key(actor_key, workspace_id, @workspace_fast_path_sid, host_id, mode)

      workspace_wildcard_key =
        cache_key(actor_key, workspace_id, @workspace_fast_path_sid, host_id, :any)

      ensure_cache_table!()

      case :ets.lookup(@fast_path_cache_table, mode_key) do
        [{^mode_key, claims, expires_at}] ->
          now = System.system_time(:millisecond)

          if now < expires_at do
            validate_cached_claim(mode, claims)
          else
            :ets.delete(@fast_path_cache_table, mode_key)

            cached_fast_claim_from_ets(
              [wildcard_key, workspace_mode_key, workspace_wildcard_key],
              now,
              mode
            )
          end

        _ ->
          cached_fast_claim_from_ets(
            [wildcard_key, workspace_mode_key, workspace_wildcard_key],
            System.system_time(:millisecond),
            mode
          )
      end
    else
      :fallback
    end
  end

  defp cached_fast_claim_from_ets([], _now, _mode), do: :fallback

  defp cached_fast_claim_from_ets([key | rest], now, mode) do
    case :ets.lookup(@fast_path_cache_table, key) do
      [{^key, claims, expires_at}] ->
        if now < expires_at do
          validate_cached_claim(mode, claims)
        else
          :ets.delete(@fast_path_cache_table, key)
          cached_fast_claim_from_ets(rest, now, mode)
        end

      _ ->
        cached_fast_claim_from_ets(rest, now, mode)
    end
  end

  defp cache_key(actor_id, workspace_id, sid, host_id, mode) do
    {:terminal_fast_path, actor_id, workspace_id, sid, host_id, mode}
  end

  defp actor_key_to_string(value) when is_binary(value), do: value
  defp actor_key_to_string(value) when is_integer(value), do: Integer.to_string(value)
  defp actor_key_to_string(_), do: nil

  defp cache_fast_path_claims(user, workspace_id, sid, host_id, mode, claims) do
    actor = actor_id(%{current_user: user})
    actor_key = actor_key_to_string(actor)

    if actor_key do
      ensure_cache_table!()
      mode_key = cache_key(actor_key, workspace_id, sid, host_id, mode)
      wildcard_key = cache_key(actor_key, workspace_id, sid, host_id, :any)
      workspace_claim = Map.delete(claims, :terminal_sid)

      workspace_mode_key =
        cache_key(actor_key, workspace_id, @workspace_fast_path_sid, host_id, mode)

      workspace_wildcard_key =
        cache_key(actor_key, workspace_id, @workspace_fast_path_sid, host_id, :any)

      expires_at = System.system_time(:millisecond) + @fast_path_cache_ttl_ms
      :ets.insert(@fast_path_cache_table, {mode_key, claims, expires_at})
      :ets.insert(@fast_path_cache_table, {wildcard_key, claims, expires_at})
      :ets.insert(@fast_path_cache_table, {workspace_mode_key, workspace_claim, expires_at})
      :ets.insert(@fast_path_cache_table, {workspace_wildcard_key, workspace_claim, expires_at})
    end

    :ok
  end

  defp synthetic_claim(user, ws, sid, host_id, mode) do
    actor = actor_id(%{current_user: user})
    actor_key = actor_key_to_string(actor)

    if actor_key && is_map(ws) do
      raw_allowed? =
        case mode do
          :raw -> Boundary.raw_allowed?(ws.id || ws[:id], host_id)
          _ -> true
        end

      if raw_allowed? do
        %{
          kind: :terminal_workspace,
          user_id: actor_key,
          workspace_id: ws.id || ws[:id],
          workspace_name: ws.name || ws.id || "",
          workspace_user: ws.user || actor_key,
          workspace_path: ws.path,
          terminal_sid: sid,
          workspace_host_id: host_id,
          owner_ok: true,
          terminal_owner_ok: true,
          raw_terminal_ok: raw_allowed?
        }
      end
    else
      nil
    end
  end

  defp ensure_cache_table! do
    case :ets.whereis(@fast_path_cache_table) do
      :undefined -> :ets.new(@fast_path_cache_table, [:named_table, :public, :set])
      _ -> :ok
    end
  end

  defp fast_mode_allowed?(:raw, claims) do
    cond do
      claims[:owner_ok] == false or claims[:terminal_owner_ok] == false ->
        {:error, :forbidden}

      claims[:raw_terminal_ok] == true ->
        {:ok, :raw}

      true ->
        :fallback
    end
  end

  defp fast_mode_allowed?(_, claims) do
    if claims[:owner_ok] == false or claims[:terminal_owner_ok] == false do
      {:error, :forbidden}
    else
      {:ok, :governed}
    end
  end

  defp validate_cached_claim(mode, claims) do
    case fast_mode_allowed?(mode, claims) do
      {:ok, _mode} -> {:ok, claims}
      _ -> :fallback
    end
  end

  defp ensure_capability_match(_mode, claims, user) do
    actor = actor_id(%{current_user: user})
    actor_key = to_string(actor)

    if is_binary(claims[:user_id]) and actor_key == claims[:user_id] do
      :ok
    else
      :fallback
    end
  end

  defp ensure_workspace_match(workspace_id, sid, claims, host_id) do
    cond do
      claims[:workspace_id] != workspace_id -> :fallback
      is_binary(claims[:terminal_sid]) and claims[:terminal_sid] != sid -> :fallback
      claims[:workspace_host_id] in [nil, host_id] -> :ok
      true -> :fallback
    end
  end

  defp synthetic_workspace(claims) do
    %{
      id: claims[:workspace_id],
      name: claims[:workspace_name],
      user: claims[:workspace_user],
      path: claims[:workspace_path],
      loc: claims[:workspace_loc],
      status: :running,
      owner_id: claims[:user_id],
      metadata: %{},
      branch: nil
    }
  end

  defp attach_owner_mode(%Info{} = info, :governed, _ws, socket) do
    case Terminals.owner_attach(
           socket.assigns.workspace_id,
           info,
           mode: :governed,
           host_id: socket.assigns.host_id,
           workspace_key: socket.assigns.workspace_id,
           session_id: socket.assigns.terminal_sid
         ) do
      {:ok, owner_pid, attach_payload} ->
        {:ok, attach_payload, assign(socket, :terminal_owner_pid, owner_pid)}

      {:error, reason} ->
        {:error, %{reason: format(reason)}}
    end
  end

  defp attach_owner_mode(%Info{kind: :shell} = info, :raw, ws, socket) do
    auth_check =
      if Map.get(socket.assigns, :terminal_fast_path, false) do
        :ok
      else
        Boundary.authorize_raw(socket.assigns.workspace_id,
          actor_id: actor_id(socket),
          host_id: socket.assigns.host_id,
          session_id: info.sid
        )
      end

    with :ok <- auth_check,
         {:ok, loc} <- workspace_loc_for_raw(ws, socket),
         {:ok, owner_pid, attach_payload} <-
           Terminals.owner_attach(
             socket.assigns.workspace_id,
             info,
             mode: :raw,
             host_id: socket.assigns.host_id,
             workspace_key: ws.name || ws.id,
             loc: loc,
             session_id: socket.assigns.terminal_sid
           ) do
      {:ok, attach_payload, assign(socket, :terminal_owner_pid, owner_pid)}
    else
      {:error, reason} -> {:error, %{reason: format(reason)}}
      _ -> {:error, %{reason: "raw terminal unavailable"}}
    end
  end

  # =====================
  # Incoming Events
  # =====================

  @impl true
  def handle_in(
        "input",
        %{"data" => data},
        %{assigns: %{terminal_mode: :raw, terminal_owner_pid: owner_pid}} = socket
      )
      when is_binary(data) do
    Terminals.owner_input(owner_pid, data)
    {:noreply, socket}
  end

  def handle_in("input", _params, socket) do
    {:reply, {:error, %{reason: Boundary.format_reason(:raw_terminal_disabled)}}, socket}
  end

  def handle_in("command", %{"line" => line}, %{assigns: %{terminal_mode: :governed}} = socket)
      when is_binary(line) do
    case Boundary.submit_governed(socket.assigns.workspace_id, line,
           actor_id: actor_id(socket),
           host_id: socket.assigns.host_id,
           session_id: socket.assigns.terminal_sid
         ) do
      {:ok, %{kind: :inspection} = result} ->
        {:reply,
         {:ok,
          %{
            status: result.status,
            line: result.line,
            exit_code: result.exit_code,
            output: result.output,
            output_truncated: result.output_truncated
          }}, socket}

      {:ok, assignment} ->
        {:reply, {:ok, %{status: "queued", assignment: assignment}}, socket}

      {:error, :blank} ->
        {:reply, {:ok, %{status: "blank"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: Boundary.format_reason(reason)}}, socket}
    end
  end

  def handle_in("command", _params, socket) do
    {:reply, {:error, %{reason: "command submission requires governed terminal mode"}}, socket}
  end

  def handle_in(
        "resize",
        %{"cols" => c, "rows" => r},
        %{assigns: %{terminal_mode: :raw, terminal_owner_pid: owner_pid}} = socket
      )
      when is_integer(c) and is_integer(r) do
    Terminals.owner_resize(owner_pid, c, r)
    {:noreply, socket}
  end

  def handle_in(_, _, socket), do: {:noreply, socket}

  defp workspace_loc_for_raw(ws, socket) do
    if Map.get(socket.assigns, :terminal_fast_path, false) and is_tuple(ws[:loc]) do
      {:ok, ws[:loc]}
    else
      Workspaces.safe_host_loc(ws)
    end
  end

  # =====================
  # Owner events
  # =====================

  @impl true
  def handle_info({:terminal_payload, :data, payload}, socket) do
    push(socket, "data", payload)
    {:noreply, socket}
  end

  def handle_info({:terminal_payload, :exit, reason}, socket) do
    push(socket, "exit", %{reason: inspect(reason)})
    {:stop, :normal, socket}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, %{assigns: %{terminal_owner_pid: owner_pid}}) do
    Terminals.owner_detach(owner_pid, self())
    :ok
  end

  def terminate(_reason, _socket), do: :ok

  defp format(:forbidden), do: "that workspace belongs to another user"
  defp format(:missing_path), do: "workspace has no host path"
  defp format(:outside_root), do: "workspace path outside allowed roots"
  defp format(:requires_local_host), do: Boundary.format_reason(:requires_local_host)
  defp format(:requires_manual_mode), do: Boundary.format_reason(:requires_manual_mode)
  defp format(:invalid_shell_attachment_opts), do: "missing shell attachment options"
  defp format(other), do: inspect(other)

  defp host_id(params) do
    case params["host_id"] do
      value when is_binary(value) and value != "" -> value
      _ -> "local"
    end
  end

  defp actor_id(%{assigns: %{current_user: %{id: id}}}), do: id
  defp actor_id(%{current_user: %{id: id}}), do: id
  defp actor_id(_), do: "terminal"
end
