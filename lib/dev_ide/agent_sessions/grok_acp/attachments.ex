defmodule DevIDE.AgentSessions.GrokACP.Attachments do
  @moduledoc """
  Production lifecycle manager for Grok ACP leader attachments.

  Hook reports provide the Grok session ID and the private leader socket used
  by the interactive TUI. After validating that metadata, this manager starts
  one supervised `GrokACP` observer per workspace/session and keeps a safe,
  workspace-scoped projection for operator approval surfaces.

  Neither the global `~/.grok/leader.sock` nor an arbitrary filesystem path is
  accepted. Leader sockets must be direct children of DevIDE's configured
  Grok leader root, and capability bundles must be content-addressed directories
  accepted by `DevIDE.Agents.GrokCapabilityBundle`.
  """

  use GenServer

  require Logger

  alias DevIDE.Agents.GrokCapabilityBundle
  alias DevIDE.AgentSessions.GrokACP
  alias Phoenix.PubSub

  @topic_prefix "grok_acp_attachments:"
  @digest ~r/\A(?:sha256-)?([0-9a-f]{64})\z/

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Observe validated Grok runtime metadata without blocking the hook request."
  @spec observe(map()) :: :ok | :disabled | {:error, term()}
  def observe(attrs) when is_map(attrs) do
    case normalize_observation(attrs) do
      {:ok, observation} ->
        if enabled?() do
          GenServer.cast(__MODULE__, {:observe, observation})
          :ok
        else
          :disabled
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc "List safe ACP attachment snapshots for one workspace."
  @spec list(String.t()) :: [map()]
  def list(workspace_id) when is_binary(workspace_id) do
    GenServer.call(__MODULE__, {:list, workspace_id})
  end

  @doc "Respond to a pending permission using its UI string request ID."
  @spec respond_permission(String.t(), String.t(), String.t() | integer(), String.t()) ::
          :ok | {:error, term()}
  def respond_permission(workspace_id, attachment_key, request_id, option_id)
      when is_binary(workspace_id) and is_binary(attachment_key) and is_binary(option_id) do
    GenServer.call(
      __MODULE__,
      {:respond_permission, workspace_id, attachment_key, request_id, option_id}
    )
  end

  @doc "Cancel a pending permission using its UI string request ID."
  @spec cancel_permission(String.t(), String.t(), String.t() | integer()) ::
          :ok | {:error, term()}
  def cancel_permission(workspace_id, attachment_key, request_id)
      when is_binary(workspace_id) and is_binary(attachment_key) do
    GenServer.call(__MODULE__, {:cancel_permission, workspace_id, attachment_key, request_id})
  end

  @doc "Subscribe to safe attachment snapshots for a workspace."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(workspace_id) when is_binary(workspace_id) do
    PubSub.subscribe(DevIDE.PubSub, topic(workspace_id))
  end

  @doc false
  def topic(workspace_id), do: @topic_prefix <> workspace_id

  @doc false
  def clear, do: GenServer.call(__MODULE__, :clear)

  @impl true
  def init(opts) do
    {:ok,
     %{
       attachments: %{},
       monitors: %{},
       transport: Keyword.get(opts, :transport),
       transport_opts: Keyword.get(opts, :transport_opts, [])
     }}
  end

  @impl true
  def handle_call({:list, workspace_id}, _from, state) do
    {:reply, workspace_snapshots(state, workspace_id), state}
  end

  def handle_call(
        {:respond_permission, workspace_id, attachment_key, request_id, option_id},
        _from,
        state
      ) do
    {reply, state} =
      with {:ok, entry} <- fetch_entry(state, workspace_id, attachment_key),
           {:ok, raw_request_id} <- resolve_request_id(entry, request_id),
           :ok <- safe_respond_permission(entry.pid, raw_request_id, option_id) do
        {:ok, refresh_entry(state, workspace_id, attachment_key)}
      else
        {:error, reason} -> {{:error, public_permission_error(reason)}, state}
      end

    {:reply, reply, state}
  end

  def handle_call({:cancel_permission, workspace_id, attachment_key, request_id}, _from, state) do
    {reply, state} =
      with {:ok, entry} <- fetch_entry(state, workspace_id, attachment_key),
           {:ok, raw_request_id} <- resolve_request_id(entry, request_id),
           :ok <- safe_cancel_permission(entry.pid, raw_request_id) do
        {:ok, refresh_entry(state, workspace_id, attachment_key)}
      else
        {:error, reason} -> {{:error, public_permission_error(reason)}, state}
      end

    {:reply, reply, state}
  end

  def handle_call(:clear, _from, state) do
    Enum.each(state.attachments, fn {_key, entry} -> stop_attachment(entry) end)
    {:reply, :ok, %{state | attachments: %{}, monitors: %{}}}
  end

  @impl true
  def handle_cast({:observe, observation}, state) do
    state = retire_replaced_binding(state, observation)
    key = entry_key(observation.workspace_id, observation.attachment_key)

    state =
      case Map.get(state.attachments, key) do
        %{pid: pid} = entry when is_pid(pid) ->
          if connection_signature(entry.observation) == connection_signature(observation) do
            put_entry(state, key, %{entry | observation: observation})
          else
            stop_attachment(entry)

            state
            |> delete_entry(key)
            |> start_attachment(observation)
          end

        _ ->
          start_attachment(state, observation)
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:grok_acp_status, pid, snapshot}, state)
      when is_pid(pid) and is_map(snapshot) do
    key = entry_key(snapshot.workspace_id, snapshot.attachment_key)

    state =
      case Map.get(state.attachments, key) do
        nil ->
          state

        entry ->
          {state, monitor_ref} = ensure_monitor(state, key, pid)

          state
          |> put_entry(key, %{
            entry
            | pid: pid,
              monitor_ref: monitor_ref,
              snapshot: snapshot
          })
          |> broadcast_if_changed(key, entry)
      end

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {key, monitors} ->
        state = %{state | monitors: monitors}

        case Map.get(state.attachments, key) do
          %{pid: ^pid} = entry ->
            disconnected =
              entry.snapshot
              |> Map.put(:status, :disconnected)
              |> Map.put(:last_error, transport_exit_summary(reason))

            state =
              put_entry(state, key, %{entry | pid: nil, monitor_ref: nil, snapshot: disconnected})

            broadcast(state, elem(key, 0))
            {:noreply, state}

          _entry ->
            {:noreply, state}
        end
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_attachment(state, observation) do
    protected_opts =
      [
        attachment_key: observation.attachment_key,
        session_id: observation.session_id,
        leader_socket: observation.leader_socket,
        leader_mode: :attach,
        plugin_dirs: [observation.bundle_dir],
        status_listener: self()
      ]

    opts =
      state
      |> configured_transport_opts()
      |> Keyword.merge(protected_opts)
      |> maybe_put_transport(state)

    key = entry_key(observation.workspace_id, observation.attachment_key)

    case GrokACP.ensure_started(observation.workspace_id, observation.cwd, opts) do
      {:ok, pid} ->
        snapshot = safe_status(pid, observation)
        {state, monitor_ref} = monitor(state, key, pid)

        entry = %{
          pid: pid,
          monitor_ref: monitor_ref,
          observation: observation,
          snapshot: snapshot
        }

        state = put_entry(state, key, entry)
        broadcast(state, observation.workspace_id)
        state

      {:error, reason} ->
        Logger.warning("Unable to attach DevIDE to Grok leader",
          workspace_id: observation.workspace_id,
          reason: inspect(reason)
        )

        state
    end
  end

  defp maybe_put_transport(opts, state) do
    case state.transport || Application.get_env(:dev_ide, :grok_acp_transport) do
      nil -> opts
      transport -> Keyword.put(opts, :transport, transport)
    end
  end

  defp configured_transport_opts(state) do
    Application.get_env(:dev_ide, :grok_acp_transport_opts, [])
    |> Keyword.merge(state.transport_opts)
  end

  defp safe_status(pid, observation) do
    GrokACP.status(pid)
  catch
    :exit, _reason ->
      %{
        status: :starting,
        workspace_id: observation.workspace_id,
        attachment_key: observation.attachment_key,
        session_id: observation.session_id,
        protocol_version: nil,
        capabilities: %{},
        pending_permissions: [],
        last_error: nil
      }
  end

  defp refresh_entry(state, workspace_id, attachment_key) do
    key = entry_key(workspace_id, attachment_key)

    case Map.get(state.attachments, key) do
      %{pid: pid} = entry when is_pid(pid) ->
        updated = %{entry | snapshot: GrokACP.status(pid)}
        state = put_entry(state, key, updated)
        broadcast(state, workspace_id)
        state

      _ ->
        state
    end
  catch
    :exit, _reason -> state
  end

  defp fetch_entry(state, workspace_id, attachment_key) do
    case Map.get(state.attachments, entry_key(workspace_id, attachment_key)) do
      %{pid: pid} = entry when is_pid(pid) -> {:ok, entry}
      _ -> {:error, :attachment_not_found}
    end
  end

  defp resolve_request_id(entry, request_id) do
    request =
      Enum.find(entry.snapshot.pending_permissions, fn permission ->
        to_string(permission.request_id) == to_string(request_id)
      end)

    case request do
      nil -> {:error, :permission_not_found}
      permission -> {:ok, permission.request_id}
    end
  end

  defp retire_replaced_binding(state, observation) do
    binding = binding_key(observation)

    Enum.reduce(state.attachments, state, fn {key, entry}, acc ->
      if binding_key(entry.observation) == binding and
           entry.observation.attachment_key != observation.attachment_key do
        stop_attachment(entry)
        delete_entry(acc, key)
      else
        acc
      end
    end)
  end

  defp stop_attachment(%{pid: pid}) when is_pid(pid) do
    if Process.alive?(pid), do: GrokACP.stop(pid)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp stop_attachment(_entry), do: :ok

  defp workspace_snapshots(state, workspace_id) do
    state.attachments
    |> Enum.filter(fn {{workspace, _key}, _entry} -> workspace == workspace_id end)
    |> Enum.map(fn {_key, entry} -> public_snapshot(entry) end)
    |> Enum.sort_by(& &1.attachment_key)
  end

  defp public_snapshot(entry) do
    snapshot = entry.snapshot

    %{
      attachment_key: snapshot.attachment_key,
      session_id: snapshot.session_id,
      status: snapshot.status,
      protocol_version: snapshot.protocol_version,
      pending_permissions: snapshot.pending_permissions,
      last_error: snapshot.last_error,
      tmux_session_id: entry.observation.tmux_session_id,
      pane_id: entry.observation.pane_id,
      bundle_digest: entry.observation.bundle_digest
    }
  end

  defp broadcast_if_changed(state, key, previous) do
    if public_snapshot(Map.fetch!(state.attachments, key)) != public_snapshot(previous) do
      broadcast(state, elem(key, 0))
    end

    state
  end

  defp broadcast(state, workspace_id) do
    PubSub.broadcast(
      DevIDE.PubSub,
      topic(workspace_id),
      {:grok_acp_attachments_updated, workspace_id, workspace_snapshots(state, workspace_id)}
    )
  end

  defp put_entry(state, key, entry) do
    %{state | attachments: Map.put(state.attachments, key, entry)}
  end

  defp delete_entry(state, key) do
    case Map.pop(state.attachments, key) do
      {nil, _attachments} ->
        state

      {entry, attachments} ->
        monitors =
          if entry.monitor_ref do
            Process.demonitor(entry.monitor_ref, [:flush])
            Map.delete(state.monitors, entry.monitor_ref)
          else
            state.monitors
          end

        %{state | attachments: attachments, monitors: monitors}
    end
  end

  defp monitor(state, key, pid) do
    ref = Process.monitor(pid)
    {%{state | monitors: Map.put(state.monitors, ref, key)}, ref}
  end

  defp ensure_monitor(state, key, pid) do
    case Map.get(state.attachments, key) do
      %{pid: ^pid, monitor_ref: ref} when is_reference(ref) ->
        {state, ref}

      %{monitor_ref: old_ref} ->
        state =
          if is_reference(old_ref) do
            Process.demonitor(old_ref, [:flush])
            %{state | monitors: Map.delete(state.monitors, old_ref)}
          else
            state
          end

        monitor(state, key, pid)
    end
  end

  defp normalize_observation(attrs) do
    with "grok" <- value(attrs, :agent_runtime),
         true <- value(attrs, :source) in [:hook, "hook"],
         workspace_id when is_binary(workspace_id) <- present(value(attrs, :workspace_id)),
         session_id when is_binary(session_id) <- present(value(attrs, :agent_session_id)),
         tmux_session_id when is_binary(tmux_session_id) <-
           present(value(attrs, :tmux_session_id)),
         pane_id when is_binary(pane_id) <- present(value(attrs, :pane_id)),
         cwd when is_binary(cwd) <- valid_cwd(value(attrs, :cwd)),
         transcript_path when is_binary(transcript_path) <-
           valid_transcript(value(attrs, :transcript_path)),
         leader_socket when is_binary(leader_socket) <-
           valid_leader_socket(value(attrs, :grok_leader_socket)),
         bundle_dir when is_binary(bundle_dir) <- valid_bundle_dir(value(attrs, :grok_bundle_dir)),
         bundle_digest when is_binary(bundle_digest) <-
           valid_bundle_digest(value(attrs, :grok_bundle_digest), bundle_dir) do
      {:ok,
       %{
         workspace_id: workspace_id,
         attachment_key: session_id,
         session_id: session_id,
         tmux_session_id: tmux_session_id,
         pane_id: pane_id,
         cwd: cwd,
         transcript_path: transcript_path,
         leader_socket: leader_socket,
         bundle_dir: bundle_dir,
         bundle_digest: bundle_digest
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_grok_attachment_metadata}
    end
  end

  defp valid_cwd(cwd) when is_binary(cwd) do
    expanded = Path.expand(cwd)
    if Path.type(expanded) == :absolute and File.dir?(expanded), do: expanded, else: nil
  end

  defp valid_cwd(_cwd), do: nil

  defp valid_transcript(path) when is_binary(path) do
    if DevIDE.Agents.Transcripts.Grok.allowed_pending_path?(path),
      do: Path.expand(path),
      else: nil
  end

  defp valid_transcript(_path), do: nil

  defp valid_leader_socket(path) when is_binary(path) do
    expanded = Path.expand(path)

    if GrokCapabilityBundle.allowed_leader_socket?(expanded) do
      expanded
    end
  end

  defp valid_leader_socket(_path), do: nil

  defp valid_bundle_dir(path) when is_binary(path) do
    validator =
      Application.get_env(
        :dev_ide,
        :grok_acp_bundle_validator,
        &GrokCapabilityBundle.allowed_path?/1
      )

    if is_function(validator, 1) and validator.(path) do
      Path.expand(path)
    end
  end

  defp valid_bundle_dir(_path), do: nil

  defp valid_bundle_digest(digest, bundle_dir) when is_binary(digest) do
    with [_, normalized] <- Regex.run(@digest, String.downcase(String.trim(digest))),
         true <- Path.basename(bundle_dir) == "sha256-" <> normalized do
      normalized
    else
      _ -> nil
    end
  end

  defp valid_bundle_digest(_digest, _bundle_dir), do: nil

  defp enabled?, do: Application.get_env(:dev_ide, :grok_acp_auto_attach, true) == true

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil

  defp entry_key(workspace_id, attachment_key), do: {workspace_id, attachment_key}

  defp binding_key(observation) do
    {observation.workspace_id, observation.tmux_session_id, observation.pane_id}
  end

  defp connection_signature(observation) do
    {
      observation.cwd,
      observation.leader_socket,
      observation.bundle_dir,
      observation.bundle_digest
    }
  end

  defp transport_exit_summary(reason), do: %{kind: :transport_exit, reason: inspect(reason)}

  defp safe_respond_permission(pid, request_id, option_id) do
    GrokACP.respond_permission(pid, request_id, option_id)
  catch
    :exit, _reason -> {:error, :attachment_not_found}
  end

  defp safe_cancel_permission(pid, request_id) do
    GrokACP.cancel_permission(pid, request_id)
  catch
    :exit, _reason -> {:error, :attachment_not_found}
  end

  defp public_permission_error(:unknown_permission_option), do: :invalid_option
  defp public_permission_error(reason), do: reason
end
