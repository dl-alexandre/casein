defmodule DevideMob.PairingScreen do
  @moduledoc """
  Pair this device to a dev_ide host's session feed.

  The web cockpit's `/pair/<workspace_id>` page shows a QR and a copyable
  pairing code (Base64 of `{url, token, workspace_id}`). Paste that code here to
  connect `DevideMob.SessionClient` and pin the workspace to the dashboard.

  Scanning the QR with the camera is the fast path. Paste and manual entry use
  the same parser as scanned values, so all pairing paths accept the same code
  formats.
  """
  use Mob.Screen

  alias DevideMob.DeviceLink
  alias DevideMob.SessionClient
  alias DevideMob.SessionConfig
  alias DevideMob.SessionDashboardScreen
  alias DevideMob.UI

  @success_delay_ms 900

  def mount(params, _session, socket) do
    socket =
      socket
      |> Mob.Socket.assign(:code, "")
      |> Mob.Socket.assign(:state, initial_state(params))
      |> Mob.Socket.assign(:message, nil)
      |> Mob.Socket.assign(:paired_workspace, nil)

    {:ok, socket}
  end

  defp initial_state(%{state: state})
       when state in [:ready, :scanning, :pairing, :success, :error],
       do: state

  defp initial_state(%{"state" => state})
       when state in ["ready", "scanning", "pairing", "success", "error"] do
    String.to_existing_atom(state)
  end

  defp initial_state(_params), do: :ready

  def handle_info({:change, :code, value}, socket) do
    {:noreply,
     socket
     |> Mob.Socket.assign(:code, value)
     |> Mob.Socket.assign(:state, :ready)
     |> Mob.Socket.assign(:message, nil)}
  end

  def handle_info({:tap, :pair}, socket) do
    {:noreply, pair_with(socket, socket.assigns.code)}
  end

  def handle_info({:tap, :paste_clipboard}, socket) do
    case Mob.Clipboard.get(socket) do
      {:clipboard, :ok, code} ->
        socket =
          socket
          |> Mob.Socket.assign(:code, code)
          |> pair_with(code)

        {:noreply, socket}

      {:clipboard, :empty} ->
        {:noreply,
         socket
         |> Mob.Socket.assign(:state, :error)
         |> Mob.Socket.assign(:message, clipboard_empty_message())}
    end
  end

  def handle_info({:tap, :scan_qr}, socket) do
    {:noreply, request_camera_permission(socket)}
  end

  def handle_info({:tap, :cancel_pairing}, socket) do
    {:noreply,
     socket
     |> Mob.Socket.assign(:state, :ready)
     |> Mob.Socket.assign(:message, nil)}
  end

  def handle_info({:tap, :cancel_scan}, socket) do
    {:noreply,
     socket
     |> Mob.Socket.assign(:state, :ready)
     |> Mob.Socket.assign(:message, "Scan cancelled. Paste the pairing code if you prefer.")}
  end

  def handle_info({:tap, :continue}, socket) do
    {:noreply, Mob.Socket.reset_to(socket, SessionDashboardScreen)}
  end

  def handle_info({:permission, :camera, :granted}, socket) do
    {:noreply, open_scanner(socket)}
  end

  def handle_info({:permission, :camera, :denied}, socket) do
    {:noreply,
     socket
     |> Mob.Socket.assign(:state, :error)
     |> Mob.Socket.assign(
       :message,
       "Camera permission is required to scan. Paste the pairing code below instead."
     )}
  end

  def handle_info({:scan, :result, %{value: value}}, socket) when is_binary(value) do
    {:noreply, socket |> Mob.Socket.assign(:code, value) |> pair_with(value)}
  end

  def handle_info({:scan, :cancelled}, socket) do
    {:noreply,
     socket
     |> Mob.Socket.assign(:state, :ready)
     |> Mob.Socket.assign(:message, "Scan cancelled. Paste the pairing code if you prefer.")}
  end

  def handle_info({:scan, :not_available}, socket) do
    {:noreply,
     socket
     |> Mob.Socket.assign(:state, :error)
     |> Mob.Socket.assign(:message, scanner_unavailable_message())}
  end

  def handle_info(:pairing_success_done, %{assigns: %{state: :success}} = socket) do
    {:noreply, Mob.Socket.reset_to(socket, SessionDashboardScreen)}
  end

  def handle_info({:tap, :back}, socket) do
    {:noreply, Mob.Socket.pop_screen(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp pair_with(socket, code) do
    socket =
      socket
      |> Mob.Socket.assign(:state, :pairing)
      |> Mob.Socket.assign(:message, nil)

    with {:ok, payload} <- decode_pairing_payload(code),
         {:ok, %{url: url, token: token, workspace_id: wid}} <- DeviceLink.pair(payload) do
      SessionConfig.clear_all()
      SessionClient.configure(url, token)
      SessionConfig.pin_workspace(wid)
      Process.send_after(self(), :pairing_success_done, @success_delay_ms)

      socket
      |> Mob.Socket.assign(:state, :success)
      |> Mob.Socket.assign(:paired_workspace, wid)
      |> Mob.Socket.assign(:message, "Paired successfully")
    else
      {:error, :empty} ->
        socket
        |> Mob.Socket.assign(:state, :error)
        |> Mob.Socket.assign(:message, clipboard_empty_message())

      _ ->
        socket
        |> Mob.Socket.assign(:state, :error)
        |> Mob.Socket.assign(:message, invalid_code_message())
    end
  end

  defp request_camera_permission(socket) do
    socket =
      socket
      |> Mob.Socket.assign(:state, :scanning)
      |> Mob.Socket.assign(:message, "Requesting camera access...")

    try do
      Mob.Permissions.request(socket, :camera)
    rescue
      _ in [UndefinedFunctionError, ArgumentError, ErlangError] ->
        scanner_unavailable(socket)
    end
  end

  defp open_scanner(socket) do
    socket =
      socket
      |> Mob.Socket.assign(:state, :scanning)
      |> Mob.Socket.assign(:message, "Point your camera at the QR code shown in the web cockpit.")

    try do
      MobScanner.scan(socket, formats: [:qr])
    rescue
      _ in [UndefinedFunctionError, ArgumentError, ErlangError] ->
        scanner_unavailable(socket)
    end
  end

  defp scanner_unavailable(socket) do
    socket
    |> Mob.Socket.assign(:state, :error)
    |> Mob.Socket.assign(:message, scanner_unavailable_message())
  end

  defp clipboard_empty_message do
    "Clipboard is empty or doesn't contain a pairing code. Copy the code from the cockpit and try again."
  end

  defp invalid_code_message do
    "That code doesn't look valid. Check the web cockpit, or edit it below and try again."
  end

  defp scanner_unavailable_message do
    "Camera scanner isn't available in this build. Paste the pairing code below instead."
  end

  defp decode_pairing_payload(code) when is_binary(code) do
    code = code |> extract_pairing_code() |> String.trim()

    cond do
      code == "" ->
        {:error, :empty}

      String.starts_with?(code, "{") ->
        Jason.decode(code)

      true ->
        encoded = String.replace(code, ~r/\s+/, "")

        with {:ok, json} <- Base.url_decode64(encoded, padding: false) do
          Jason.decode(json)
        end
    end
  end

  defp decode_pairing_payload(_), do: {:error, :invalid}

  defp extract_pairing_code(input) do
    trimmed = String.trim(input)

    case URI.parse(trimmed) do
      %URI{query: query} when is_binary(query) ->
        params = URI.decode_query(query)
        params["code"] || params["pairing_code"] || trimmed

      %URI{scheme: "devide", host: "pair", path: "/" <> code} when code != "" ->
        URI.decode(code)

      _ ->
        trimmed
    end
  end

  def render(assigns) do
    %{
      type: :column,
      props: %{background: :background, fill_width: true, fill_height: true},
      children: [
        UI.header("Pair workspace",
          subtitle: "Connect this phone to a dev_ide workspace",
          leading: UI.icon_button("back", {self(), :back}, label: "Back", background: :surface)
        ),
        %{
          type: :scroll,
          props: %{fill_width: true, weight: 1},
          children: [
            UI.stack(content(assigns),
              gap: 12,
              padding_left: 16,
              padding_right: 16,
              padding_top: 16,
              padding_bottom: 28
            )
          ]
        }
      ]
    }
  end

  defp content(%{state: :pairing}) do
    [
      state_panel(
        "Pairing...",
        "Connecting this phone to the workspace feed.",
        :progress,
        "Cancel",
        :cancel_pairing
      )
    ]
  end

  defp content(%{state: :scanning}) do
    [
      state_panel(
        "Opening scanner...",
        "Point your camera at the QR code shown in the web cockpit.",
        :progress,
        "Cancel",
        :cancel_scan
      )
    ]
  end

  defp content(%{state: :success, paired_workspace: workspace_id}) do
    [
      state_panel(
        "Paired successfully",
        "Workspace #{workspace_id || "workspace"} is ready on this phone.",
        :check,
        "Continue",
        :continue
      )
    ]
  end

  defp content(assigns) do
    [
      qr_section(),
      message_card(assigns),
      manual_section(assigns),
      UI.meta("Pairs to one workspace at a time.")
    ]
    |> Enum.reject(&is_nil/1)
  end

  # The QR path is the fast one, so it gets the hero treatment: the primary
  # action, and paste as its quieter sibling right underneath.
  defp qr_section do
    UI.card(
      [
        UI.box([UI.icon("qr_code", text_size: 32, text_color: :primary)],
          align: "center",
          fill_width: true,
          padding_top: 4,
          padding_bottom: 4
        ),
        UI.title("Scan the cockpit QR", text_align: :center, fill_width: true),
        UI.body("Open /pair in the web cockpit and point your camera at the code.",
          text_color: :muted,
          text_align: :center,
          fill_width: true
        ),
        UI.button("Scan QR code", {self(), :scan_qr}, :primary),
        UI.button("Paste & pair", {self(), :paste_clipboard}, :secondary)
      ],
      gap: 10,
      padding: 16
    )
  end

  defp manual_section(assigns) do
    UI.card(
      [
        UI.section_label("Have a pairing code?"),
        %{
          type: :text_field,
          props: %{
            value: assigns.code,
            placeholder: "Enter pairing code",
            keyboard: :default,
            return_key: :done,
            background: :surface_raised,
            text_color: :on_surface,
            placeholder_color: :muted,
            border_color: :border,
            corner_radius: :radius_md,
            padding: 12,
            on_change: {self(), :code},
            on_submit: {self(), :pair}
          },
          children: []
        },
        UI.button("Pair", {self(), :pair}, :secondary, disabled: String.trim(assigns.code) == "")
      ],
      gap: 10
    )
  end

  defp state_panel(title, body, indicator, action_label, action) do
    UI.card(
      [
        indicator_node(indicator),
        UI.title(title, text_size: :lg),
        UI.body(body, text_color: :muted),
        action_label && UI.button(action_label, {self(), action}, :secondary)
      ],
      gap: 12,
      padding: 20
    )
  end

  defp indicator_node(:progress), do: %{type: :progress, props: %{color: :primary}, children: []}

  defp indicator_node(:check) do
    UI.icon("check", text_size: 28, text_color: UI.tone_fg(:done))
  end

  defp message_card(%{message: nil}), do: nil

  defp message_card(%{state: :error, message: message}) do
    UI.tinted(
      [
        UI.row(
          [
            UI.icon("warning", text_color: UI.tone_fg(:failed), text_size: 15),
            UI.body(message, weight: 1)
          ],
          gap: 8
        )
      ],
      :failed
    )
  end

  defp message_card(%{message: message}) do
    UI.tinted([UI.body(message)], :neutral)
  end
end
