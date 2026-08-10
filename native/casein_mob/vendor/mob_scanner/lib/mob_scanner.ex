defmodule MobScanner do
  @moduledoc """
  QR code / barcode scanner — a Mob plugin (extracted from mob core in
  Wave 3).

  Opens a full-screen camera preview. When a code is detected the view
  dismisses automatically and the result is delivered to `handle_info`:

      handle_info({:scan, :result,    %{type: :qr, value: "https://..."}}, socket)
      handle_info({:scan, :cancelled},                                       socket)

  iOS additionally delivers `{:scan, :not_available}` when no camera input
  can be opened (core parity, ios/mob_nif.m:2957).

  **Requires the mob_camera plugin for the `:camera` permission.** The
  `:camera` runtime-permission capability (its registry handler on iOS and
  the `MobPermissionProvider` mapping on Android) is owned by mob_camera —
  activate mob_camera alongside this plugin and request `:camera` via
  `Mob.Permissions.request/2` before calling `scan/2`. mob_camera's manifest
  also carries the iOS `NSCameraUsageDescription` plist key.

  iOS: `AVCaptureMetadataOutput`. Android: `CameraX` + ML Kit
  `BarcodeScanning` in a plugin-owned full-screen Activity
  (`io.mob.scanner.MobScannerActivity`) — the host AndroidManifest must
  declare it (see `host_requirements` in `priv/mob_plugin.exs`).
  """

  @type format ::
          :qr
          | :ean13
          | :ean8
          | :code128
          | :code39
          | :upca
          | :upce
          | :pdf417
          | :aztec
          | :data_matrix

  @doc """
  Open the barcode scanner.

  Options:
    - `formats: [format]` — list of barcode formats to detect (default `[:qr]`)

  Core-parity note: both native sides currently ignore the formats list
  (iOS hardcodes its `metadataObjectTypes`, ios/mob_nif.m:2966-2971; the
  Android activity scans all ML Kit formats) — it is encoded and passed
  through so honoring it later is a non-breaking change.
  """
  @spec scan(Mob.Socket.t(), keyword()) :: Mob.Socket.t()
  def scan(socket, opts \\ []) do
    formats = Keyword.get(opts, :formats, [:qr]) |> Enum.map(&Atom.to_string/1)
    formats_json = :json.encode(formats)
    :mob_scanner_nif.scanner_scan(formats_json)
    socket
  end
end
