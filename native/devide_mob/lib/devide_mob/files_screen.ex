defmodule DevideMob.FilesScreen do
  @moduledoc """
  Devbox-backed file browser for the mobile IDE.

  The device owns the UI, but directory reads happen on the host through
  `DevideMob.HostBridge`. This keeps the transport explicit and avoids parsing
  terminal output.
  """

  use Mob.Screen

  @bg 0xFF0B0D10
  @surface 0xFF14181C
  @panel 0xFF1C2227
  @border 0xFF303840
  @accent 0xFF7DD3FC
  @good 0xFF9FE6B8
  @warn 0xFFFFD166
  @text 0xFFE7ECEF
  @muted 0xFF9AA4AD
  @button 0xFF26313A

  def mount(_params, _session, socket) do
    socket =
      socket
      |> Mob.Socket.assign(:path, ".")
      |> Mob.Socket.assign(:root, "")
      |> Mob.Socket.assign(:entries, [])
      |> Mob.Socket.assign(:status, "waiting for devbox")
      |> Mob.Socket.assign(:connected?, false)
      |> Mob.Socket.assign(:request_ref, nil)

    {:ok, request_list(socket, ".")}
  end

  def render(assigns) do
    %{
      type: :column,
      props: %{background: @bg, padding: 6, gap: 6, fill_width: true, fill_height: true},
      children: [
        header(assigns),
        toolbar(assigns),
        entry_list(assigns),
        bottom_bar()
      ]
    }
  end

  def handle_info({:vt_host, host}, socket) when is_pid(host) do
    DevideMob.DeviceBridge.put_host(host)
    {:noreply, request_list(socket, socket.assigns.path)}
  end

  def handle_info({:ide_response, ref, {:ok, payload}}, socket)
      when ref == socket.assigns.request_ref do
    socket =
      socket
      |> Mob.Socket.assign(:path, Map.fetch!(payload, :path))
      |> Mob.Socket.assign(:root, Map.get(payload, :root, ""))
      |> Mob.Socket.assign(:entries, Map.fetch!(payload, :entries))
      |> Mob.Socket.assign(:status, "#{length(Map.fetch!(payload, :entries))} items")
      |> Mob.Socket.assign(:connected?, true)
      |> Mob.Socket.assign(:request_ref, nil)

    {:noreply, socket}
  end

  def handle_info({:ide_response, ref, {:error, reason}}, socket)
      when ref == socket.assigns.request_ref do
    socket =
      socket
      |> Mob.Socket.assign(:status, "error: #{format_reason(reason)}")
      |> Mob.Socket.assign(:connected?, true)
      |> Mob.Socket.assign(:request_ref, nil)

    {:noreply, socket}
  end

  def handle_info({:tap, :refresh}, socket),
    do: {:noreply, request_list(socket, socket.assigns.path)}

  def handle_info({:tap, :terminal}, socket), do: {:noreply, Mob.Socket.pop_screen(socket)}

  def handle_info({:tap, :home}, socket),
    do: {:noreply, Mob.Socket.push_screen(socket, DevideMob.HomeScreen)}

  def handle_info({:tap, :up}, socket) do
    {:noreply, request_list(socket, parent_path(socket.assigns.path))}
  end

  def handle_info({:tap, "entry:" <> index}, socket) do
    with {i, ""} <- Integer.parse(index),
         entry when not is_nil(entry) <- Enum.at(socket.assigns.entries, i) do
      {:noreply, open_entry(socket, entry)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_info({:tap, name}, socket) when is_binary(name) do
    case Enum.find(socket.assigns.entries, &(&1.name == name)) do
      nil -> {:noreply, socket}
      entry -> {:noreply, open_entry(socket, entry)}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp request_list(socket, path) do
    case DevideMob.DeviceBridge.host() do
      {:ok, host} ->
        ref = make_ref()
        send(host, {:ide_request, self(), ref, {:list_dir, path}})

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

  defp open_entry(socket, %{type: :directory, name: name}) do
    request_list(socket, child_path(socket.assigns.path, name))
  end

  defp open_entry(socket, %{name: name}) do
    path = child_path(socket.assigns.path, name)
    Mob.Socket.push_screen(socket, DevideMob.FileViewerScreen, %{path: path})
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
          props: %{text: "DevIDE Files", text_size: 18.0, text_color: @text},
          children: []
        },
        %{
          type: :text,
          props: %{
            text: status_line(assigns),
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

  defp toolbar(assigns) do
    %{
      type: :row,
      props: %{background: @panel, corner_radius: 6.0, padding: 4, gap: 4, fill_width: true},
      children: [
        nav_button("Up", :up, assigns.path != "."),
        nav_button("Refresh", :refresh, true),
        nav_button("Home", :home, true)
      ]
    }
  end

  defp entry_list(%{entries: []}) do
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
          props: %{text: "No files yet", text_size: 14.0, text_color: @muted},
          children: []
        }
      ]
    }
  end

  defp entry_list(assigns) do
    %{
      type: :scroll,
      props: %{
        background: @surface,
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
          props: %{padding: 4, gap: 4, fill_width: true},
          children:
            assigns.entries
            |> Enum.with_index()
            |> Enum.map(fn {entry, index} -> entry_row(entry, index) end)
        }
      ]
    }
  end

  defp entry_row(entry, index) do
    %{
      type: :button,
      props: %{
        text: entry_label(entry),
        background: if(entry.type == :directory, do: @panel, else: @surface),
        text_color: if(entry.type == :directory, do: @accent, else: @text),
        text_size: 13.0,
        padding: 8,
        fill_width: true,
        on_tap: {self(), "entry:#{index}"}
      },
      children: []
    }
  end

  defp bottom_bar do
    %{
      type: :row,
      props: %{background: @panel, corner_radius: 6.0, padding: 4, gap: 4, fill_width: true},
      children: [
        nav_button("Terminal", :terminal, true),
        nav_button("Files", :refresh, true)
      ]
    }
  end

  defp nav_button(label, tag, enabled?) do
    %{
      type: :button,
      props: %{
        text: label,
        compact: true,
        height: 34.0,
        corner_radius: 4.0,
        background: if(enabled?, do: @button, else: @surface),
        text_color: if(enabled?, do: @text, else: @muted),
        text_size: 12.0,
        weight: 1,
        disabled: not enabled?,
        on_tap: {self(), tag}
      },
      children: []
    }
  end

  defp status_line(%{status: status}), do: "devbox: #{status}"

  defp entry_label(%{type: :directory, name: name}), do: "[dir] #{name}"
  defp entry_label(%{name: name, size: size}), do: "#{name}  #{format_size(size)}"

  defp format_size(nil), do: ""
  defp format_size(size) when size < 1024, do: "#{size} B"
  defp format_size(size) when size < 1_048_576, do: "#{div(size, 1024)} KB"
  defp format_size(size), do: "#{Float.round(size / 1_048_576, 1)} MB"

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)

  defp display_path("."), do: "."
  defp display_path(path), do: path

  defp parent_path("."), do: "."

  defp parent_path(path) do
    case Path.dirname(path) do
      "." -> "."
      parent -> parent
    end
  end

  defp child_path(".", name), do: name
  defp child_path(path, name), do: Path.join(path, name)
end
