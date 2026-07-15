# Push notifications

> OS push fan-out for session alerts and high-priority mobile cards. Reaches a
> backgrounded or killed `devide_mob` app — the "tell me when I need to pay
> attention, even when I'm not at my desk" half of the mobile companion.

## Responsibility

The push subsystem turns high-signal server events into APNs/FCM notifications
delivered to paired devices. It is the offline counterpart to the live channel:
`DevIdeWeb.SessionChannel` shows in-app banners only while a device is
connected, whereas `DevIDE.Push.Dispatcher` runs server-side regardless of any
live socket.

## End-to-end flow

```
device (devide_mob)                         server (dev_ide)
──────────────────                          ────────────────
OS push permission grant
  │
FirebaseMessaging.getInstance().token  ┐
didRegisterForRemoteNotifications…     ┘ → {:push_token, platform, token}
  │
SessionClient.register_push ───ws──▶ Channel "register_push"
                                      │
                                      ▼
                              DevIDE.Push.Registry         (token store, in-memory)
                                      │  Dispatcher.watch(workspace_id)
                                      ▼
  audit alert / needs_review card ─▶ DevIDE.Push.Dispatcher (subscribes spines)
                                      │  Push.provider()
                                      ▼
                              DevIDE.Push.NativeProvider   (routes by platform)
                                ├ android → FCMProvider  (HTTP v1 + OAuth)
                                └ ios     → APNSProvider  (ES256 JWT)
                                      │
                                      ▼  HTTP seam (Req in prod, stub in tests)
                                  FCM / APNs ──push──▶ device
```

Token acquisition is real on both platforms:

- **iOS** — `native/devide_mob/ios/AppDelegate.m`
  (`didRegisterForRemoteNotificationsWithDeviceToken`) hex-encodes the APNs
  device token and emits `{:push_token, :ios, token}`.
- **Android** — `native/devide_mob/android/.../io/mob/notify/MobNotifyBridge.kt`
  resolves the FCM token via `FirebaseMessaging.getInstance().token`; refreshes
  flow through `MobFirebaseService`.

`SessionDashboardScreen` drives the permission → token → register lifecycle and
re-registers on reconnect. The handoff and server pipeline are complete and
covered by tests (see "Verifying" below); the only thing standing between the
code and a real notification is **provider credentials**.

## Configuration (runtime.exs)

`config/runtime.exs` reads the environment and selects the provider. Nothing is
hardcoded — with no env set, the provider stays `DevIDE.Push.LogProvider` and
push is inert (logs only). Set credentials to go live.

### Provider selection

| `DEV_IDE_PUSH_PROVIDER` | Effect |
|-------------------------|--------|
| `native` | Route per-platform: Android→FCM, iOS→APNs (**recommended**) |
| `fcm` / `firebase` | Force every token through FCM |
| `apns` | Force every token through APNs |
| _unset_ | Auto-select `native` if any FCM/APNs env is present; otherwise stay on `LogProvider` |

### FCM (Android)

| Env var | Purpose |
|---------|---------|
| `DEV_IDE_FCM_PROJECT_ID` | Firebase project id (optional — inferred from the service account if omitted) |
| `DEV_IDE_FCM_SERVICE_ACCOUNT_JSON` | Raw service-account JSON |
| `DEV_IDE_FCM_SERVICE_ACCOUNT_PATH` / `GOOGLE_APPLICATION_CREDENTIALS` | Path to service-account JSON |
| `DEV_IDE_FCM_ACCESS_TOKEN` | Pre-minted OAuth token — handy for a quick smoke test without a service account |
| `DEV_IDE_FCM_TOKEN_URI` | Override the Google OAuth token endpoint (tests) |

`DevIDE.Push.FCMToken` mints and caches short-lived OAuth access tokens from the
service account (Google JWT-bearer flow), so no extra credential dependency is
needed.

### APNs (iOS)

