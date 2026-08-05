defmodule CaseinMob.IOSTerminalComponent do
  @moduledoc """
  One-shot iOS terminal frame delivery.

  The encoded prop is retained only until native acknowledges the exact
  baseline generation and revision. The acknowledgment scrubs the component
  assigns and tells the parent screen to emit a payload-free retained tree.
  """

  use Mob.Component

  @max_frame_bytes 65_536
  @max_encoded_bytes 87_384
  @strict_base64 ~r/\A(?:[A-Za-z0-9+\/]{4})*(?:[A-Za-z0-9+\/]{2}==|[A-Za-z0-9+\/]{3}=)?\z/

  def widget(opts) when is_list(opts) do
    Mob.UI.native_view(__MODULE__, Keyword.put(opts, :id, :ios_terminal_surface))
  end

  @impl true
  def mount(props, socket), do: {:ok, assign_props(socket, props)}

  @impl true
  def update(props, socket), do: {:ok, assign_props(socket, props)}

  @impl true
  def render(assigns) do
    %{
      encoded_frame: assigns.encoded_frame,
      frame_bytes: assigns.frame_bytes,
      delivery_state: assigns.delivery_state,
      baseline_generation: assigns.baseline_generation,
      revision: assigns.revision,
      baseline_ready: assigns.baseline_ready,
      columns: assigns.columns,
      width: assigns.width,
      height: assigns.height
    }
  end

  @impl true
  def handle_event(
        "terminal_consumed",
        %{"generation" => generation, "revision" => revision},
        socket
      ) do
    cond do
      generation == socket.assigns.baseline_generation and
          revision == socket.assigns.revision ->
        send(socket.assigns.owner, {:ios_terminal_consumed, generation, revision})
        {:noreply, scrub(socket)}

      generation == socket.assigns.baseline_generation and
        is_integer(revision) and revision < socket.assigns.revision ->
        {:noreply, socket}

      true ->
        send(socket.assigns.owner, :ios_terminal_invalid_consumption)
        {:noreply, scrub(socket)}
    end
  end

  def handle_event(_event, _payload, socket) do
    send(socket.assigns.owner, :ios_terminal_invalid_consumption)
    {:noreply, scrub(socket)}
  end

  defp assign_props(socket, props) do
    encoded = Map.get(props, :encoded_frame, "")
    frame_bytes = Map.get(props, :frame_bytes, 0)
    baseline_generation = positive_integer(props[:baseline_generation])
    revision = non_negative_integer(props[:revision])

    bounded? =
      is_binary(encoded) and byte_size(encoded) <= @max_encoded_bytes and
        is_integer(frame_bytes) and frame_bytes >= 0 and frame_bytes <= @max_frame_bytes

    decodes_to_declared_size? = bounded? and decoded_size(encoded) == frame_bytes

    frame_delivery? =
      props[:delivery_state] in [:frame, "frame"] and props[:baseline_ready] == true and
        decodes_to_declared_size? and baseline_generation > 0 and revision >= 0

    socket
    |> Mob.Socket.assign(:owner, valid_owner(props[:owner]))
    |> Mob.Socket.assign(:encoded_frame, if(frame_delivery?, do: encoded, else: ""))
    |> Mob.Socket.assign(:frame_bytes, if(frame_delivery?, do: frame_bytes, else: 0))
    |> Mob.Socket.assign(:delivery_state, delivery_state(props[:delivery_state], frame_delivery?))
    |> Mob.Socket.assign(:baseline_generation, baseline_generation)
    |> Mob.Socket.assign(:revision, revision)
    |> Mob.Socket.assign(:baseline_ready, frame_delivery?)
    |> Mob.Socket.assign(:columns, bounded_integer(props[:columns], 1, 400, 80))
    |> Mob.Socket.assign(:width, bounded_number(props[:width], 1, 4_096, 720))
    |> Mob.Socket.assign(:height, bounded_number(props[:height], 1, 4_096, 432))
  end

  defp scrub(socket) do
    socket
    |> Mob.Socket.assign(:encoded_frame, "")
    |> Mob.Socket.assign(:frame_bytes, 0)
    |> Mob.Socket.assign(:delivery_state, "consumed")
    |> Mob.Socket.assign(:baseline_ready, false)
  end

  defp delivery_state(:frame, true), do: "frame"
  defp delivery_state("frame", true), do: "frame"
  defp delivery_state(:consumed, _frame_delivery?), do: "consumed"
  defp delivery_state("consumed", _frame_delivery?), do: "consumed"
  defp delivery_state(_state, _frame_delivery?), do: "covered"

  defp valid_owner(owner) when is_pid(owner), do: owner
  defp valid_owner(_owner), do: self()

  defp decoded_size(encoded) when rem(byte_size(encoded), 4) == 0 do
    if Regex.match?(@strict_base64, encoded) do
      decode_size(encoded)
    else
      :error
    end
  end

  defp decoded_size(_encoded), do: :error

  defp decode_size(encoded) do
    case Base.decode64(encoded, padding: true) do
      {:ok, decoded} -> byte_size(decoded)
      :error -> :error
    end
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: -1

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: -1

  defp bounded_integer(value, low, high, _default)
       when is_integer(value) and value >= low and value <= high,
       do: value

  defp bounded_integer(_value, _low, _high, default), do: default

  defp bounded_number(value, low, high, _default)
       when is_number(value) and value >= low and value <= high,
       do: value

  defp bounded_number(_value, _low, _high, default), do: default
end
