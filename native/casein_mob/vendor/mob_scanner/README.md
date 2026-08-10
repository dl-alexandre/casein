# mob_scanner

QR code / barcode scanner for apps built with [Mob](https://hexdocs.pm/mob) —
extracted from mob core as a plugin. Opens a full-screen camera preview; when
a code is detected the view dismisses automatically and the result lands in
`handle_info`.

iOS: `AVCaptureMetadataOutput`. Android: CameraX + ML Kit `BarcodeScanning`
in a plugin-owned full-screen activity.

## Installation

Requires **mob_camera activated alongside** — the `:camera` runtime
permission (and the iOS `NSCameraUsageDescription` plist key) is owned by
mob_camera:

```elixir
# mix.exs
{:mob_scanner, "~> 0.1"},
{:mob_camera,  "~> 0.1"}

# mob.exs
config :mob, :plugins, [:mob_camera, :mob_scanner]
```

Request `:camera` via `Mob.Permissions.request(socket, :camera)` before
scanning.

## Usage

```elixir
socket = MobScanner.scan(socket, formats: [:qr])

def handle_info({:scan, :result, %{type: :qr, value: value}}, socket), do: ...
def handle_info({:scan, :cancelled}, socket), do: ...
# iOS additionally delivers {:scan, :not_available} when no camera input can be opened
```

Formats: `:qr`, `:ean13`, `:ean8`, `:code128`, `:code39`, `:upca`, `:upce`,
`:pdf417`, `:aztec`, `:data_matrix`.

## Host app requirements

`AndroidManifest.xml` must declare the scanner activity inside
`<application>` (mob_new-generated apps already include it):

```xml
<activity android:name="io.mob.scanner.MobScannerActivity"
          android:exported="false"
          android:theme="@style/Theme.AppCompat.NoActionBar" />
```

Without the declaration the app builds and boots fine, then throws
`ActivityNotFoundException` at first scan. The AppCompat theme is required —
`MobScannerActivity` extends `AppCompatActivity` and throws
`IllegalStateException` at `setContentView` under a non-AppCompat theme.

## Limits

- The `formats:` option is currently ignored by both native sides (core
  parity: iOS hardcodes its metadata object types, Android scans all ML Kit
  formats). It's encoded and passed through, so honoring it later is a
  non-breaking change.

## Development

Clone, then run once:

```bash
mix setup
```

That fetches deps and activates the repo's git hooks (`.githooks/pre-push`):
`mix format --check`, `mix credo --strict` (incl. ExSlop), and `mix compile --warnings-as-errors` run on every push, plus the full test
suite when `mix.exs` changes — the same gate CI enforces before publishing.

## License

MIT
