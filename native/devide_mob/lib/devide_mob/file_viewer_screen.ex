defmodule DevideMob.FileViewerScreen do
  @moduledoc """
  Read-only file viewer for the mobile IDE.

  The screen requests file bytes from `DevideMob.HostBridge`; the host enforces
  root containment and caps reads before sending text back to the device.
  """

  use Mob.Screen

  @bg 0xFF0B0D10
  @surface 0xFF14181C
  @panel 0xFF1C2227
  @border 0xFF303840
  @good 0xFF9FE6B8
  @warn 0xFFFFD166
  @text 0xFFE7ECEF
  @muted 0xFF9AA4AD
  @button 0xFF26313A
  @code_bg 0xFF0F1317

  @max_render_lines 500

  def mount(params, _session, socket) do
    path = params[:path] || params["path"] || "."

    socket =
      socket
      |> Mob.Socket.assign(:path, path)
      |> Mob.Socket.assign(:root, "")
      |> Mob.Socket.assign(:content, "")
      |> Mob.Socket.assign(:size, nil)
      |> Mob.Socket.assign(:truncated, false)
      |> Mob.Socket.assign(:status, "waiting for devbox")
      |> Mob.Socket.assign(:connected?, false)
      |> Mob.Socket.assign(:request_ref, nil)

    {:ok, request_file(socket, path)}
  end

  def render(assigns) do
    %{
      type: :column,
      props: %{background: @bg, padding: 6, gap: 6, fill_width: true, fill_height: true},
      children: [
        header(assigns),
        toolbar(),
        content_view(assigns),
        bottom_bar()
      ]
    }
  end

  def handle_info({:vt_host, host}, socket) when is_pid(host) do
    DevideMob.DeviceBridge.put_host(host)
    {:noreply, request_file(socket, socket.assigns.path)}
  end

  def handle_info({:ide_response, ref, {:ok, payload}}, socket)
      when ref == socket.assigns.request_ref do
    socket =
      socket
      |> Mob.Socket.assign(:path, Map.fetch!(payload, :path))
      |> Mob.Socket.assign(:root, Map.get(payload, :root, ""))
      |> Mob.Socket.assign(:content, Map.fetch!(payload, :content))
      |> Mob.Socket.assign(:size, Map.fetch!(payload, :size))
      |> Mob.Socket.assign(:truncated, Map.get(payload, :truncated, false))
      |> Mob.Socket.assign(:status, loaded_status(payload))
      |> Mob.Socket.assign(:connected?, true)
      |> Mob.Socket.assign(:request_ref, nil)

    {:noreply, socket}
  end

  def handle_info({:ide_response, ref, {:error, reason}}, socket)
      when ref == socket.assigns.request_ref do
    socket =
      socket
      |> Mob.Socket.assign(:content, "")
      |> Mob.Socket.assign(:size, nil)
      |> Mob.Socket.assign(:truncated, false)
      |> Mob.Socket.assign(:status, "error: #{format_reason(reason)}")
      |> Mob.Socket.assign(:connected?, true)
      |> Mob.Socket.assign(:request_ref, nil)

    {:noreply, socket}
  end

  def handle_info({:tap, :refresh}, socket),
    do: {:noreply, request_file(socket, socket.assigns.path)}

  def handle_info({:tap, :back}, socket), do: {:noreply, Mob.Socket.pop_screen(socket)}
  def handle_info({:tap, :files}, socket), do: {:noreply, Mob.Socket.pop_screen(socket)}

  def handle_info({:tap, :terminal}, socket),
    do: {:noreply, Mob.Socket.pop_to(socket, DevideMob.TerminalScreen)}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp request_file(socket, path) do
    case DevideMob.DeviceBridge.host() do
      {:ok, host} ->
        ref = make_ref()
        send(host, {:ide_request, self(), ref, {:read_file, path}})

        socket
        |> Mob.Socket.assign(:path, path)
        |> Mob.Socket.assign(:status, "loading #{display_path(path)}")
        |> Mob.Socket.assign(:connected?, true)
        |> Mob.Socket.assign(:request_ref, ref)

      :error ->
        socket
        |> Mob.Socket.assign(:status, "waiting for devbox")
        |> Mob.Socket.assign(:connected?, false)
    end
  end

  defp header(assigns) do
    %{
      type: :column,
      props: %{
        background: @surface,
        border_color: @border,
        border_width: 1.0,
        corner_radius: 6.0,
        padding: 8,
        gap: 2,
        fill_width: true
      },
      children: [
        %{
          type: :text,
          props: %{text: Path.basename(assigns.path), text_size: 18.0, text_color: @text},
          children: []
        },
        %{
          type: :text,
          props: %{
            text: "devbox: #{assigns.status}",
            text_size: 12.0,
            text_color: if(assigns.connected?, do: @good, else: @warn)
          },
          children: []
        },
        %{
          type: :text,
          props: %{text: display_path(assigns.path), text_size: 12.0, text_color: @muted},
          children: []
        }
      ]
    }
  end

  defp toolbar do
    %{
      type: :row,
      props: %{background: @panel, corner_radius: 6.0, padding: 4, gap: 4, fill_width: true},
      children: [
        nav_button("Back", :back),
        nav_button("Refresh", :refresh)
      ]
    }
  end

  defp content_view(%{content: ""} = assigns) do
    %{
      type: :box,
      props: %{
        background: @surface,
        border_color: @border,
        border_width: 1.0,
        corner_radius: 6.0,
        padding: 10,
        fill_width: true,
        fill_height: true,
        weight: 1
      },
      children: [
        %{
          type: :text,
          props: %{text: empty_text(assigns), text_size: 14.0, text_color: @muted},
          children: []
        }
      ]
    }
  end

  defp content_view(assigns) do
    lines = display_lines(assigns.content)

    %{
      type: :scroll,
      props: %{
        background: @code_bg,
        border_color: @border,
        border_width: 1.0,
        corner_radius: 6.0,
        fill_width: true,
        fill_height: true,
        weight: 1
      },
      children: [
        %{
          type: :column,
          props: %{padding: 6, gap: 0, fill_width: true},
          children: Enum.map(lines, fn {line, number} -> line_row(line, number) end)
        }
      ]
    }
  end

  defp line_row(line, number) do
    %{
      type: :row,
      props: %{fill_width: true, gap: 8},
      children: [
        %{
          type: :text,
          props: %{
            text: Integer.to_string(number),
            width: 38.0,
            text_align: :right,
            text_size: 11.0,
            text_color: @muted,
            font: "monospace",
            line_height: 1.25
          },
          children: []
        },
        %{
          type: :text,
          props: %{
            text: printable_line(line),
            text_size: 11.0,
            text_color: @text,
            font: "monospace",
            line_height: 1.25,
            fill_width: true,
            weight: 1
          },
          children: []
        }
      ]
    }
  end

  defp bottom_bar do
    %{
      type: :row,
      props: %{background: @panel, corner_radius: 6.0, padding: 4, gap: 4, fill_width: true},
      children: [
        nav_button("Files", :files),
        nav_button("Terminal", :terminal)
      ]
    }
  end

  defp nav_button(label, tag) do
    %{
      type: :button,
      props: %{
        text: label,
        compact: true,
        height: 34.0,
        corner_radius: 4.0,
        background: @button,
        text_color: @text,
        text_size: 12.0,
        weight: 1,
        on_tap: {self(), tag}
      },
      children: []
    }
  end

  defp display_lines(content) do
    content
    |> String.split("\n")
    |> Enum.take(@max_render_lines)
    |> Enum.with_index(1)
  end

  defp printable_line(""), do: " "

  defp printable_line(line) do
    String.replace(line, "\t", "    ")
  end

  defp empty_text(%{request_ref: ref}) when not is_nil(ref), do: "Loading..."
  defp empty_text(%{status: "waiting for devbox"}), do: "Waiting for devbox"
  defp empty_text(%{status: "error:" <> _} = assigns), do: assigns.status
  defp empty_text(_assigns), do: "Empty file"

  defp loaded_status(%{size: size, truncated: true}), do: "#{format_size(size)}; first 128 KB"
  defp loaded_status(%{size: size}), do: format_size(size)

  defp format_size(nil), do: ""
  defp format_size(size) when size < 1024, do: "#{size} B"
  defp format_size(size) when size < 1_048_576, do: "#{div(size, 1024)} KB"
  defp format_size(size), do: "#{Float.round(size / 1_048_576, 1)} MB"

  defp format_reason({:not_file, type}), do: "not a file (#{type})"
  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)

  defp display_path("."), do: "."
  defp display_path(path), do: path
end
