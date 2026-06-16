defmodule PreviewCtl.Test.FakeAdapter do
  @moduledoc """
  In-memory browser simulation for tests and local development.

  Maintains a tiny DOM model so agents can exercise the preview control API
  without a real browser.
  """

  @behaviour PreviewCtl.Adapter

  @impl true
  def start_session(%{current_url: url}) when is_binary(url) do
    {:ok, base_state(url)}
  end

  def start_session(_), do: {:error, :missing_url}

  @impl true
  def navigate(state, url) do
    state =
      state
      |> put_history_url(url)
      |> Map.put(:dom, default_dom(url))

    {:ok, state, observation(state)}
  end

  @impl true
  def go_back(state) do
    state = move_history(state, -1)
    {:ok, state, observation(state)}
  end

  @impl true
  def go_forward(state) do
    state = move_history(state, 1)
    {:ok, state, observation(state)}
  end

  @impl true
  def reload(state) do
    state = %{state | dom: default_dom(state.current_url)}
    {:ok, state, observation(state)}
  end

  @impl true
  def observe(state), do: {:ok, observation(state)}

  @impl true
  def observe_live(state), do: {:ok, state, observation(state)}

  @impl true
  def click(state, %{selector: selector}) when is_binary(selector) do
    if selector in state.dom.selectors do
      state =
        state
        |> maybe_navigate_anchor(selector)
        |> put_in([:dom, :last_clicked], selector)

      {:ok, state, observation(state)}
    else
      {:error, :selector_not_found}
    end
  end

  def click(state, %{x: x, y: y}) when is_integer(x) and is_integer(y) do
    state = put_in(state.dom.last_point, %{x: x, y: y})
    {:ok, state, observation(state)}
  end

  def click(_state, _), do: {:error, :invalid_target}

  @impl true
  def type(state, selector, text)
      when is_binary(selector) and is_binary(text) do
    if selector in state.dom.selectors do
      values = Map.put(state.dom.values, selector, text)
      state = put_in(state.dom.values, values)
      {:ok, state}
    else
      {:error, :selector_not_found}
    end
  end

  @impl true
  def press(state, key) when is_binary(key) do
    keys = [key | state.dom.keys_pressed]
    state = put_in(state.dom.keys_pressed, Enum.take(keys, 8))
    {:ok, state}
  end

  @impl true
  def screenshot(state) do
    artifact =
      "data:image/png;base64," <>
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGA" <>
        "WjR9awAAAABJRU5ErkJggg=="

    obs = Map.put(observation(state), :screenshot, %{artifact: artifact, simulated: true})
    {:ok, state, obs, artifact}
  end

  @impl true
  def get_storage(state) do
    storage = %{
      url: state.current_url,
      local_storage: state.dom.local_storage,
      session_storage: state.dom.session_storage,
      console_errors: state.dom.console_errors,
      network_errors: state.dom.network_errors
    }

    {:ok, state, storage}
  end

  @impl true
  def close(_state), do: :ok

  defp base_state(url) do
    %{
      current_url: url,
      history: [url],
      history_index: 0,
      dom: default_dom(url)
    }
  end

  defp maybe_navigate_anchor(state, selector) do
    case Regex.run(~r/^a\[href="([^"]+)"\]$/, selector) do
      [_, href] ->
        url = PreviewCtl.Origin.resolve_against(href, state.current_url)

        state
        |> put_history_url(url)
        |> Map.put(:dom, default_dom(url))

      _ ->
        state
    end
  end

  defp put_history_url(state, url) do
    current_index = Map.get(state, :history_index, 0)

    history =
      state
      |> Map.get(:history, [state.current_url])
      |> Enum.take(current_index + 1)

    %{state | current_url: url}
    |> Map.put(:history, history ++ [url])
    |> Map.put(:history_index, length(history))
  end

  defp move_history(state, offset) do
    history = Map.get(state, :history, [state.current_url])
    current_index = Map.get(state, :history_index, 0)
    next_index = current_index + offset

    if next_index >= 0 and next_index < length(history) do
      url = Enum.at(history, next_index)

      state
      |> Map.put(:current_url, url)
      |> Map.put(:history_index, next_index)
      |> Map.put(:dom, default_dom(url))
    else
      state
    end
  end

  defp default_dom(url) do
    %{
      title: "Preview — #{URI.parse(url).host || "page"}",
      selectors: [
        "body",
        "main",
        "h1",
        "button[type=submit]",
        "#app",
        ~s(a[href="/settings"]),
        ~s(a[href="https://example.com/news"])
      ],
      values: %{},
      local_storage: %{},
      session_storage: %{},
      keys_pressed: [],
      last_clicked: nil,
      last_point: nil,
      console_errors: [],
      network_errors: []
    }
  end

  defp observation(state) do
    %{
      url: state.current_url,
      title: state.dom.title,
      dom_summary: %{
        selectors: state.dom.selectors,
        values: state.dom.values,
        last_clicked: state.dom.last_clicked,
        last_point: state.dom.last_point
      },
      console_errors: state.dom.console_errors,
      network_errors: state.dom.network_errors
    }
  end
end
