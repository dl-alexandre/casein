defmodule DevIDE.PreviewControl.PlaywrightAdapter do
  @moduledoc """
  Browser-backed preview control via HTTP observation and optional Playwright.

  Navigation and static observation use `Req` against trusted workspace URLs.
  Live observation, storage inspection, click, type, press, and screenshot
  delegate to a Node Playwright helper when `preview_playwright_script` is
  configured; otherwise live observation falls back to static observation and
  the other browser actions return `{:error, :playwright_unavailable}`.
  """

  @behaviour DevIDE.PreviewControl.Adapter

  @impl true
  def start_session(%{current_url: url}) when is_binary(url) do
    {:ok, %{current_url: url, browser_id: browser_id()}}
  end

  def start_session(_), do: {:error, :missing_url}

  @impl true
  def navigate(state, url) do
    with {:ok, body} <- fetch(url),
         {:ok, summary} <- summarize_html(body, url) do
      state = %{state | current_url: url}
      {:ok, state, observation(state, summary)}
    end
  end

  @impl true
  def observe(state) do
    with {:ok, body} <- fetch(state.current_url),
         {:ok, summary} <- summarize_html(body, state.current_url) do
      {:ok, observation(state, summary)}
    end
  end

  @impl true
  def observe_live(state) do
    case playwright_command(state, "observe_live", %{}) do
      {:ok, new_state, obs, _} -> {:ok, new_state, obs}
      {:error, _reason} -> observe_live_fallback(state)
    end
  end

  @impl true
  def click(state, target) do
    case playwright_command(state, "click", target) do
      {:ok, new_state, obs, _} -> {:ok, new_state, obs}
      other -> other
    end
  end

  @impl true
  def type(state, selector, text) do
    case playwright_command(state, "type", %{selector: selector, text: text}) do
      {:ok, new_state, _obs, _} -> {:ok, new_state}
      other -> other
    end
  end

  @impl true
  def press(state, key) do
    case playwright_command(state, "press", %{key: key}) do
      {:ok, new_state, _obs, _} -> {:ok, new_state}
      other -> other
    end
  end

  @impl true
  def screenshot(state) do
    case playwright_command(state, "screenshot", %{}) do
      {:ok, state, obs, artifact} ->
        {:ok, state, obs, artifact}

      {:error, :playwright_unavailable} ->
        with {:ok, body} <- fetch(state.current_url),
             {:ok, summary} <- summarize_html(body, state.current_url) do
          obs =
            observation(state, summary)
            |> Map.put(:screenshot, %{simulated: true, note: "playwright unavailable"})

          {:ok, state, obs, nil}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def get_storage(state) do
    case playwright_raw_command(state, "get_storage", %{}) do
      {:ok, result} ->
        {new_state, storage} = decode_storage_result(result, state)
        {:ok, new_state, storage}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def close(%{browser_id: id}) when is_binary(id) do
    _ = playwright_command(%{current_url: "", browser_id: id}, "close", %{})
    :ok
  end

  def close(_), do: :ok

  defp observe_live_fallback(state) do
    with {:ok, obs} <- observe(state) do
      {:ok, state, obs}
    end
  end

  defp fetch(url) do
    # redirect: false is a security boundary: PreviewControl validates `url` against
    # the session's allowed origins before we get here, but Req follows redirects by
    # default. A trusted localhost/workspace URL that responds 3xx -> internal host
    # (e.g. cloud metadata) would otherwise be fetched and summarized back to the
    # agent, bypassing the origin gate. Treat redirects as a non-2xx response.
    case Req.get(url,
           redirect: false,
           connect_options: [timeout: 10_000],
           receive_timeout: 15_000
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_binary(body) ->
        {:ok, body}

      {:ok, %{status: status} = resp} when status in 300..399 ->
        {:error, {:redirect_blocked, status, redirect_location(resp)}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_status, status, truncate(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp redirect_location(%{headers: headers}) when is_map(headers) do
    case Map.get(headers, "location") do
      [loc | _] -> loc
      loc when is_binary(loc) -> loc
      _ -> nil
    end
  end

  defp redirect_location(_), do: nil

  defp summarize_html(body, url) do
    title =
      case Regex.run(~r/<title[^>]*>(.*?)<\/title>/i, body) do
        [_, title] -> String.trim(title)
        _ -> nil
      end

    headings =
      ~r/<h[1-3][^>]*>(.*?)<\/h[1-3]>/i
      |> Regex.scan(body)
      |> Enum.map(fn [_, text] -> strip_tags(text) end)
      |> Enum.take(6)

    links =
      ~r/<a[^>]+href=["']([^"']+)["'][^>]*>(.*?)<\/a>/i
      |> Regex.scan(body)
      |> Enum.map(fn [_, href, text] ->
        %{href: href, text: strip_tags(text)}
      end)
      |> Enum.take(12)

    {:ok,
     %{
       title: title,
       headings: headings,
       links: links,
       byte_size: byte_size(body),
       url: url
     }}
  end

  defp observation(state, summary \\ %{}) do
    %{
      url: state.current_url,
      title: Map.get(summary, :title),
      dom_summary: summary,
      console_errors: [],
      network_errors: []
    }
  end

  defp playwright_command(state, action, params) do
    case playwright_raw_command(state, action, params) do
      {:ok, result} ->
        decode_playwright_result(result, state)

      {:error, :playwright_unavailable} ->
        {:error, :playwright_unavailable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp playwright_raw_command(state, action, params) do
    payload = %{
      action: action,
      url: state.current_url,
      browser_id: Map.get(state, :browser_id),
      params: params
    }

    case DevIDE.PreviewControl.PlaywrightBridge.command(payload) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_playwright_result(result, state) do
    result_url = result["url"] || state.current_url
    new_state = %{state | current_url: result_url}

    obs =
      result
      |> Map.get("observation", observation(new_state))
      |> normalize_observation()

    new_state =
      new_state
      |> Map.put(:current_url, obs[:url] || result_url)
      |> Map.put(:last_observation, obs)

    {:ok, new_state, obs, Map.get(result, "artifact")}
  end

  defp decode_storage_result(result, state) do
    result_url = result["url"] || state.current_url

    storage = %{
      url: result_url,
      local_storage: map_value(result, :local_storage) || %{},
      session_storage: map_value(result, :session_storage) || %{},
      console_errors: map_value(result, :console_errors) || [],
      network_errors: map_value(result, :network_errors) || []
    }

    new_state =
      state
      |> Map.put(:current_url, result_url)
      |> Map.put(:last_storage, storage)

    {new_state, storage}
  end

  defp normalize_observation(%{} = obs) do
    %{
      url: map_value(obs, :url),
      title: map_value(obs, :title),
      dom_summary: normalize_summary(map_value(obs, :dom_summary) || %{}),
      console_errors: map_value(obs, :console_errors) || [],
      network_errors: map_value(obs, :network_errors) || []
    }
    |> maybe_put(:screenshot, map_value(obs, :screenshot))
  end

  defp normalize_observation(_), do: %{}

  defp normalize_summary(%{} = summary) do
    %{
      title: map_value(summary, :title),
      headings: map_value(summary, :headings) || [],
      links: map_value(summary, :links) || [],
      visible_text: map_value(summary, :visible_text),
      byte_size: map_value(summary, :byte_size),
      url: map_value(summary, :url)
    }
  end

  defp normalize_summary(_), do: %{}

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp browser_id do
    "pw-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp strip_tags(text) do
    text
    |> String.replace(~r/<[^>]+>/, "")
    |> String.trim()
  end

  defp truncate(data) when is_binary(data) do
    if byte_size(data) > 400, do: String.slice(data, 0, 400) <> "…", else: data
  end

  defp truncate(data), do: inspect(data)
end
