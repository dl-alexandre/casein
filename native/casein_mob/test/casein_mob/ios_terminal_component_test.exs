defmodule CaseinMob.IOSTerminalComponentTest do
  use ExUnit.Case, async: true

  alias CaseinMob.IOSTerminalComponent

  test "widget has the exact native registry module and a fixed identity" do
    node =
      IOSTerminalComponent.widget(
        owner: self(),
        encoded_frame: Base.encode64("fixture"),
        frame_bytes: 7,
        delivery_state: :frame,
        baseline_generation: 1,
        revision: 0,
        baseline_ready: true,
        columns: 80,
        width: 720,
        height: 432
      )

    assert node.type == :native_view
    assert node.props.module == IOSTerminalComponent
    assert node.props.id == :ios_terminal_surface
  end

  test "component forwards only a bounded current frame and identity metadata" do
    socket = Mob.Socket.new(IOSTerminalComponent, platform: :no_render)

    props = %{
      owner: self(),
      encoded_frame: Base.encode64("fixture"),
      frame_bytes: 7,
      delivery_state: :frame,
      baseline_generation: 3,
      revision: 4,
      baseline_ready: true,
      columns: 80,
      width: 720,
      height: 432
    }

    assert {:ok, mounted} = IOSTerminalComponent.mount(props, socket)
    expected = props |> Map.delete(:owner) |> Map.put(:delivery_state, "frame")
    assert IOSTerminalComponent.render(mounted.assigns) == expected
  end

  test "validated native consumption scrubs the encoded copy and notifies its owner" do
    socket = Mob.Socket.new(IOSTerminalComponent, platform: :no_render)

    props = %{
      owner: self(),
      encoded_frame: Base.encode64("fixture"),
      frame_bytes: 7,
      delivery_state: :frame,
      baseline_generation: 3,
      revision: 4,
      baseline_ready: true,
      columns: 80,
      width: 720,
      height: 432
    }

    assert {:ok, mounted} = IOSTerminalComponent.mount(props, socket)

    assert {:noreply, scrubbed} =
             IOSTerminalComponent.handle_event(
               "terminal_consumed",
               %{"generation" => 3, "revision" => 4},
               mounted
             )

    assert_receive {:ios_terminal_consumed, 3, 4}
    rendered = IOSTerminalComponent.render(scrubbed.assigns)
    assert rendered.encoded_frame == ""
    assert rendered.frame_bytes == 0
    assert rendered.delivery_state == "consumed"
    refute rendered.baseline_ready
  end

  test "mismatched consumption scrubs and forces the parent fail-covered path" do
    socket = Mob.Socket.new(IOSTerminalComponent, platform: :no_render)

    props = %{
      owner: self(),
      encoded_frame: Base.encode64("fixture"),
      frame_bytes: 7,
      delivery_state: :frame,
      baseline_generation: 3,
      revision: 4,
      baseline_ready: true,
      columns: 80,
      width: 720,
      height: 432
    }

    assert {:ok, mounted} = IOSTerminalComponent.mount(props, socket)

    assert {:noreply, scrubbed} =
             IOSTerminalComponent.handle_event(
               "terminal_consumed",
               %{"generation" => 3, "revision" => 5},
               mounted
             )

    assert_receive :ios_terminal_invalid_consumption
    assert IOSTerminalComponent.render(scrubbed.assigns).encoded_frame == ""
  end

  test "same-generation older acknowledgment is ignored while the newest slot remains pending" do
    socket = Mob.Socket.new(IOSTerminalComponent, platform: :no_render)

    props = %{
      owner: self(),
      encoded_frame: Base.encode64("fixture"),
      frame_bytes: 7,
      delivery_state: :frame,
      baseline_generation: 3,
      revision: 5,
      baseline_ready: true,
      columns: 80,
      width: 720,
      height: 432
    }

    assert {:ok, mounted} = IOSTerminalComponent.mount(props, socket)

    assert {:noreply, unchanged} =
             IOSTerminalComponent.handle_event(
               "terminal_consumed",
               %{"generation" => 3, "revision" => 4},
               mounted
             )

    refute_receive {:ios_terminal_consumed, _, _}
    refute_receive :ios_terminal_invalid_consumption
    rendered = IOSTerminalComponent.render(unchanged.assigns)
    assert rendered.revision == 5
    assert rendered.encoded_frame == Base.encode64("fixture")
    assert rendered.delivery_state == "frame"
  end

  test "oversized and malformed identity props fail covered without retaining content" do
    socket = Mob.Socket.new(IOSTerminalComponent, platform: :no_render)

    props = %{
      owner: self(),
      encoded_frame: String.duplicate("A", 87_388),
      frame_bytes: 65_537,
      delivery_state: :frame,
      baseline_generation: nil,
      revision: -1,
      baseline_ready: true,
      columns: 999,
      width: 99_999,
      height: 99_999
    }

    assert {:ok, mounted} = IOSTerminalComponent.mount(props, socket)
    rendered = IOSTerminalComponent.render(mounted.assigns)

    assert rendered.encoded_frame == ""
    assert rendered.frame_bytes == 0
    assert rendered.delivery_state == "covered"
    assert rendered.baseline_generation == -1
    assert rendered.revision == -1
    refute rendered.baseline_ready
    assert rendered.columns == 80
    assert rendered.width == 720
    assert rendered.height == 432
  end

  test "non-frame and invalid-identity states never retain or reflect a valid-sized payload" do
    encoded = Base.encode64("private fixture")

    for overrides <- [
          %{delivery_state: :consumed, baseline_ready: false},
          %{delivery_state: :covered, baseline_ready: false},
          %{delivery_state: :frame, baseline_ready: true, baseline_generation: nil},
          %{delivery_state: :frame, baseline_ready: true, revision: -1}
        ] do
      socket = Mob.Socket.new(IOSTerminalComponent, platform: :no_render)

      props =
        Map.merge(
          %{
            owner: self(),
            encoded_frame: encoded,
            frame_bytes: 15,
            delivery_state: :frame,
            baseline_generation: 3,
            revision: 4,
            baseline_ready: true,
            columns: 80,
            width: 720,
            height: 432
          },
          overrides
        )

      assert {:ok, mounted} = IOSTerminalComponent.mount(props, socket)
      rendered = IOSTerminalComponent.render(mounted.assigns)
      assert rendered.encoded_frame == ""
      assert rendered.frame_bytes == 0
      refute inspect(rendered) =~ encoded
    end
  end

  test "malformed base64 and declared-size mismatch scrub immediately without reflection" do
    for {encoded, declared_bytes} <- [
          {"!!!!", 3},
          {"A===", 1},
          {"AAAA====", 3},
          {Base.encode64("fixture"), 6}
        ] do
      socket = Mob.Socket.new(IOSTerminalComponent, platform: :no_render)

      props = %{
        owner: self(),
        encoded_frame: encoded,
        frame_bytes: declared_bytes,
        delivery_state: :frame,
        baseline_generation: 3,
        revision: 4,
        baseline_ready: true,
        columns: 80,
        width: 720,
        height: 432
      }

      assert {:ok, mounted} = IOSTerminalComponent.mount(props, socket)
      rendered = IOSTerminalComponent.render(mounted.assigns)
      assert rendered.encoded_frame == ""
      assert rendered.frame_bytes == 0
      assert rendered.delivery_state == "covered"
      refute rendered.baseline_ready
      refute inspect(rendered) =~ encoded
    end
  end

  test "exact decoded cap is admitted and one byte over is scrubbed" do
    exact = :binary.copy(<<0>>, 65_536)
    over = exact <> <<0>>

    for {frame, admitted?} <- [{exact, true}, {over, false}] do
      socket = Mob.Socket.new(IOSTerminalComponent, platform: :no_render)
      encoded = Base.encode64(frame)

      props = %{
        owner: self(),
        encoded_frame: encoded,
        frame_bytes: byte_size(frame),
        delivery_state: :frame,
        baseline_generation: 3,
        revision: 4,
        baseline_ready: true,
        columns: 80,
        width: 720,
        height: 432
      }

      assert {:ok, mounted} = IOSTerminalComponent.mount(props, socket)
      rendered = IOSTerminalComponent.render(mounted.assigns)

      if admitted? do
        assert rendered.encoded_frame == encoded
        assert rendered.frame_bytes == 65_536
        assert rendered.delivery_state == "frame"
      else
        assert rendered.encoded_frame == ""
        assert rendered.frame_bytes == 0
        assert rendered.delivery_state == "covered"
        refute inspect(rendered) =~ encoded
      end
    end
  end
end
