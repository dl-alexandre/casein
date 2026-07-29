defmodule CaseinMob.PairingScreen do
  @moduledoc """
  Pair this device to a Casein host's session feed.

  The web cockpit's `/pair/<workspace_id>` page shows a compact QR and copyable
  pairing code containing only the canonical origin plus a short-lived opaque
  handle. The server owns workspace scope and exchanges the handle once for a
  durable device credential.

  Scanning the QR with the camera is the fast path. Paste and manual entry use
  the same parser as scanned values, so all pairing paths accept the same code
  formats.
  """
  use Mob.Screen

  require Logger

  alias CaseinMob.DeviceLink
  alias CaseinMob.PairingCode
  alias CaseinMob.SessionClient
  alias CaseinMob.SessionConfig
  alias CaseinMob.SessionDashboardScreen

  @success_delay_ms 900
  @max_diagnostic_bytes 4_096
  @pairing_reason_labels %{
    empty: "empty",
    insecure_transport: "insecure_transport",
    invalid_encoding: "invalid_encoding",
    invalid_json: "invalid_json",
    invalid_payload: "invalid_payload",
    invalid_response: "invalid_response",
    invalid_structure: "invalid_structure",
    not_found: "not_found",
    origin_mismatch: "origin_mismatch",
    pairing_already_used: "pairing_already_used",
    pairing_expired: "pairing_expired",
    rejected: "rejected",
    request_failed: "request_failed",
    unavailable: "unavailable",
    unsupported_pairing_version: "unsupported_pairing_version"
  }

  def mount(params, _session, socket) do
    code = pairing_code_param(params)

    socket =
      socket
      |> Mob.Socket.assign(:code, code)
      |> Mob.Socket.assign(:state, if(code == "", do: initial_state(params), else: :pairing))
      |> Mob.Socket.assign(:message, nil)
      |> Mob.Socket.assign(:paired_workspace, nil)

    if code != "", do: send(self(), {:pair_code, code})
    {:ok, socket}
  end

  defp pairing_code_param(%{code: code}) when is_binary(code), do: String.trim(code)
  defp pairing_code_param(%{"code" => code}) when is_binary(code), do: String.trim(code)
  defp pairing_code_param(_params), do: ""

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

  def handle_info({:pair_code, code}, socket) when is_binary(code) do
    {:noreply, pair_with(socket, code)}
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

    with {:ok, payload} <- decode_pairing_code(code),
         {:ok, %{workspace_id: wid} = pairing} <- pair_device(payload, code) do
      refreshed? =
        Enum.any?(
          SessionConfig.host_profiles(),
          &(&1.origin_id == pairing.origin_id and not &1.read_only?)
        )

      SessionClient.configure(pairing)
      SessionConfig.pin_workspace(wid)
      Process.send_after(self(), :pairing_success_done, @success_delay_ms)

      socket
      |> Mob.Socket.assign(:state, :success)
      |> Mob.Socket.assign(:paired_workspace, wid)
      |> Mob.Socket.assign(
        :message,
        if(refreshed?, do: "Connection refreshed", else: "Paired successfully")
      )
    else
      {:error, :empty} ->
        socket
        |> Mob.Socket.assign(:state, :error)
        |> Mob.Socket.assign(:message, clipboard_empty_message())

      {:error, :pairing_expired} ->
        socket
        |> Mob.Socket.assign(:state, :error)
        |> Mob.Socket.assign(
          :message,
          "That pairing code expired or was refreshed. Refresh the cockpit QR and scan again."
        )

      {:error, :pairing_already_used} ->
        socket
        |> Mob.Socket.assign(:state, :error)
        |> Mob.Socket.assign(
          :message,
          "That pairing code was already used. Refresh the cockpit QR to pair another device."
        )

      {:error, reason}
      when reason in [
             :empty,
             :invalid_structure,
             :invalid_encoding,
             :invalid_json,
             :invalid_payload,
             :unsupported_pairing_version,
             :origin_mismatch,
             :insecure_transport
           ] ->
        socket
        |> Mob.Socket.assign(:state, :error)
        |> Mob.Socket.assign(:message, invalid_code_message())

      _ ->
        socket
        |> Mob.Socket.assign(:state, :error)
        |> Mob.Socket.assign(
          :message,
          "Casein couldn't verify that pairing code. Refresh the cockpit QR and scan again."
        )
    end
  end

  defp decode_pairing_code(code) do
    case PairingCode.decode(code) do
      {:error, reason} = error ->
        log_pairing_rejection(:pairing_code, reason, code)
        error

      result ->
        result
    end
  end

  defp pair_device(payload, code) do
    case DeviceLink.pair(payload) do
      {:error, reason} = error ->
        log_pairing_rejection(:device_link, reason, code)
        error

      result ->
        result
    end
  end

  defp log_pairing_rejection(stage, reason, code) do
    diagnostics = pairing_code_diagnostics(code)
    reason_label = Map.get(@pairing_reason_labels, reason, "other")

    Logger.warning(
      "mobile_pairing_rejected stage=#{stage} reason=#{reason_label} " <>
        "raw_bytes=#{diagnostics.raw_bytes} trimmed_bytes=#{diagnostics.trimmed_bytes} " <>
        "compact_prefix=#{diagnostics.compact_prefix?} " <>
        "segment_bytes=#{diagnostics.segment_bytes} " <>
        "base64url_segment=#{diagnostics.base64url_segment?} " <>
        "oversized=#{diagnostics.oversized?}"
    )
  end

  defp pairing_code_diagnostics(code)
       when is_binary(code) and byte_size(code) > @max_diagnostic_bytes do
    %{
      raw_bytes: byte_size(code),
      trimmed_bytes: 0,
      compact_prefix?: false,
      segment_bytes: 0,
      base64url_segment?: false,
      oversized?: true
    }
  end

  defp pairing_code_diagnostics(code) when is_binary(code) do
    trimmed = safe_trim(code)
    compact_prefix? = String.starts_with?(trimmed, "casein://pair/")

    segment =
      if compact_prefix?,
        do: String.replace_prefix(trimmed, "casein://pair/", ""),
        else: ""

    %{
      raw_bytes: byte_size(code),
      trimmed_bytes: byte_size(trimmed),
      compact_prefix?: compact_prefix?,
      segment_bytes: byte_size(segment),
      base64url_segment?: compact_prefix? and Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, segment),
      oversized?: false
    }
  end

  defp pairing_code_diagnostics(_code) do
    %{
      raw_bytes: 0,
      trimmed_bytes: 0,
      compact_prefix?: false,
      segment_bytes: 0,
      base64url_segment?: false,
      oversized?: false
    }
  end

  defp safe_trim(code) do
    String.trim(code)
  rescue
    ArgumentError -> ""
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

  def render(assigns) do
    %{
      type: :column,
      props: %{background: :background, fill_width: true, fill_height: true},
      children: [
        header(),
        %{
          type: :scroll,
          props: %{fill_width: true, weight: 1},
          children: [
            %{
              type: :column,
              props: %{fill_width: true, padding: :space_md, gap: 10},
              children: content(assigns)
            }
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

  defp content(%{state: :success, paired_workspace: workspace_id, message: message}) do
    [
      state_panel(
        message || "Pairing complete",
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
      paste_section(assigns),
      manual_section(assigns),
      helper_line("Each host is saved. You can switch hosts from the Action Center.")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp qr_section do
    %{
      type: :column,
      props: %{fill_width: true, background: :surface, padding: :space_md, gap: 6},
      children: [
        %{
          type: :button,
          props: %{
            text: "Scan QR code",
            fill_width: true,
            background: :primary,
            text_color: :on_primary,
            padding: :space_md,
            height: 48.0,
            on_tap: {self(), :scan_qr}
          },
          children: []
        },
        %{
          type: :text,
          props: %{
            text: "Use the web cockpit QR code. Paste still works below.",
            text_color: :muted,
            text_size: :sm
          },
          children: []
        }
      ]
    }
  end

  defp paste_section(assigns) do
    %{
      type: :column,
      props: %{fill_width: true, gap: 6},
      children:
        [
          %{
            type: :button,
            props: %{
              text: "Paste & pair",
              fill_width: true,
              background: :surface_raised,
              text_color: :on_surface,
              padding: :space_md,
              height: 48.0,
              on_tap: {self(), :paste_clipboard}
            },
            children: []
          },
          message_text(assigns)
        ]
        |> Enum.reject(&is_nil/1)
    }
  end

  defp manual_section(assigns) do
    %{
      type: :column,
      props: %{fill_width: true, background: :surface, padding: :space_md, gap: 8},
      children: [
        %{
          type: :text,
          props: %{text: "Have a pairing code?", text_color: :on_surface, font_weight: "bold"},
          children: []
        },
        %{
          type: :text_field,
          props: %{
            value: assigns.code,
            placeholder: "Enter pairing code",
            keyboard: :default,
            return_key: :done,
            on_change: {self(), :code},
            on_submit: {self(), :pair}
          },
          children: []
        },
        %{
          type: :button,
          props: %{
            text: "Pair",
            fill_width: true,
            background: :surface_raised,
            text_color: :on_surface,
            padding: :space_sm,
            height: 44.0,
            disabled: String.trim(assigns.code) == "",
            on_tap: {self(), :pair}
          },
          children: []
        }
      ]
    }
  end

  defp state_panel(title, body, indicator, action_label, action) do
    %{
      type: :column,
      props: %{fill_width: true, background: :surface, padding: :space_lg, gap: 10},
      children:
        [
          indicator_node(indicator),
          %{
            type: :text,
            props: %{text: title, text_color: :on_surface, text_size: :lg, font_weight: "bold"},
            children: []
          },
          %{
            type: :text,
            props: %{text: body, text_color: :muted, text_size: :sm},
            children: []
          },
          action_label &&
            %{
              type: :button,
              props: %{
                text: action_label,
                fill_width: true,
                background: :surface_raised,
                text_color: :on_surface,
                padding: :space_sm,
                height: 44.0,
                on_tap: {self(), action}
              },
              children: []
            }
        ]
        |> Enum.reject(&is_nil/1)
    }
  end

  defp indicator_node(:progress), do: %{type: :progress, props: %{color: :primary}, children: []}

  defp indicator_node(:check) do
    %{
      type: :text,
      props: %{text: "✓", text_color: :green_400, text_size: :xl, text_align: "center"},
      children: []
    }
  end

  defp helper_line(text) do
    %{type: :text, props: %{text: text, text_color: :muted, text_size: :xs}, children: []}
  end

  defp message_text(%{message: nil}), do: nil

  defp message_text(%{state: :error, message: message}) do
    %{
      type: :text,
      props: %{text: message, text_color: :red_400, text_size: :sm},
      children: []
    }
  end

  defp message_text(%{message: message}) do
    %{
      type: :text,
      props: %{text: message, text_color: :muted, text_size: :sm},
      children: []
    }
  end

  defp header do
    %{
      type: :row,
      props: %{fill_width: true, background: :primary, padding: :space_sm, gap: 8},
      children: [
        %{
          type: :button,
          props: %{
            text: "Back",
            fill_width: false,
            background: :surface_raised,
            text_color: :on_surface,
            padding: :space_sm,
            height: 44.0,
            on_tap: {self(), :back}
          },
          children: []
        },
        %{
          type: :text,
          props: %{
            text: "Pair workspace",
            text_size: :lg,
            text_color: :on_primary,
            font_weight: "bold",
            weight: 1
          },
          children: []
        }
      ]
    }
  end
end
