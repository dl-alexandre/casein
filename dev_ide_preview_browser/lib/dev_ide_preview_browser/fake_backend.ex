defmodule DevIDEPreviewBrowser.FakeBackend do
  @moduledoc """
  In-memory backend for tests and early integration work.

  It exercises the public contract without starting a native browser runtime.
  """

  @behaviour DevIDEPreviewBrowser.Backend

  alias DevIDEPreviewBrowser.Screenshot

  defstruct browsers: %{}, commands: []

  @impl true
  def start_runtime(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def open_browser(%__MODULE__{} = state, browser_id, opts) do
    ref = {:fake_browser, browser_id}
    url = Keyword.get(opts, :url, "about:blank")
    browser = %{id: browser_id, url: url, title: title_for(url), closed?: false}
    {:ok, put_in(state.browsers[ref], browser), ref}
  end

  @impl true
  def navigate(%__MODULE__{} = state, ref, url) when is_binary(url) do
    with {:ok, browser} <- fetch_open_browser(state, ref) do
      browser = %{browser | url: url, title: title_for(url)}
      state = put_in(state.browsers[ref], browser)

      {:ok, state,
       %{
         url: url,
         title: browser.title,
         status: 200,
         backend: :fake
       }}
    end
  end

  @impl true
  def observe(%__MODULE__{} = state, ref) do
    with {:ok, browser} <- fetch_open_browser(state, ref) do
      {:ok,
       %{
         url: browser.url,
         title: browser.title,
         status: 200,
         backend: :fake
       }}
    end
  end

  @impl true
  def cdp(%__MODULE__{} = state, ref, method, params)
      when is_binary(method) and is_map(params) do
    with {:ok, browser} <- fetch_open_browser(state, ref) do
      result =
        case method do
          "Page.getNavigationHistory" ->
            %{
              "currentIndex" => 0,
              "entries" => [
                %{"id" => 1, "url" => browser.url, "title" => browser.title}
              ]
            }

          _ ->
            %{
              "method" => method,
              "params" => params,
              "url" => browser.url
            }
        end

      state = %{state | commands: [{ref, method, params} | state.commands]}
      {:ok, state, result}
    end
  end

  @impl true
  def screenshot(%__MODULE__{} = state, ref, opts) do
    with {:ok, browser} <- fetch_open_browser(state, ref) do
      format = opts |> Keyword.get(:format, "png") |> to_string()

      screenshot = %Screenshot{
        mime_type: "image/#{format}",
        bytes: "fake screenshot for #{browser.url}",
        metadata: %{url: browser.url, backend: :fake}
      }

      {:ok, state, screenshot}
    end
  end

  @impl true
  def close_browser(%__MODULE__{} = state, ref) do
    with {:ok, browser} <- fetch_open_browser(state, ref) do
      {:ok, put_in(state.browsers[ref], %{browser | closed?: true})}
    end
  end

  @impl true
  def stop_runtime(_state), do: :ok

  defp fetch_open_browser(%__MODULE__{} = state, ref) do
    case Map.fetch(state.browsers, ref) do
      {:ok, %{closed?: false} = browser} -> {:ok, browser}
      {:ok, %{closed?: true}} -> {:error, :browser_closed}
      :error -> {:error, :browser_not_found}
    end
  end

  defp title_for("about:blank"), do: "Blank"
  defp title_for(url), do: URI.parse(url).host || url
end
