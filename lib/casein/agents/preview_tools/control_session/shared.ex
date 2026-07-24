defmodule Casein.Agents.PreviewTools.ControlSession.Shared do
  alias Casein.PreviewPanes
  alias Casein.Previews.Url
  @moduledoc false

  alias Casein.Previews.Deps
  alias Casein.Previews

  def health_error(reason) when is_atom(reason), do: reason
  def health_error(reason) when is_binary(reason), do: reason
  def health_error(reason), do: inspect(reason)

  def observation_url(%{url: url}) when is_binary(url), do: url
  def observation_url(%{"url" => url}) when is_binary(url), do: url
  def observation_url(_), do: nil

  def kill_preview_pane(tmux_session, pane_id)
      when is_binary(tmux_session) and tmux_session != "" and is_binary(pane_id) and
             pane_id != "" do
    terminals().kill_pane(tmux_session, pane_id)
  end

  def kill_preview_pane(_tmux_session, _pane_id), do: {:error, :tmux_session_required}

  def ensure_tmux_pane_exists(tmux_session, pane_id)
      when is_binary(tmux_session) and is_binary(pane_id) do
    if tmux_pane_exists?(tmux_session, pane_id) do
      :ok
    else
      _ = PreviewPanes.deregister(pane_id)

      {:error,
       %{
         error: :preview_pane_exited,
         pane_id: pane_id,
         tmux_session: tmux_session,
         message: "Preview pane exited before it could be shown; no preview pane was opened."
       }}
    end
  end

  def ensure_tmux_pane_exists(_tmux_session, _pane_id), do: :ok

  def tmux_pane_exists?(tmux_session, pane_id) do
    tmux_session
    |> terminals().list_session_panes()
    |> Enum.any?(&(Map.get(&1, :id) == pane_id))
  end

  def preview_api_token do
    System.get_env("CASEIN_API_TOKEN") ||
      Application.get_env(:casein, :casein_api_token)
  end

  def preview_api_base_url do
    cond do
      url = System.get_env("DEVIDE_URL") ->
        url

      host = System.get_env("PHX_HOST") ->
        "https://#{host}"

      true ->
        nil
    end
  end

  def workspace_host_path(workspace) do
    case workspaces().safe_host_path(workspace) do
      {:ok, path} -> path
      _ -> nil
    end
  end

  def viewport_string(%{width: width, height: height})
      when is_integer(width) and is_integer(height),
      do: "#{width}x#{height}"

  def viewport_string(viewport) when is_binary(viewport), do: viewport
  def viewport_string(_), do: nil

  def workspaces, do: Deps.impl(:workspaces)

  def terminals, do: Deps.impl(:terminals)

  def shell_quote(value) when is_binary(value) do
    if String.match?(value, ~r"^[A-Za-z0-9_.,:/%@+-]+$") do
      value
    else
      "'" <> String.replace(value, "'", "'\\''") <> "'"
    end
  end

  def errors_payload(data) when is_map(data) do
    %{
      console_errors:
        Map.get(data, "console_errors") || Map.get(data, :console_errors) ||
          Map.get(data, "errors") || Map.get(data, :errors) || [],
      network_errors: Map.get(data, "network_errors") || Map.get(data, :network_errors) || []
    }
  end

  def ensure_pane_workspace_scope(workspace, registration_workspace_id) do
    workspace
    |> workspace_id()
    |> case do
      id when is_binary(id) and id != "" ->
        if registration_workspace_id in workspaces().viewer_ids(id),
          do: :ok,
          else: {:error, :not_found}

      _ ->
        :ok
    end
  end

  def activity_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(50)

  def activity_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {int, ""} -> activity_limit(int)
      _ -> 10
    end
  end

  def activity_limit(_), do: 10

  defp snapshot_display_url?(display_url) when is_binary(display_url) do
    String.contains?(display_url, "/preview-artifacts/")
  end

  defp snapshot_display_url?(_), do: false

  def preview_mode(%{display_url: display_url}) when is_binary(display_url) do
    if snapshot_display_url?(display_url), do: "snapshot", else: "iframe"
  end

  def preview_mode(_), do: "unknown"

  def preview_status(registration) do
    case preview_mode(registration) do
      "snapshot" -> "snapshot_controlled"
      "iframe" -> "iframe_live"
      _ -> "unknown"
    end
  end

  def preview_title(registration, latest_observation) do
    dom_title =
      latest_observation
      |> observation_data()
      |> dom_summary_title()

    cond do
      is_binary(dom_title) and dom_title != "" ->
        dom_title

      is_binary(registration.display_url) and registration.display_url != "" ->
        Previews.extract_title_from_url(registration.display_url)

      true ->
        "Preview"
    end
  end

  def dom_summary_title(%{"dom_summary" => %{"title" => title}}), do: title
  def dom_summary_title(%{dom_summary: %{title: title}}), do: title
  def dom_summary_title(%{"title" => title}), do: title
  def dom_summary_title(%{title: title}), do: title
  def dom_summary_title(_), do: nil

  # The real site behind a snapshot pane: prefer the URL we resolved and stored
  # at capture time, falling back to the `<base href>`/canonical we parsed from a
  # statically-served HTML capture (e.g. the durable preview demo).
  def pane_source_url(registration, latest_observation) do
    case Map.get(registration, :source_url) do
      source_url when is_binary(source_url) and source_url != "" ->
        source_url

      _ ->
        latest_observation
        |> observation_data()
        |> dom_summary_source_url()
    end
  end

  defp dom_summary_source_url(%{"dom_summary" => %{"source_url" => url}}), do: url
  defp dom_summary_source_url(%{dom_summary: %{source_url: url}}), do: url
  defp dom_summary_source_url(%{"source_url" => url}), do: url
  defp dom_summary_source_url(%{source_url: url}), do: url
  defp dom_summary_source_url(_), do: nil

  def observation_payload(nil), do: nil

  def observation_payload(observation) do
    %{
      kind: Map.get(observation, :kind),
      data: observation_data(observation),
      artifact_path: Map.get(observation, :artifact_path),
      inserted_at: datetime_iso(Map.get(observation, :inserted_at))
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, %{}] end)
    |> Map.new()
  end

  defp observation_data(nil), do: %{}
  defp observation_data(%{data: data}) when is_map(data), do: data
  defp observation_data(_), do: %{}

  def activity_payload(nil), do: nil

  def activity_payload(activity) do
    %{
      id: activity.id,
      pane_id: activity.pane_id,
      session_id: activity.session_id,
      preview_id: activity.preview_id,
      source: Atom.to_string(activity.source),
      event: activity.event,
      summary: activity.summary,
      metadata: activity.metadata,
      inserted_at: datetime_iso(activity.inserted_at)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  def datetime_iso(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  def datetime_iso(%NaiveDateTime{} = datetime),
    do: datetime |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  def datetime_iso(_), do: nil

  def session_payload(session, navigation \\ %{}) do
    navigation = navigation || %{}
    navigated_to = Map.get(navigation, :navigated_to)

    payload = %{
      session_id: session.id,
      workspace_id: session.workspace_id,
      preview_id: session.preview_id,
      surface: session.surface,
      current_url: navigated_to || session.current_url,
      display_url: session.metadata["display_url"],
      mode:
        if(snapshot_display_url?(session.metadata["display_url"]), do: "snapshot", else: "iframe"),
      snapshot_mode: snapshot_display_url?(session.metadata["display_url"]),
      adapter: session.adapter
    }

    payload
    |> maybe_put_navigated_to(Map.get(navigation, :navigated_to))
    |> maybe_put_navigation_failed(Map.get(navigation, :navigation_failed))
  end

  defp maybe_put_navigated_to(payload, navigated_to)
       when is_binary(navigated_to) and navigated_to != "" do
    Map.put(payload, :navigated_to, navigated_to)
  end

  defp maybe_put_navigated_to(payload, _), do: payload

  defp maybe_put_navigation_failed(payload, failed) when not is_nil(failed) do
    Map.put(payload, :navigation_failed, navigation_failure_payload(failed))
  end

  defp maybe_put_navigation_failed(payload, _), do: payload

  def navigation_failure_payload({:redirect_blocked, status, location}) do
    %{error: :redirect_blocked, status: status, location: location}
  end

  def navigation_failure_payload({:http_status, status, body}) do
    %{error: :http_status, status: status, body: body}
  end

  def navigation_failure_payload(reason) when is_map(reason), do: reason

  def navigation_failure_payload(reason) when is_atom(reason), do: %{error: reason}

  def navigation_failure_payload(reason), do: %{error: :navigation_failed, reason: reason}

  def loopback_devide_session?(%{current_url: url}) when is_binary(url),
    do: devide_loopback_url?(url)

  def loopback_devide_session?(_), do: false

  def devide_loopback_url?(url) do
    port = Application.get_env(:casein, :preview_loopback_port, 4000)

    Url.localhost_url?(url) and
      case URI.parse(url) do
        %URI{port: ^port} -> true
        %URI{port: nil} when port in [80, 443] -> true
        _ -> false
      end
  end

  def workspace_viewer_route(workspace) do
    case workspace_id(workspace) do
      id when is_binary(id) and id != "" -> workspaces().viewer_route_id(id)
      _ -> "/workspaces"
    end
  end

  def workspace_id(workspace) when is_map(workspace) do
    Map.get(workspace, :id) || Map.get(workspace, "id")
  end

  def workspace_id(_), do: nil

  def tool_opts(params, workspace) do
    [
      actor_id: Map.get(params, "actor_id") || Map.get(params, :actor_id),
      assignment_id: Map.get(params, "assignment_id") || Map.get(params, :assignment_id),
      tmux_session: string_param(params, :tmux_session),
      default_headers: default_headers(params, workspace),
      new_control_session: boolean_param(params, :new_control_session),
      force_new_pane: boolean_param(params, :force_new_pane),
      isolation_key: string_param(params, :isolation_key),
      storage_profile: storage_profile_param(params),
      storage_profile_name: string_param(params, :storage_profile_name),
      share_session: boolean_param(params, :share_session),
      attach_to_pane_id: string_param(params, :attach_to_pane_id)
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  def truthy_param?(params, key) when is_map(params) and is_atom(key),
    do: boolean_param(params, key) == true

  defp storage_profile_param(params) do
    case string_param(params, :storage_profile) do
      value when value in ["ephemeral", "workspace", "profile"] -> value
      _ -> nil
    end
  end

  def boolean_param(params, key) when is_map(params) and is_atom(key) do
    value = Map.get(params, Atom.to_string(key)) || Map.get(params, key)

    case value do
      value when value in [true, false] -> value
      value when value in ["true", "1", "yes"] -> true
      value when value in ["false", "0", "no"] -> false
      _ -> nil
    end
  end

  def string_param(params, key) when is_map(params) and is_atom(key) do
    case Map.get(params, Atom.to_string(key)) || Map.get(params, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp default_headers(params, workspace) do
    case Map.get(params, "default_headers") || Map.get(params, :default_headers) do
      headers when is_map(headers) ->
        sanitize_headers(headers)

      _ ->
        case workspace do
          ws when is_map(ws) -> workspaces().forward_auth_headers(ws)
          _ -> nil
        end
    end
  end

  defp sanitize_headers(headers) do
    headers
    |> Enum.flat_map(fn {key, value} ->
      key = to_string(key)

      cond do
        key == "" -> []
        String.contains?(key, ["\r", "\n", ":"]) -> []
        not is_binary(value) -> []
        String.contains?(value, ["\r", "\n"]) -> []
        true -> [{key, value}]
      end
    end)
    |> Enum.take(20)
    |> Map.new()
  end

  def guide_observation(observation, session_id) when is_map(observation) do
    put_preview_next(observation, "preview_elements", %{session_id: session_id})
  end

  def put_preview_next(payload, tool, args) when is_map(payload) and is_map(args) do
    payload
    |> Map.put(:next_tool, tool)
    |> Map.put(:next_arguments, args)
  end

  def first_element_args(session_id, [%{element_id: element_id} | _]),
    do: %{session_id: session_id, element_id: element_id}

  def first_element_args(session_id, _), do: %{session_id: session_id}

  def elements_from_observation(observation) when is_map(observation) do
    summary = map_get(observation, :dom_summary) || %{}

    summary
    |> summary_elements()
    |> Kernel.++(selector_elements(summary))
    |> Kernel.++(link_elements(summary))
    |> dedupe_elements()
    |> Enum.with_index(1)
    |> Enum.map(fn {element, index} ->
      element
      |> Map.put(:element_id, "el_#{index}")
      |> Map.put_new(:visible, true)
      |> Map.put_new(:clickable, clickable_element?(element))
      |> Map.put_new(:typeable, typeable_element?(element))
    end)
  end

  defp summary_elements(summary) when is_map(summary) do
    case map_get(summary, :elements) do
      elements when is_list(elements) ->
        elements
        |> Enum.flat_map(&normalize_element/1)

      _ ->
        []
    end
  end

  defp selector_elements(summary) when is_map(summary) do
    case map_get(summary, :selectors) do
      selectors when is_list(selectors) ->
        selectors
        |> Enum.filter(&is_binary/1)
        |> Enum.map(fn selector ->
          %{
            selector: selector,
            role: selector_role(selector),
            name: selector_name(selector),
            visible: true
          }
        end)

      _ ->
        []
    end
  end

  defp link_elements(summary) when is_map(summary) do
    case map_get(summary, :links) do
      links when is_list(links) ->
        links
        |> Enum.flat_map(fn link ->
          href = map_get(link, :href)
          text = map_get(link, :text)

          if is_binary(href) and href != "" do
            [
              %{
                selector: ~s(a[href="#{css_attr(href)}"]),
                role: "link",
                name: text || href,
                href: href,
                visible: true
              }
            ]
          else
            []
          end
        end)

      _ ->
        []
    end
  end

  defp normalize_element(%{} = element) do
    selector = map_get(element, :selector)

    if is_binary(selector) and selector != "" do
      [
        %{
          selector: selector,
          role: map_get(element, :role) || selector_role(selector),
          name: map_get(element, :name) || map_get(element, :text) || selector_name(selector),
          href: map_get(element, :href),
          tag: map_get(element, :tag),
          type: map_get(element, :type),
          visible: map_get(element, :visible) != false,
          bounds: map_get(element, :bounds)
        }
        |> compact_map()
      ]
    else
      []
    end
  end

  defp normalize_element(_), do: []

  def filter_elements(elements, query) when is_binary(query) and query != "" do
    needle = String.downcase(query)

    Enum.filter(elements, fn element ->
      [:role, :name, :selector]
      |> Enum.map(&(Map.get(element, &1) || ""))
      |> Enum.any?(fn value ->
        value |> to_string() |> String.downcase() |> String.contains?(needle)
      end)
    end)
  end

  def filter_elements(elements, _), do: elements

  defp dedupe_elements(elements) do
    elements
    |> Enum.reduce({MapSet.new(), []}, fn element, {seen, acc} ->
      selector = Map.get(element, :selector)

      if is_binary(selector) and not MapSet.member?(seen, selector) do
        {MapSet.put(seen, selector), [element | acc]}
      else
        {seen, acc}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp clickable_element?(element),
    do: Map.get(element, :role) in ["button", "link", "tab", "menuitem"]

  defp typeable_element?(element) do
    role = Map.get(element, :role)
    selector = Map.get(element, :selector) || ""

    role in ["textbox", "combobox", "searchbox"] or
      String.starts_with?(selector, "input") or String.starts_with?(selector, "textarea") or
      String.starts_with?(selector, "select")
  end

  defp selector_role("button" <> _), do: "button"
  defp selector_role("a[" <> _), do: "link"
  defp selector_role("input" <> _), do: "textbox"
  defp selector_role("textarea" <> _), do: "textbox"
  defp selector_role("select" <> _), do: "combobox"
  defp selector_role(_), do: "generic"

  defp selector_name(~s(a[href="/settings"])), do: "Settings"
  defp selector_name(~s(a[href="https://example.com/news"])), do: "News"
  defp selector_name("button[type=submit]"), do: "Submit"
  defp selector_name(selector), do: selector

  defp css_attr(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  def required_string(params, key) do
    case Map.get(params, Atom.to_string(key)) || Map.get(params, key) do
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:missing_argument, key}}
    end
  end

  def map_get(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        case Map.fetch(map, Atom.to_string(key)) do
          {:ok, value} -> value
          :error -> nil
        end
    end
  end

  def map_get(_map, _key), do: nil

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  def parse_id(id) when is_integer(id), do: {:ok, id}

  def parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> {:ok, int}
      _ -> {:error, :invalid_session_id}
    end
  end

  def parse_id(_), do: {:error, :invalid_session_id}

  # Thread an optional 0-based `nth` into the target/opts map when it is a
  # non-negative integer; ignore/strip any other value so a selector-only call
  # still produces a valid command.
  def maybe_put_nth(map, params) do
    case Map.get(params, "nth") || Map.get(params, :nth) do
      nth when is_integer(nth) and nth >= 0 -> Map.put(map, :nth, nth)
      _ -> map
    end
  end
end
