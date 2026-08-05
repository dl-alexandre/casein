defmodule CaseinWeb.MobileTerminalChannelTest do
  use CaseinWeb.ConnCase, async: true

  import Phoenix.ChannelTest

  alias CaseinWeb.MobileTerminalChannel

  test "join failures echo only the bounded connection generation" do
    generation = Ecto.UUID.generate()

    socket =
      socket(CaseinWeb.UserSocket, "mobile-terminal-test", %{
        socket_credential: :device_link_token
      })

    assert {:error,
            %{
              "schema" => "mobile_terminal_v1",
              "reason" => "not_found",
              "connection_generation" => ^generation
            }} =
             MobileTerminalChannel.join(
               "mobile_terminal:#{Ecto.UUID.generate()}",
               %{
                 "child_grant" => "one-time-secret",
                 "connection_generation" => generation
               },
               socket
             )

    refute inspect(
             MobileTerminalChannel.join(
               "mobile_terminal:#{Ecto.UUID.generate()}",
               %{"child_grant" => "one-time-secret"},
               socket
             )
           ) =~ "one-time-secret"
  end

  test "terminal mutations are explicitly rejected as read only" do
    socket = socket(CaseinWeb.UserSocket, "mobile-terminal-test", %{})

    for event <- ["terminal_input", "terminal_paste", "terminal_query"] do
      assert {:reply,
              {:error,
               %{
                 "schema" => "mobile_terminal_v1",
                 "reason" => "read_only"
               }}, ^socket} = MobileTerminalChannel.handle_in(event, %{}, socket)
    end
  end

  test "unknown messages fail closed" do
    socket = socket(CaseinWeb.UserSocket, "mobile-terminal-test", %{})

    assert {:reply, {:error, %{"reason" => "invalid_payload"}}, ^socket} =
             MobileTerminalChannel.handle_in("terminal_exec", %{}, socket)
  end

  test "output hot path only renders the already-authorized stream frame" do
    lifecycle = Ecto.UUID.generate()

    socket =
      socket(CaseinWeb.UserSocket, "mobile-terminal-test", %{})
      |> Phoenix.Socket.assign(:terminal_lease, %{lifecycle_generation: lifecycle})
      |> Map.put(:joined, true)
      |> Map.put(:topic, "mobile_terminal:test")

    frame = %{
      lease_id: Ecto.UUID.generate(),
      connection_generation: Ecto.UUID.generate(),
      stream_generation: Ecto.UUID.generate(),
      offset: 0,
      next_offset: 3,
      bytes: "abc"
    }

    assert {:noreply, ^socket} =
             MobileTerminalChannel.handle_info({:mobile_terminal_output, frame}, socket)

    assert_push "terminal_output", %{"bytes_base64" => "YWJj", "next_offset" => 3}
  end
end
