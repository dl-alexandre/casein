# CaseinPreviewBrowser

`CaseinPreviewBrowser` is a standalone browser-runtime boundary for Casein preview
work. It is intentionally kept separate from the Phoenix application so native
browser experiments can evolve without coupling CEF, Rustler, or external-process
lifecycle concerns to the main app.

The first implementation is a fake backend that proves the Elixir API, lifecycle,
event delivery, CDP command path, and screenshot contract. Real browser backends
should implement `CaseinPreviewBrowser.Backend` behind the same public facade.
`CaseinPreviewBrowser.ExternalBackend` provides the first process-isolated
backend boundary using a small newline-delimited JSON protocol.

## Initial contract

```elixir
{:ok, session} =
  CaseinPreviewBrowser.start_link(
    backend: CaseinPreviewBrowser.FakeBackend,
    event_owner: self()
  )

{:ok, browser} = CaseinPreviewBrowser.open_browser(session, url: "http://127.0.0.1:4000")
{:ok, observation} = CaseinPreviewBrowser.navigate(browser, "http://127.0.0.1:4000/page")
{:ok, result} = CaseinPreviewBrowser.cdp(browser, "Runtime.evaluate", %{"expression" => "1 + 1"})
{:ok, screenshot} = CaseinPreviewBrowser.screenshot(browser)
:ok = CaseinPreviewBrowser.close(browser)
```

Events are delivered as BEAM messages to the configured `:event_owner`:

```elixir
{:preview_browser, browser.id, {:load_started, url}}
{:preview_browser, browser.id, {:load_finished, url, status}}
{:preview_browser, browser.id, {:console, level, text}}
{:preview_browser, browser.id, {:crashed, reason}}
```

External backends should send events to the session process. The session records
the latest normalized `CaseinPreviewBrowser.Health` snapshot per browser and then
forwards the public event to `:event_owner`. When a backend observation does not
include health directly, `observe/1` can still return the most recent health
snapshot learned from asynchronous bridge events.

## PreviewCtl adapter boundary

`CaseinPreviewBrowser.Adapter` implements the same function-shaped surface as
`PreviewCtl.Adapter`, backed by this library's public API:

```elixir
{:ok, state} =
  CaseinPreviewBrowser.Adapter.start_session(%{
    current_url: "http://127.0.0.1:4000",
    event_owner: self()
  })

{:ok, state, observation} =
  CaseinPreviewBrowser.Adapter.navigate(state, "http://127.0.0.1:4000/page")
```

The adapter intentionally does not declare `@behaviour PreviewCtl.Adapter`
because this sibling package must compile independently from the host Casein app.
The host can wire it into `PreviewCtl.Session.adapter_for/1` later, after the
currently frozen preview/MCP integration paths are clear.

## Backend guidance

Keep real backends narrow:

- start a browser runtime
- create and close browser instances
- navigate
- send a minimal CDP command
- capture a screenshot
- emit lifecycle events

Prefer a supervised external-process backend before committing to long-lived CEF
inside the BEAM. A Rustler backend can use the same behaviour once crash behavior,
dirty scheduler use, resource lifetimes, and binary packaging are proven.

`native/cef_bridge` is only a dormant Rust scaffold for that possible future
backend. It is not wired into Mix, CI, or runtime startup.

## External process protocol

`CaseinPreviewBrowser.ExternalBackend` starts an executable and sends one JSON
object per line on stdin:

```json
{"id":"1","command":"navigate","payload":{"browser_ref":"browser-1","url":"http://127.0.0.1:4000"}}
```

The process replies on stdout with either:

```json
{"id":"1","ok":true,"result":{"url":"http://127.0.0.1:4000","title":"Casein","status":200}}
```

or:

```json
{"id":"1","ok":false,"error":"navigation_failed"}
```

It may also emit asynchronous events:

```json
{"type":"event","browser_id":"browser-1","event":["console","info","ready"]}
```

Screenshots should return `mime_type` plus either `data_base64` or `bytes`.
The Elixir side of this contract lives in
`CaseinPreviewBrowser.ExternalBackend.Protocol`.

## Playwright sidecar

`priv/sidecars/playwright_browser.mjs` is a real external browser sidecar for the
same protocol. It is intentionally a separate process: browser crashes and hangs
are converted into explicit Elixir errors/events by `ExternalBackend.Worker`.

Install the sidecar dependency and run the opt-in browser smoke test with:

```bash
cd dev_ide_preview_browser/priv/sidecars
npm install
cd ../..
mix test --include playwright
```
