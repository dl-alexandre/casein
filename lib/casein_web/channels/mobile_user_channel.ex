defmodule CaseinWeb.MobileUserChannel do
  @moduledoc """
  User-scoped mobile card stream.

  Topic: `mobile:user:me` for normal clients, with `mobile:user:<user_id>`
  still accepted for explicit internal callers. The channel is a transport over
  `Casein.Mobile.UserObserver`; it authorizes which user/workspaces may feed the
  observer, then forwards full card snapshots to connected mobile clients.
  """

  use Phoenix.Channel

  alias Casein.Mobile.Actions
  alias Casein.Mobile.Evidence
  alias Casein.Mobile.Intervention
  alias Casein.Mobile.Observability
  alias Casein.Mobile.ResumeCard
  alias Casein.Mobile.UserObserver
  alias Casein.Origin
  alias Casein.Push
  alias Casein.Workspaces

  @impl true
  def join("mobile:user:me", _params, socket) do
    case current_user_id(socket) do
      user_id when is_binary(user_id) ->
        join_user_topic(user_id, socket)

      _ ->
        {:error, %{reason: "unauthorized"}}
    end
  end

  def join("mobile:user:" <> user_id, _params, socket) do
    if current_user_id(socket) == user_id,
      do: join_user_topic(user_id, socket),
      else: {:error, %{reason: "unauthorized"}}
  end

  @impl true
  def handle_in("watch_workspace", %{"workspace_id" => workspace_id}, socket)
      when is_binary(workspace_id) do
    user_id = socket.assigns.mobile_user_id
    user = socket.assigns[:current_user] || %{}

    case authorize_workspace(socket, user, workspace_id) do
      :ok ->
        :ok = UserObserver.watch_workspace(user_id, workspace_id)
        :ok = UserObserver.connection_live(user_id, workspace_id)
        {:reply, {:ok, render_snapshot(UserObserver.snapshot(user_id), socket)}, socket}

      {:error, reason} ->
        report_connection_issue(user_id, workspace_id, reason)
        {:reply, {:error, %{reason: Atom.to_string(reason)}}, socket}
    end
  end

  def handle_in("card_action", %{"card_id" => card_id, "action" => action} = params, socket)
      when is_binary(card_id) and is_binary(action) do
    user_id = socket.assigns.mobile_user_id

    case Actions.dispatch(action_context(socket, user_id), params) do
      {:ok, result} ->
        {:reply,
         {:ok,
          %{
            status: "accepted",
            idempotent: result.idempotent,
            result: result.result,
            snapshot: render_snapshot(UserObserver.snapshot(user_id), socket)
          }}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: Atom.to_string(reason)}}, socket}
    end
  end

  def handle_in("card_action", _params, socket) do
    {:reply, {:error, %{reason: "invalid_payload"}}, socket}
  end

  def handle_in("mobile_observation", params, socket) when is_map(params) do
    workspace_id = Map.get(params, "workspace_id")
    user = socket.assigns[:current_user] || %{}

    with :ok <- authorize_observation_workspace(socket, user, workspace_id),
         :ok <-
           Observability.record(
             Map.put(
               action_context(socket, socket.assigns.mobile_user_id),
               :workspace_id,
               workspace_id
             ),
             params
           ) do
      {:reply, :ok, socket}
    else
      {:error, reason} -> {:reply, {:error, error_payload(reason)}, socket}
    end
  end

  def handle_in(
        "register_push",
        %{"workspace_id" => workspace_id, "token" => token, "platform" => platform},
        socket
      )
      when is_binary(workspace_id) and is_binary(token) and is_binary(platform) do
    user_id = socket.assigns.mobile_user_id
    user = socket.assigns[:current_user] || %{}

    with :ok <- authorize_workspace(socket, user, workspace_id),
         :ok <- Push.ready_for?(platform) do
      Push.register(%{
        workspace_id: workspace_id,
        token: token,
        platform: platform,
        user_id: user_id
      })

      {:reply, :ok, socket}
    else
      {:error, reason} ->
        {:reply, {:error, error_payload(reason)}, socket}
    end
  end

  def handle_in("register_push", params, socket) do
    case register_user_push(socket, params) do
      :ok -> {:reply, :ok, socket}
      {:error, reason} -> {:reply, {:error, error_payload(reason)}, socket}
    end
  end

  def handle_in("unregister_push", %{"token" => token}, socket) when is_binary(token) do
    Push.unregister(token)
    {:reply, :ok, socket}
  end

  def handle_in(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:mobile_cards_snapshot, payload}, socket) do
    push(socket, "cards_snapshot", render_snapshot(payload, socket))
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp watch_paired_workspace(socket, user_id) do
    case socket.assigns[:pairing_workspace_id] do
      workspace_id when is_binary(workspace_id) ->
        _ = UserObserver.watch_workspace(user_id, workspace_id)
        UserObserver.connection_live(user_id, workspace_id)

      _ ->
        :ok
    end
  end

  defp authorize_workspace(socket, user, workspace_id) do
    cond do
      not scoped_to_workspace?(socket, workspace_id) ->
        {:error, :workspace_scope_mismatch}

      true ->
        case Workspaces.get(workspace_id) do
          {:ok, workspace} ->
            if Workspaces.viewer_terminal_owner?(workspace, user),
              do: :ok,
              else: {:error, :unauthorized}

          {:error, :not_found} ->
            {:error, :workspace_not_found}

          {:error, _reason} ->
            {:error, :workspace_unavailable}
        end
    end
  end

  defp authorize_observation_workspace(_socket, _user, nil), do: :ok

  defp authorize_observation_workspace(socket, user, workspace_id)
       when is_binary(workspace_id) do
    authorize_workspace(socket, user, workspace_id)
  end

  defp authorize_observation_workspace(_socket, _user, _workspace_id),
    do: {:error, :invalid_payload}

  defp scoped_to_workspace?(socket, workspace_id) do
    case socket.assigns[:pairing_workspace_id] do
      nil -> true
      ^workspace_id -> true
      _other -> false
    end
  end

  defp report_connection_issue(user_id, workspace_id, reason) do
    UserObserver.connection_issue_changed(user_id, %{
      workspace_id: workspace_id,
      reason: connection_issue_reason(reason),
      last_seen_at: DateTime.utc_now()
    })
  end

  defp connection_issue_reason(:workspace_unavailable), do: :offline
  defp connection_issue_reason(:workspace_scope_mismatch), do: :token_revoked
  defp connection_issue_reason(:unauthorized), do: :token_revoked
  defp connection_issue_reason(_reason), do: :join_failed

  defp register_user_push(_socket, %{"workspace_id" => workspace_id})
       when not is_nil(workspace_id) and workspace_id != "" do
    {:error, :invalid_payload}
  end

  defp register_user_push(socket, %{"token" => token, "platform" => platform})
       when is_binary(token) and is_binary(platform) do
    user_id = socket.assigns.mobile_user_id

    with :ok <- Push.ready_for?(platform) do
      Push.register_user(%{
        user_id: user_id,
        token: token,
        platform: platform
      })
    end
  end

  defp register_user_push(_socket, _params), do: {:error, :invalid_payload}

  defp error_payload(reason), do: %{reason: reason_to_string(reason)}

  defp reason_to_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_to_string(reason) when is_binary(reason), do: reason
  defp reason_to_string(reason), do: inspect(reason)

  defp join_user_topic(user_id, socket) do
    {:ok, _pid} = UserObserver.ensure_started(user_id)
    :ok = UserObserver.subscribe(user_id)
    :ok = watch_paired_workspace(socket, user_id)

    {:ok, render_snapshot(UserObserver.snapshot(user_id), socket),
     assign(socket, :mobile_user_id, user_id)}
  end

  defp current_user_id(socket) do
    user = socket.assigns[:current_user] || %{}
    Map.get(user, :id) || Map.get(user, "id")
  end

  # Server-side actor context for action dispatch. Device provenance
  # (`device_link_id`, `platform`) is read from socket assigns set at connect —
  # never from the client action payload.
  defp action_context(socket, user_id) do
    %{
      user_id: user_id,
      user: socket.assigns[:current_user] || %{},
      pairing_workspace_id: socket.assigns[:pairing_workspace_id],
      device_link_id: socket.assigns[:device_link_id],
      platform: socket.assigns[:mobile_platform],
      origin_id: socket.assigns[:mobile_origin_id] || Origin.id()
    }
  end

  defp render_snapshot(%{user_id: user_id, version: version, cards: cards}, socket) do
    %{
      user_id: user_id,
      version: version,
      origin: %{
        id: socket.assigns[:mobile_origin_id] || Origin.id(),
        display_name: socket.assigns[:mobile_origin_name] || Origin.display_name()
      },
      cards: Enum.map(cards, &render_card(&1, socket))
    }
  end

  defp render_card(card, socket) do
    resume = ResumeCard.project(card)
    intervention = Intervention.describe(card)
    evidence = Evidence.project(card, socket.assigns[:current_user] || %{})
    actions = intervention_actions(card, intervention)

    %{
      id: card.id,
      origin: render_value(resume.origin),
      resume: render_value(resume),
      type: Atom.to_string(card.type),
      # Normalized contract (v1). Legacy keys below remain for existing native
      # consumers until the native client migrates to `actions`.
      source: Map.get(card, :source, "casein"),
      kind: Map.get(card, :kind, Atom.to_string(card.type)),
      status: Map.get(card, :status, "open"),
      resource: render_value(Map.get(card, :resource, %{})),
      actions: Enum.map(actions, &render_action_spec/1),
      intervention: render_intervention(intervention),
      evidence: render_evidence(evidence),
      pwa_url: CaseinWeb.Endpoint.url() <> Intervention.pwa_path(card),
      context:
        card
        |> Map.get(:context, %{})
        |> Map.drop([:files_changed, "files_changed", :diff_preview, "diff_preview"])
        |> render_value(),
      priority: Atom.to_string(card.priority),
      user_id: card.user_id,
      workspace_id: card.workspace_id,
      workspace_name: card.workspace_name,
      session_id: card.session_id,
      title: card.title,
      body: card.body,
      action: render_action(card.action),
      secondary_actions: Enum.map(card.secondary_actions, &render_action/1),
      meta:
        card.meta
        |> Map.drop([:files_changed, "files_changed", :diff_preview, "diff_preview"])
        |> render_value(),
      created_at: render_value(card.created_at),
      updated_at: render_value(card.updated_at),
      expires_at: render_value(card.expires_at)
    }
  end

  defp intervention_actions(card, nil), do: Map.get(card, :actions, [])

  defp intervention_actions(card, %{action: action}) do
    actions = Map.get(card, :actions, [])

    if Enum.any?(actions, &(Map.get(&1, :id) == action.id)),
      do: actions,
      else: actions ++ [action]
  end

  defp render_intervention(nil), do: nil

  defp render_intervention(intervention) do
    intervention
    |> Map.delete(:pwa_path)
    |> Map.put(:pwa_url, CaseinWeb.Endpoint.url() <> intervention.pwa_path)
    |> render_value()
  end

  defp render_evidence(nil), do: nil

  defp render_evidence(evidence) do
    evidence
    |> update_in([:artifact], &qualify_evidence_artifact/1)
    |> update_in([:links], fn links -> Enum.map(links || [], &qualify_evidence_link/1) end)
    |> render_value()
  end

  defp qualify_evidence_artifact(nil), do: nil

  defp qualify_evidence_artifact(artifact) do
    artifact
    |> Map.put(:pwa_url, CaseinWeb.Endpoint.url() <> artifact.pwa_path)
    |> Map.delete(:pwa_path)
  end

  defp qualify_evidence_link(link) do
    link
    |> Map.put(:url, CaseinWeb.Endpoint.url() <> link.path)
    |> Map.delete(:path)
  end

  # Action specs may carry a `:route` tuple (navigation actions); convert it to a
  # JSON-encodable map. Everything else renders generically.
  defp render_action_spec(spec) when is_map(spec) do
    Map.new(spec, fn
      {:route, route} -> {"route", render_route(route)}
      {key, value} -> {to_string(key), render_value(value)}
    end)
  end

  defp render_action(nil), do: nil

  defp render_action(%{label: label, route: route}) do
    %{label: label, route: render_route(route)}
  end

  defp render_action(%{} = action) do
    action
    |> Map.drop([:route, "route"])
    |> Map.put(:route, render_route(Map.get(action, :route) || Map.get(action, "route")))
    |> render_value()
  end

  defp render_route({:session_detail, workspace_id, session_id}) do
    %{type: "session_detail", workspace_id: workspace_id, session_id: session_id}
  end

  defp render_route({:retry_workspace, workspace_id}) do
    %{type: "retry_workspace", workspace_id: workspace_id}
  end

  defp render_route({:pair_workspace, workspace_id}) do
    %{type: "pair_workspace", workspace_id: workspace_id}
  end

  defp render_route(route), do: render_value(route)

  defp render_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp render_value(value) when is_atom(value), do: Atom.to_string(value)
  defp render_value(value) when is_list(value), do: Enum.map(value, &render_value/1)

  defp render_value(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), render_value(nested)} end)
  end

  defp render_value(value), do: value
end
