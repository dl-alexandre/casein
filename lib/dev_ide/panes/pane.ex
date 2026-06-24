defmodule DevIDE.Panes.Pane do
  @moduledoc """
  Uniform abstraction for a workspace pane, regardless of what lives inside it.

  Both classic terminal panes (PTY-backed, rendered server-side via Ghostty) and
  feature panes (e.g. preview surfaces) implement this behaviour. The layout engine,
  the session-template/reconcile pipeline, and the focus model treat every pane
  through these callbacks, so a new pane type slots into any layout without special
  casing.

  ## What this behaviour does *not* change (preserved invariants)

    * **Input-ownership ladder stays `global > leader > pane content`.** Global keys
      (`palette_hook.js`) and the `C-b` leader (`workspace_leader.js`) are intercepted
      in the browser capture phase *before* a pane's `c:handle_input/2` ever runs.
      Implementing this behaviour does not let a pane claim global keys.

    * **Agents declare intent only; dev_ide owns placement/geometry.** `c:attach/2` is
      invoked by the execute/reconcile pipeline, never by an MCP/agent tool. No pane
      type may expose geometry mutation to an agent.

  ## Geometry

  This behaviour is deliberately geometry-agnostic. tmux remains the geometry
  *allocator* (a pane rides a real tmux pane's rectangle) and the web layer remains
  the *renderer*. Lifting geometry allocation into dev_ide ("Tier 2") is out of scope
  and gated on the per-pane PTY cost becoming a measured problem.
  """

  @typedoc "Pane kind. `:terminal` is the default for back-compat with existing templates."
  @type pane_type :: :terminal | :preview

  @typedoc "Resolved template leaf describing a pane to bring to life."
  @type node_spec :: map()

  @typedoc "Context threaded from the execute/reconcile pipeline (workspace, session, tmux pane id, ...)."
  @type ctx :: map()

  @typedoc "Opaque backend handle. Terminal: a `PaneWorker`-managed ref. Preview: a `PreviewPanes` pane id."
  @type pane_ref :: term()

  @typedoc """
  Focus signal, mirroring `SessionOwner` subscriber tracking: an active flag plus a
  monotonic sequence used to pick the most-recently-active viewer.
  """
  @type focus :: {active? :: boolean(), seq :: integer()}

  @typedoc """
  Payload pushed to the browser for one render tick.

    * Terminal: `%{rows: [...]}` (row diff) or `%{cells: [...]}` (full frame).
    * Preview: `%{rect: map(), screenshot: term()}`.
  """
  @type render_payload :: map()

  @typedoc "Normalized input event routed into a pane (key/text for terminal; click/type/navigate for preview)."
  @type input :: map()

  # --- Pipeline-facing callbacks (required) -------------------------------------
  # These three are what the execute/reconcile pipeline and template export need to
  # treat any pane type uniformly. Every implementer wires them in this increment.

  @doc """
  Start the pane's backend on an already-allocated slot and return a handle.

  Called by the execute/reconcile pipeline after geometry exists (the slot is a real
  tmux pane). Must be idempotent for a given slot so a reconcile re-run does not
  double-attach. On failure it must return `{:error, reason}` so the pipeline can
  record a degraded pane rather than crash the reconcile.

  Terminal panes are created by the standard tmux split/`send_command` steps, so the
  terminal implementation treats `attach/2` as a no-op acknowledgment.
  """
  @callback attach(node_spec(), ctx()) :: {:ok, pane_ref()} | {:error, term()}

  @doc "Serialize the pane to a template JSON fragment. Must include the pane `\"type\"`."
  @callback serialize(pane_ref()) :: map()

  @doc "Tear down the pane's backend."
  @callback terminate(pane_ref()) :: :ok

  # --- Runtime callbacks (optional this increment) ------------------------------
  # The runtime surface (render/input/focus) is still served by the existing
  # per-pane machinery: terminals via `PaneWorker` + the LiveView terminal
  # component, previews via `PreviewPanes` + the JS overlay. Routing terminals
  # through these callbacks (so render/input/focus are uniform too) is the larger
  # follow-up; previews implement them now because they are cleanly callable from a
  # pane id.

  @doc "Produce the current render payload pushed to connected viewers."
  @callback render_payload(pane_ref()) :: render_payload()

  @doc "Route a normalized input event into the pane backend."
  @callback handle_input(pane_ref(), input()) :: :ok | {:error, term()}

  @doc "Apply the focus signal (drives focused-viewer sizing for terminals; visibility for previews)."
  @callback set_active(pane_ref(), active? :: boolean()) :: :ok

  @optional_callbacks render_payload: 1, handle_input: 2, set_active: 2

  @impls %{terminal: DevIDE.Panes.Terminal, preview: DevIDE.Panes.Preview}

  @doc """
  Resolve the implementation module for a pane type. Single dispatch point so call
  sites stay type-agnostic. Implementations can be overridden per type via the
  `:pane_impls` app env (used in tests to stub the preview backend).
  """
  @spec impl(pane_type()) :: module()
  def impl(type) when is_atom(type) do
    @impls
    |> Map.merge(Application.get_env(:dev_ide, :pane_impls, %{}))
    |> Map.fetch!(type)
  end

  @doc "Known pane types."
  @spec types() :: [pane_type()]
  def types, do: Map.keys(@impls)
end