| Env var | Purpose |
|---------|---------|
| `DEV_IDE_APNS_TEAM_ID` | Apple developer team id |
| `DEV_IDE_APNS_KEY_ID` | APNs auth key id (the `.p8`'s key id) |
| `DEV_IDE_APNS_TOPIC` | iOS app bundle id — **must match the signed build** (`com.alexandrefamilyfarm.devide-mob`, from `ios/Info.plist` / `ios/Provision.xcodeproj`). A mismatch is rejected with `DeviceTokenNotForTopic`. Note this is the iOS bundle id; Android's FCM applicationId is independent. |
| `DEV_IDE_APNS_PRIVATE_KEY` | The `.p8` PEM contents inline |
| `DEV_IDE_APNS_PRIVATE_KEY_PATH` | Path to the `.p8` file (alternative to inline) |
| `DEV_IDE_APNS_ENV` | `sandbox` (default) or `production` |

The provider mints the ES256 JWT itself and converts the DER ECDSA signature to
the raw 64-byte form APNs requires.

## Going live

### FCM, fastest path

1. In Firebase, create/download a service-account JSON with the Cloud Messaging
   role.
2. Export and start:
   ```bash
   export DEV_IDE_PUSH_PROVIDER=native
   export DEV_IDE_FCM_SERVICE_ACCOUNT_PATH=/run/secrets/firebase-service-account.json
   ```
3. Verify readiness (no send): `mix dev_ide.push.check --platform android`
4. Pair a device, trigger a `needs_review` (an agent approval request), confirm
   the banner arrives with the app backgrounded.

### APNs

The iOS app id and its push entitlement are registered with Apple by signing
`ios/Provision.xcodeproj` (bundle id `com.alexandrefamilyfarm.devide-mob`,
entitlement `aps-environment: development` → **sandbox**). That gives you the
provisioning profile and entitlement, but **not** the server credential — the
server authenticates to APNs with a `.p8` **auth key** you create separately.

1. Create the APNs auth key (one-time): Apple Developer portal → **Certificates,
   Identifiers & Profiles** → **Keys** → **+** → enable **Apple Push
   Notifications service (APNs)** → register → **download the `.p8`** (only
   downloadable once). Note the **Key ID** shown next to it.
2. Note your **Team ID** (Membership page, 10 chars) and the **bundle id** of the
   build that mints the token (`com.alexandrefamilyfarm.devide-mob`). The topic
   must equal that bundle id.
3. Export and start:
   ```bash
   export DEV_IDE_PUSH_PROVIDER=native
   export DEV_IDE_APNS_TEAM_ID=ABCDE12345              # your team id
   export DEV_IDE_APNS_KEY_ID=KEY1234567               # the .p8's key id
   export DEV_IDE_APNS_TOPIC=com.alexandrefamilyfarm.devide-mob
   export DEV_IDE_APNS_PRIVATE_KEY_PATH=/run/secrets/AuthKey_KEY1234567.p8
   export DEV_IDE_APNS_ENV=sandbox   # development builds register against sandbox
   ```
4. Verify: `mix dev_ide.push.check --platform ios`
5. The device token comes from the **real `devide_mob` build** (not the
   `MobProvision` shell) — `AppDelegate.m` registers for remote notifications via
   `mob_notify` after the user grants permission. Run it on a real device,
   pair, trigger an approval request, confirm the push arrives backgrounded.

> Sandbox vs production: a development/TestFlight build's device token only works
> against the matching APNs environment (`aps-environment: development` →
> sandbox). Mismatched env (`BadDeviceToken`) or a topic ≠ signed bundle id
> (`DeviceTokenNotForTopic`) are the two most common failures — the provider
> auto-unregisters such tokens.
>
> HTTP/2: APNs refuses HTTP/1.1 and closes the connection
> (`%Req.TransportError{reason: :closed}`). The server routes APNs through a
> dedicated HTTP/2 Finch pool (`DevIDE.Push.APNS.Finch`, started in
> `DevIDE.Supervision.PlatformServices`), so this is handled — but it means
> APNs delivery cannot be proven by the stub-based tests or `push.check` alone;
> a real send (even with a dummy token → `BadDeviceToken`) is what exercises the
> transport. A `403 InvalidProviderToken` instead means the team id / key id /
> `.p8` are wrong; a `400 BadDeviceToken` means auth is good and only the token
> is bad.

## Verifying

- `mix dev_ide.push.check` — config readiness for both platforms (exits non-zero
  if any requested platform is not ready). Each `not ready` line prints the
  specific missing env. This is a configuration check, not a send probe.
- **Offline end-to-end proof** (no credentials, no devices):
  - `test/dev_ide/push/delivery_integration_test.exs` drives a real spine event
    through `Dispatcher → NativeProvider → FCM/APNs provider → HTTP seam` and
    asserts the exact outbound URL, headers (incl. a real ES256 JWT / FCM bearer
    token), and JSON envelope.
  - `test/dev_ide/push_test.exs` covers dispatcher fan-out, workspace/user
    scoping, dedupe, and invalid-token auto-unregister against a fake provider.
  - `test/dev_ide/push/registry_test.exs` covers the token store directly.
  - Per-provider request shaping: `apns_provider_test.exs`,
    `fcm_provider_test.exs`, `fcm_token_test.exs`, `native_provider_test.exs`.

## Known simplifications

- **`DevIDE.Push.Registry` is in-memory** — tokens do not survive a restart.
  Devices re-register on reconnect, so this self-heals for connected devices but
  drops pushes to a device that never reconnects after a server restart. Swap
  for an Ecto-backed store when durability matters.
- **`DevIdeWeb.UserSocket` hardcodes `role: :owner`** for user-token
  connections — a placeholder until real auth roles land. See
  `lib/dev_ide_web/channel_auth.ex`.

## Related

- Deep-link scheme the payloads use: [`../deep_links.md`](../deep_links.md)
- Alert taxonomy shared with the live channel: `lib/dev_ide/alerts.ex`
- Card lifecycle that produces `needs_review` pushes: `lib/dev_ide/mobile/`
