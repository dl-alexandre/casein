defmodule Casein.Previews.Pane do
  @moduledoc """
  `Casein.Panes.Pane` implementation for preview (feature) panes.

  Thin adapter over the existing `Casein.PreviewPanes` registry — it does not
  reimplement preview lifecycle, it gives the uniform pane pipeline a typed entry
  point into it. This is the proof case that a non-terminal surface can be a
  first-class declarative node: a `:preview` leaf in a session template gets brought
  to life here on execute/reconcile, instead of leaving a blank shell pane.

  ## Node payload

  The template `Pane`/`Window` `:command` field is the pane's *payload*: a shell
  command for `:terminal`, the **URL to preview** for `:preview`. The `:type` guard
  in the reconcile diff ensures a preview node's payload is never sent to a shell.
  """

  @behaviour Casein.Panes.Pane

  alias Casein.PreviewPanes

  @impl true
  def attach(node, ctx) do
    with {:ok, pane_id} <- fetch(ctx, :pane_id),
         {:ok, url} <- fetch_payload(node) do
      case PreviewPanes.get_by_pane(pane_id) do
        # Idempotent on reconcile re-run: same pane already showing the same URL.
        %{url: ^url} -> {:ok, pane_id}
        %{display_url: ^url} -> {:ok, pane_id}
        _ -> register(pane_id, url, node, ctx)
      end
    end
  end

  @impl true
  def serialize(pane_id) when is_binary(pane_id) do
    case PreviewPanes.get_by_pane(pane_id) do
      nil ->
        %{"type" => "preview"}

      reg ->
        %{
          "type" => "preview",
          "command" => reg.url,
          "url" => reg.url
        }
        |> put_optional("viewport", viewport_string(reg.viewport))
    end
  end

  @impl true
  def terminate(pane_id) when is_binary(pane_id) do
    _ = PreviewPanes.deregister(pane_id)
    :ok
  end

  @impl true
  def render_payload(pane_id) when is_binary(pane_id) do
    case PreviewPanes.get_by_pane(pane_id) do
      nil -> %{}
      reg -> render_payload_from(reg)
    end
  end

  @doc """
  The `render_payload/1` shape built from an in-hand registration.

  Used by `Casein.PreviewPanes` at its broadcast sites so the generic
  `Casein.Panes.Events` payload matches what `render_payload/1`/`snapshot/1`
  would return for the same pane — one shape for events and hydration.
  """
  def render_payload_from(reg) when is_map(reg) do
    %{
      url: reg.url,
      display_url: reg.display_url,
      viewport: reg.viewport,
      mode: preview_mode(reg),
      workspace_id: Map.get(reg, :workspace_id),
      source_url: Map.get(reg, :source_url),
      tmux_session: Map.get(reg, :tmux_session),
      shared: Map.get(reg, :shared, false),
      source_pane_id: Map.get(reg, :source_pane_id),
      preview_id: Map.get(reg, :preview_id),
      control_session_id: Map.get(reg, :control_session_id),
      pane_window_id: Map.get(reg, :pane_window_id)
    }
  end

  @impl true
  def list(workspace_id) when is_binary(workspace_id) do
    workspace_id
    |> PreviewPanes.list_for_workspace()
    |> Enum.map(& &1.pane_id)
  end

  @impl true
  def handle_input(pane_id, %{} = input) when is_binary(pane_id) do
    case input_action(input) do
      {:navigate, url} -> normalize(PreviewPanes.navigate(pane_id, url))
      {:click, coords} -> normalize(PreviewPanes.click_snapshot(pane_id, coords))
      :reload -> normalize(PreviewPanes.reload(pane_id))
      :go_back -> normalize(PreviewPanes.go_back(pane_id))
      :go_forward -> normalize(PreviewPanes.go_forward(pane_id))
      :close -> normalize(PreviewPanes.deregister(pane_id))
      :unknown -> {:error, :unsupported_preview_input}
    end
  end

  # Preview panes have no PTY to size to a focused viewer; visibility is driven by
  # the JS overlay. The focus signal is a no-op here (documented in the behaviour).
  @impl true
  def set_active(pane_id, active?) when is_binary(pane_id) and is_boolean(active?), do: :ok

  # --- internals ---------------------------------------------------------------

  defp register(pane_id, url, node, ctx) do
    attrs =
      %{
        "pane_id" => pane_id,
        "url" => url,
        "workspace_id" => ctx[:workspace_id],
        "tmux_session" => ctx[:tmux_session]
      }
      |> put_optional("viewport", node_field(node, :viewport))
      |> put_optional("placement", ctx[:placement])
      |> put_optional("anchor_pane_id", ctx[:anchor_pane_id])

    case PreviewPanes.register(attrs) do
      {:ok, %{pane_id: registered}} -> {:ok, registered}
      {:error, reason} -> {:error, reason}
    end
  end

  defp input_action(input) do
    type = input[:type] || input["type"]

    case type do
      t when t in ["navigate", :navigate] ->
        {:navigate, input[:url] || input["url"]}

      t when t in ["click", :click] ->
        {:click, %{"x" => input[:x] || input["x"], "y" => input[:y] || input["y"]}}

      t when t in ["reload", :reload] ->
        :reload

      t when t in ["go_back", :go_back] ->
        :go_back

      t when t in ["go_forward", :go_forward] ->
        :go_forward

      t when t in ["close", :close] ->
        :close

      _ ->
        :unknown
    end
  end

  defp fetch(ctx, key) do
    case ctx[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing, key}}
    end
  end

  defp fetch_payload(node) do
    case node_field(node, :command) || node_field(node, :url) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_preview_url}
    end
  end

  defp node_field(node, key) when is_map(node) do
    Map.get(node, key, Map.get(node, to_string(key)))
  end

  defp viewport_string(%{width: w, height: h}) when is_integer(w) and is_integer(h),
    do: "#{w}x#{h}"

  defp viewport_string(_), do: nil

  defp preview_mode(%{display_url: display_url}) when is_binary(display_url) do
    if String.contains?(display_url, "/preview-artifacts/"), do: "snapshot", else: "iframe"
  end

  defp preview_mode(_), do: "unknown"

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp normalize(:ok), do: :ok
  defp normalize({:ok, _}), do: :ok
  defp normalize({:error, reason}), do: {:error, reason}
end
