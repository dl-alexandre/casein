defmodule CaseinPreviewBrowser do
  @moduledoc """
  Public facade for supervised preview browser sessions.

  This module is the stable Elixir boundary that Casein should eventually call
  through an adapter. Browser backend details stay behind
  `CaseinPreviewBrowser.Backend`.
  """

  alias CaseinPreviewBrowser.{Browser, Screenshot, Session}

  @type browser :: Browser.t()
  @type observation :: map()
  @type cdp_result :: map()

  @doc """
  Start a browser-runtime session.

  Options:

    * `:backend` - backend module implementing `CaseinPreviewBrowser.Backend`
    * `:event_owner` - process receiving `{:preview_browser, browser_id, event}`
      messages. Defaults to the caller.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: Session.start_link(opts)

  @doc "Open a browser instance in a running session."
  @spec open_browser(GenServer.server(), keyword()) :: {:ok, browser()} | {:error, term()}
  def open_browser(session, opts \\ []), do: Session.open_browser(session, opts)

  @doc "Navigate a browser to a URL."
  @spec navigate(browser(), String.t()) :: {:ok, observation()} | {:error, term()}
  def navigate(%Browser{} = browser, url) when is_binary(url),
    do: Session.navigate(browser, url)

  @doc "Return the latest backend observation for a browser."
  @spec observe(browser()) :: {:ok, observation()} | {:error, term()}
  def observe(%Browser{} = browser), do: Session.observe(browser)

  @doc "Send a Chrome DevTools Protocol command through the active backend."
  @spec cdp(browser(), String.t(), map()) :: {:ok, cdp_result()} | {:error, term()}
  def cdp(%Browser{} = browser, method, params \\ %{})
      when is_binary(method) and is_map(params),
      do: Session.cdp(browser, method, params)

  @doc "Capture a screenshot from a browser."
  @spec screenshot(browser(), keyword()) :: {:ok, Screenshot.t()} | {:error, term()}
  def screenshot(%Browser{} = browser, opts \\ []), do: Session.screenshot(browser, opts)

  @doc "Close a browser instance."
  @spec close(browser()) :: :ok | {:error, term()}
  def close(%Browser{} = browser), do: Session.close(browser)

  @doc false
  @spec emit_event(GenServer.server(), Browser.id(), term()) :: :ok
  def emit_event(session, browser_id, event), do: Session.emit_event(session, browser_id, event)
end
