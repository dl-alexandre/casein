defmodule CaseinWeb.LiveDiffMeasure do
  @moduledoc """
  **Measure-only** LiveView diff / assign payload instrumentation (#899).

  Two independent probes, neither of which changes render behaviour:

  1. **Wire** — `CaseinWeb.LiveDiffMeasure.Serializer` wraps
     `Phoenix.Socket.V2.JSONSerializer` and records iodata byte length of
     outbound LiveView messages (`diff` pushes and `phx_reply` payloads that
     carry a `diff`). This is the actual browser-bound payload size.

  2. **Changed assigns** — an `:after_render` hook on
     `CaseinWeb.WorkspaceLive.Show` samples `assigns.__changed__` and estimates
     each dirty key's contribution via `:erlang.term_to_binary/1` byte size.
     This is a *server-side* ranking aid (not wire bytes) so we can name the
     worst offenders without optimising them here.

  Findings land on telemetry:

    * `[:casein, :live_view, :diff_wire]` — `payload_bytes`, tags
      `event` / `kind` / `view`
    * `[:casein, :live_view, :changed_assigns]` — `payload_bytes`,
      `changed_count`, tags `view`; metadata carries `top` (ranked keys)

  Opt-in gate: `Application.get_env(:casein, :live_diff_measure, true)` in test
  and dev; production can set `CASEIN_LIVE_DIFF_MEASURE=0` or
  `config :casein, live_diff_measure: false` to silence. Default **on** so a
  deploy collects data without a second PR.

  ## Explicit non-goals (this module)

  * No `temporary_assigns`
  * No stream conversion
  * No `Map.take` / `__changed__` "fixes"
  * No render-path behaviour change beyond cheap measurement

  # do not add temporary_assigns/streams here (#899 is measure-only; a follow-up
  # issue owns optimisation once wire p95 ranks the offenders — zero
  # temporary_assigns fleet-wide is a FINDING not a mandate, and Map.take
  # + :__changed__ does not restore tracking on assigns-dependent templates).
  """

  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  @wire_event [:casein, :live_view, :diff_wire]
  @assigns_event [:casein, :live_view, :changed_assigns]
  @hook_name :casein_live_diff_measure
  @top_n 12
  @max_term_bytes 2_000_000

  @doc "Whether measurement is enabled (config / env)."
  @spec enabled?() :: boolean()
  def enabled? do
    case Application.get_env(:casein, :live_diff_measure, :default) do
      true -> true
      false -> false
      :default -> env_enabled?(System.get_env("CASEIN_LIVE_DIFF_MEASURE"))
    end
  end

  defp env_enabled?(nil), do: true
  defp env_enabled?(""), do: true
  defp env_enabled?(v) when v in ["0", "false", "no", "off", "OFF", "FALSE", "NO"], do: false
  defp env_enabled?(_), do: true

  @doc """
  `on_mount` for the workspace cockpit only — attach the changed-assigns probe.
  """
  def on_mount(:default, _params, _session, socket) do
    if enabled?() and connected?(socket) and socket.view == CaseinWeb.WorkspaceLive.Show do
      {:cont, attach_hook(socket, @hook_name, :after_render, &after_render/1)}
    else
      {:cont, socket}
    end
  end

  @doc false
  def after_render(socket) do
    if enabled?() do
      measure_changed_assigns(socket)
    end

    socket
  end

  @doc """
  Estimate per-key term sizes for a changed-assigns map.

  Returns `{total_bytes, ranked}` where `ranked` is
  `[%{key: atom(), bytes: non_neg_integer()}, ...]` largest first.
  """
  @spec rank_changed(map(), map()) ::
          {non_neg_integer(), [%{key: atom(), bytes: non_neg_integer()}]}
  def rank_changed(assigns, changed) when is_map(assigns) and is_map(changed) do
    ranked =
      changed
      |> Map.keys()
      |> Enum.map(fn key ->
        bytes =
          case Map.fetch(assigns, key) do
            {:ok, value} -> term_bytes(value)
            :error -> 0
          end

        %{key: key, bytes: bytes}
      end)
      |> Enum.sort_by(& &1.bytes, :desc)

    total = Enum.reduce(ranked, 0, fn %{bytes: b}, acc -> acc + b end)
    {total, ranked}
  end

  def rank_changed(_, _), do: {0, []}

  @doc "Classify a Phoenix channel outbound message for wire telemetry."
  @spec classify_message(term()) ::
          {:measure, kind :: String.t(), event :: String.t(), payload :: term()} | :skip
  def classify_message(%Phoenix.Socket.Message{event: event, payload: payload, topic: topic})
      when is_binary(topic) do
    if live_topic?(topic) do
      case {event, payload} do
        {"diff", %{} = diff} ->
          {:measure, "diff_push", "diff", diff}

        {"phx_reply", %{response: %{diff: diff} = response}} when is_map(diff) ->
          {:measure, "reply_diff", "phx_reply", response}

        {"phx_reply", %{"response" => %{"diff" => diff} = response}} when is_map(diff) ->
          {:measure, "reply_diff", "phx_reply", response}

        _ ->
          :skip
      end
    else
      :skip
    end
  end

  def classify_message(%Phoenix.Socket.Reply{
        payload: %{diff: _} = payload,
        topic: topic
      })
      when is_binary(topic) do
    if live_topic?(topic), do: {:measure, "reply_diff", "phx_reply", payload}, else: :skip
  end

  def classify_message(%Phoenix.Socket.Reply{
        payload: %{"diff" => _} = payload,
        topic: topic
      })
      when is_binary(topic) do
    if live_topic?(topic), do: {:measure, "reply_diff", "phx_reply", payload}, else: :skip
  end

  def classify_message(%Phoenix.Socket.Broadcast{event: "diff", payload: payload, topic: topic})
      when is_binary(topic) and is_map(payload) do
    if live_topic?(topic), do: {:measure, "diff_broadcast", "diff", payload}, else: :skip
  end

  def classify_message(_), do: :skip

  @doc "Emit wire telemetry for an already-encoded socket push."
  @spec emit_wire(String.t(), String.t(), non_neg_integer(), keyword()) :: :ok
  def emit_wire(kind, event, payload_bytes, meta \\ [])
      when is_binary(kind) and is_binary(event) and is_integer(payload_bytes) do
    if enabled?() do
      :telemetry.execute(
        @wire_event,
        %{payload_bytes: payload_bytes, count: 1},
        Map.new(meta)
        |> Map.put(:kind, kind)
        |> Map.put(:event, event)
        |> Map.put_new(:view, "live")
      )
    end

    :ok
  end

  @doc "Iodata / binary byte length helper."
  @spec iodata_bytes(iodata() | {:socket_push, atom(), iodata()}) :: non_neg_integer()
  def iodata_bytes({:socket_push, _type, data}), do: iodata_bytes(data)
  def iodata_bytes(data) when is_binary(data), do: byte_size(data)
  def iodata_bytes(data) when is_list(data), do: IO.iodata_length(data)
  def iodata_bytes(_), do: 0

  ## Internals

  defp measure_changed_assigns(socket) do
    assigns = socket.assigns
    changed = Map.get(assigns, :__changed__) || %{}

    if is_map(changed) and map_size(changed) > 0 do
      {total, ranked} = rank_changed(assigns, changed)
      top = Enum.take(ranked, @top_n)

      :telemetry.execute(
        @assigns_event,
        %{payload_bytes: total, changed_count: map_size(changed), count: 1},
        %{
          view: inspect(socket.view),
          top: Enum.map(top, fn %{key: k, bytes: b} -> {k, b} end),
          top_keys: Enum.map(top, & &1.key)
        }
      )
    end
  rescue
    _ -> :ok
  end

  defp term_bytes(value) do
    value
    |> :erlang.term_to_binary()
    |> byte_size()
    |> min(@max_term_bytes)
  rescue
    _ -> 0
  end

  defp live_topic?("lv:" <> _), do: true
  defp live_topic?("phx-" <> _), do: true
  defp live_topic?(_), do: false
end
