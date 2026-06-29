defmodule DevideMob.PairingScreenTest do
  use Mob.ScreenCase, async: false

  alias DevideMob.PairingScreen
  alias DevideMob.SessionConfig
  alias DevideMob.SessionDashboardScreen

  setup do
    SessionConfig.clear_all()
    :ok
  end

  test "renders top navigation chrome" do
    view = mount_screen(PairingScreen)

    assert_renderable(view)
    assert text(view) =~ "Pair workspace"
    assert find(view, :button, text: "Back")
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
    assert text(view) =~ "Pairs to one workspace at a time."
  end

  test "valid pairing code stores credentials, replaces pins, and shows success before returning" do
    SessionConfig.put_pairing("https://old.test", "old-token")
    SessionConfig.pin_workspace("old-ws")

    code = pairing_code("https://devide.test", "new-token", "ws-1")

    view =
      PairingScreen
      |> mount_screen()
      |> render_info({:change, :code, code})
      |> render_info({:tap, :pair})

    assert SessionConfig.pairing() == {:ok, "https://devide.test", "new-token"}
    assert SessionConfig.pinned_workspaces() == ["ws-1"]
    assert assigns(view).state == :success
    assert text(view) =~ "Paired successfully"
    assert text(view) =~ "Workspace ws-1 is ready"
    assert find(view, :button, text: "Continue")
    refute navigated_to(view) == SessionDashboardScreen

    view = render_info(view, :pairing_success_done)
    assert navigated_to(view) == SessionDashboardScreen
  end

  test "success confirmation can continue immediately" do
    view =
      PairingScreen
      |> mount_screen()
      |> render_info({:change, :code, pairing_code("https://devide.test", "token", "ws-1")})
      |> render_info({:tap, :pair})
      |> render_info({:tap, :continue})

    assert navigated_to(view) == SessionDashboardScreen
  end

  test "pairing accepts a URL wrapper with a code query param" do
    code = pairing_code("https://devide.test", "token", "ws-2")
    url = "devide://pair?code=#{URI.encode_www_form(code)}"

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
      |> render_info({:change, :code, pairing_code("https://devide.test", "token", "ws-1")})
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
    code = pairing_code("https://devide.test", "token", "ws-scan")

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
    code = pairing_code("https://devide.test", "token", "ws-barcode")

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

  defp pairing_code(url, token, workspace_id) do
    %{url: url, token: token, workspace_id: workspace_id, token_type: "mobile_pairing"}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end
end
