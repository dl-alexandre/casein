defmodule CaseinMob.PairingScreenTest do
  use Mob.ScreenCase, async: false

  alias CaseinMob.PairingScreen
  alias CaseinMob.SessionConfig
  alias CaseinMob.SessionDashboardScreen

  setup do
    prev_exchange_client = Application.get_env(:casein_mob, :device_link_exchange_client)
    SessionConfig.clear_all()

    on_exit(fn ->
      restore_exchange_client(prev_exchange_client)
    end)

    :ok
  end

  test "renders top navigation chrome" do
    view = mount_screen(PairingScreen)

    assert_renderable(view)
    assert text(view) =~ "Pair workspace"
    assert find(view, :button, text: "Back").props.fill_width == false
    refute find(view, :button, text: "← Back")
  end

  test "renders QR-primary, paste fallback, and manual fallback sections" do
    view = mount_screen(PairingScreen)

    assert text(view) =~ "Use the web cockpit QR code"
    assert find(view, :button, text: "Scan QR code")
    assert find(view, :button, text: "Scan QR code").props.background == :primary
    assert find(view, :button, text: "Paste & pair")
    assert find(view, :button, text: "Paste & pair").props.background == :surface_raised
    assert find(view, :button, text: "Paste & pair").props.height == 48.0
    assert text(view) =~ "Have a pairing code?"
    assert find(view, :button, text: "Pair")
    assert find(view, :button, text: "Pair").props.height == 44.0
    assert text(view) =~ "Each host is saved."
  end

  test "valid pairing code saves the prior host and scopes pins to the new host" do
    SessionConfig.put_pairing("https://old.test", "old-token")
    SessionConfig.pin_workspace("old-ws")

    code = pairing_code("https://casein.test", "new-token", "ws-1")

    view =
      PairingScreen
      |> mount_screen()
      |> render_info({:change, :code, code})
      |> render_info({:tap, :pair})

    assert SessionConfig.pairing() == {:ok, "https://casein.test", "new-token"}
    assert SessionConfig.pinned_workspaces() == ["ws-1"]

    assert SessionConfig.host_profiles() == [
             %{
               origin_id: CaseinMob.OriginIdentity.legacy_id("https://casein.test"),
               display_name: "casein.test",
               url: "https://casein.test",
               active?: true,
               read_only?: false,
               last_workspace_id: "ws-1"
             },
             %{
               origin_id: CaseinMob.OriginIdentity.legacy_id("https://old.test"),
               display_name: "old.test",
               url: "https://old.test",
               active?: false,
               read_only?: false,
               last_workspace_id: "old-ws"
             }
           ]

    assert assigns(view).state == :success
    assert text(view) =~ "Paired successfully"
    assert text(view) =~ "Workspace ws-1 is ready"
    assert find(view, :button, text: "Continue")
    refute navigated_to(view) == SessionDashboardScreen

    view = render_info(view, :pairing_success_done)
    assert navigated_to(view) == SessionDashboardScreen
  end

  test "pairing exchanges advertised bootstrap token for durable device credentials" do
    test_pid = self()

    Application.put_env(:casein_mob, :device_link_exchange_client, fn url, request ->
      send(test_pid, {:exchange, url, request})

      {:ok,
       %{
         url: "https://casein.test",
         token: "device-link-token",
         workspace_id: "ws-1",
         origin_id: CaseinMob.OriginIdentity.legacy_id("https://casein.test"),
         display_name: "casein.test"
       }}
    end)

    code =
      pairing_code("https://casein.test", "bootstrap-token", "ws-1",
        token_exchange_url: "https://casein.test/api/device-links/exchange"
      )

    view =
      PairingScreen
      |> mount_screen()
      |> render_info({:change, :code, code})
      |> render_info({:tap, :pair})

    assert_receive {:exchange, "https://casein.test/api/device-links/exchange", request}
    assert request.token == "bootstrap-token"
    assert is_binary(request.device_name)
    assert is_binary(request.platform)
    assert SessionConfig.pairing() == {:ok, "https://casein.test", "device-link-token"}
    assert SessionConfig.pinned_workspaces() == ["ws-1"]
    assert assigns(view).state == :success
  end

  test "scanned compact code exchanges an opaque handle without client-owned scope" do
    handle = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    test_pid = self()

    Application.put_env(:casein_mob, :device_link_exchange_client, fn url, request ->
      send(test_pid, {:exchange, url, request})

      {:ok,
       %{
         url: "https://casein.test",
         token: "device-link-token",
         workspace_id: "server-owned-ws",
         origin_id: "installation-1",
         display_name: "Devbox"
       }}
    end)

    code = compact_pairing_code("https://casein.test", handle)

    view =
      PairingScreen
      |> mount_screen()
      |> render_info({:scan, :result, %{type: :qr, value: code}})

    assert_receive {:exchange, "https://casein.test/api/device-links/exchange", request}
    assert request.handle == handle
    assert request.origin == "https://casein.test"
    assert request.audience == "casein_mobile"
    refute Map.has_key?(request, :workspace_id)
    refute Map.has_key?(request, :token)
    assert SessionConfig.pinned_workspaces() == ["server-owned-ws"]
    assert SessionConfig.pairing() == {:ok, "https://casein.test", "device-link-token"}
    assert text(view) =~ "Paired successfully"
  end

  test "structural and server exchange failures have distinct recovery messages" do
    structurally_invalid =
      PairingScreen
      |> mount_screen()
      |> render_info({:scan, :result, %{type: :qr, value: "casein://pair/not+base64url"}})

    assert text(structurally_invalid) =~ "doesn't look valid"

    Application.put_env(:casein_mob, :device_link_exchange_client, fn _url, _request ->
      {:error, :rejected}
    end)

    server_rejected =
      PairingScreen
      |> mount_screen()
      |> render_info(
        {:scan, :result,
         %{
           type: :qr,
           value:
             compact_pairing_code(
               "https://casein.test",
               Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
             )
         }}
      )

    assert text(server_rejected) =~ "couldn't verify"
    refute text(server_rejected) =~ "doesn't look valid"
  end

  test "explicit re-pair refreshes the same canonical profile without deleting its context" do
    SessionConfig.put_pairing(%{
      url: "https://casein.test",
      token: "old-token",
      origin_id: "installation-1",
      display_name: "Devbox"
    })

    SessionConfig.pin_workspace("existing-ws")
    SessionConfig.put_resume_context("existing-ws", session_id: "run-1")

    Application.put_env(:casein_mob, :device_link_exchange_client, fn _url, _request ->
      {:ok,
       %{
         url: "https://casein.test",
         token: "renewed-token",
         workspace_id: "existing-ws",
         origin_id: "installation-1",
         display_name: "Devbox"
       }}
    end)

    view =
      PairingScreen
      |> mount_screen()
      |> render_info(
        {:scan, :result,
         %{
           type: :qr,
           value:
             compact_pairing_code(
               "https://casein.test",
               Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
             )
         }}
      )

    assert SessionConfig.pairing() == {:ok, "https://casein.test", "renewed-token"}
    assert SessionConfig.pinned_workspaces() == ["existing-ws"]
    assert SessionConfig.resume_context().session_id == "run-1"
    assert length(SessionConfig.host_profiles()) == 1
    assert text(view) =~ "Connection refreshed"
  end

  test "failed compact exchange never looks paired or replaces a saved credential" do
    SessionConfig.put_pairing(%{
      url: "https://casein.test",
      token: "existing-token",
      origin_id: "installation-1",
      display_name: "Devbox"
    })

    Application.put_env(:casein_mob, :device_link_exchange_client, fn _url, _request ->
      {:error, :rejected}
    end)

    view =
      PairingScreen
      |> mount_screen()
      |> render_info(
        {:scan, :result,
         %{
           type: :qr,
           value:
             compact_pairing_code(
               "https://casein.test",
               Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
             )
         }}
      )

    assert assigns(view).state == :error
    assert text(view) =~ "couldn't verify"
    refute text(view) =~ "Paired successfully"
    refute text(view) =~ "Connection refreshed"
    assert SessionConfig.pairing() == {:ok, "https://casein.test", "existing-token"}
  end

  test "expired and replayed compact handles explain how to recover" do
    for {reason, expected} <- [
          {:pairing_expired, "expired or was refreshed"},
          {:pairing_already_used, "already used"}
        ] do
      Application.put_env(:casein_mob, :device_link_exchange_client, fn _url, _request ->
        {:error, reason}
      end)

      view =
        PairingScreen
        |> mount_screen()
        |> render_info(
          {:scan, :result,
           %{
             type: :qr,
             value:
               compact_pairing_code(
                 "https://casein.test",
                 Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
               )
           }}
        )

      assert assigns(view).state == :error
      assert text(view) =~ expected
      assert text(view) =~ "Refresh the cockpit QR"
    end
  end

  test "pairing code passed by a native deep link pairs without synthetic typing" do
    code = pairing_code("https://casein.test", "native-link-token", "ws-native")

    view =
      PairingScreen
      |> mount_screen(%{code: code})
      |> render_info({:pair_code, code})

    assert SessionConfig.pairing() == {:ok, "https://casein.test", "native-link-token"}
    assert SessionConfig.pinned_workspaces() == ["ws-native"]
    assert assigns(view).state == :success
  end

  test "success confirmation can continue immediately" do
    view =
      PairingScreen
      |> mount_screen()
      |> render_info({:change, :code, pairing_code("https://casein.test", "token", "ws-1")})
      |> render_info({:tap, :pair})
      |> render_info({:tap, :continue})

    assert navigated_to(view) == SessionDashboardScreen
  end

  test "pairing accepts a URL wrapper with a code query param" do
    code = pairing_code("https://casein.test", "token", "ws-2")
    url = "casein://pair?code=#{URI.encode_www_form(code)}"

    view =
      PairingScreen
      |> mount_screen()
      |> render_info({:change, :code, url})
      |> render_info({:tap, :pair})

    assert SessionConfig.pinned_workspaces() == ["ws-2"]
    assert assigns(view).state == :success
  end

  test "cancel returns from in-progress state to ready" do
    view =
      PairingScreen
      |> mount_screen()
      |> render_info({:tap, :pair})

    assert assigns(view).state == :error

    view =
      view
      |> render_info({:change, :code, pairing_code("https://casein.test", "token", "ws-1")})
      |> render_info({:tap, :pair})

    assert assigns(view).state == :success

    view =
      PairingScreen
      |> mount_screen(%{state: :pairing})
      |> render_info({:tap, :cancel_pairing})

    assert assigns(view).state == :ready
    refute text(view) =~ "Pairing..."
  end

  test "in-progress pairing state exposes progress and cancel affordances" do
    view = mount_screen(PairingScreen, %{state: :pairing})

    assert text(view) =~ "Pairing..."
    assert find(view, :progress)
    assert find(view, :button, text: "Cancel").props.height == 44.0
  end

  test "success timer is ignored unless the screen is in success state" do
    view =
      PairingScreen
      |> mount_screen()
      |> render_info(:pairing_success_done)

    refute navigated_to(view) == SessionDashboardScreen
  end

  test "scan button requests the native scanner and recovers when unavailable on host" do
    view =
      PairingScreen
      |> mount_screen()
      |> render_info({:tap, :scan_qr})

    assert assigns(view).state == :error
    assert text(view) =~ "Camera scanner isn't available"
    assert find(view, :button, text: "Paste & pair")
  end

  test "camera permission denial keeps paste/manual recovery available" do
    view =
      PairingScreen
      |> mount_screen(%{state: :scanning})
      |> render_info({:permission, :camera, :denied})

    assert assigns(view).state == :error
    assert text(view) =~ "Camera permission is required"
    assert find(view, :button, text: "Paste & pair")
  end

  test "camera permission grant opens scanner and recovers when scanner nif is unavailable on host" do
    view =
      PairingScreen
      |> mount_screen(%{state: :scanning})
      |> render_info({:permission, :camera, :granted})

    assert assigns(view).state == :error
    assert text(view) =~ "Camera scanner isn't available"
    assert find(view, :button, text: "Paste & pair")
  end

  test "scanner cancel returns to ready with fallback guidance" do
    view =
      PairingScreen
      |> mount_screen(%{state: :scanning})
      |> render_info({:scan, :cancelled})

    assert assigns(view).state == :ready
    assert text(view) =~ "Scan cancelled"
    assert find(view, :button, text: "Paste & pair")
  end

  test "scanned QR result follows the same pairing path" do
    code = pairing_code("https://casein.test", "token", "ws-scan")

    view =
      PairingScreen
      |> mount_screen()
      |> render_info({:scan, :result, %{type: :qr, value: code}})

    assert SessionConfig.pinned_workspaces() == ["ws-scan"]
    assert assigns(view).state == :success

    view = render_info(view, :pairing_success_done)
    assert navigated_to(view) == SessionDashboardScreen
  end

  test "scanned non-QR values still use the pairing parser" do
    code = pairing_code("https://casein.test", "token", "ws-barcode")

    view =
      PairingScreen
      |> mount_screen()
      |> render_info({:scan, :result, %{type: :code128, value: code}})

    assert SessionConfig.pinned_workspaces() == ["ws-barcode"]
    assert assigns(view).state == :success
  end

  test "invalid pairing code shows a recovery message" do
    view =
      PairingScreen
      |> mount_screen()
      |> render_info({:change, :code, "not-a-valid-code"})
      |> render_info({:tap, :pair})

    assert assigns(view).state == :error
    assert text(view) =~ "That code doesn't look valid"
    assert text(view) =~ "edit it below"
    assert find(view, :button, text: "Paste & pair")
  end

  defp pairing_code(url, token, workspace_id, extra \\ []) do
    %{
      url: url,
      token: token,
      workspace_id: workspace_id,
      token_type: "mobile_pairing"
    }
    |> Map.merge(Map.new(extra))
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp compact_pairing_code(origin, handle) do
    payload =
      %{"v" => 1, "o" => origin, "h" => handle}
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    "casein://pair/" <> payload
  end

  defp restore_exchange_client(nil),
    do: Application.delete_env(:casein_mob, :device_link_exchange_client)

  defp restore_exchange_client(client),
    do: Application.put_env(:casein_mob, :device_link_exchange_client, client)
end
