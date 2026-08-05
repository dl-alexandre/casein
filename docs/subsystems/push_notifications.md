# Push notifications

> OS push fan-out for session alerts and high-priority mobile cards. Reaches a
> backgrounded or killed `casein_mob` app — the "tell me when I need to pay
> attention, even when I'm not at my desk" half of the mobile companion.

## Responsibility

The push subsystem turns high-signal server events into APNs/FCM notifications
delivered to paired devices. It is the offline counterpart to the live channel:
`CaseinWeb.SessionChannel` shows in-app banners only while a device is
connected, whereas `Casein.Push.Dispatcher` runs server-side regardless of any
live socket.

## End-to-end flow

```
device (casein_mob)                         server (casein)
──────────────────                          ────────────────
OS push permission grant
  │
FirebaseMessaging.getInstance().token  ┐
didRegisterForRemoteNotifications…     ┘ → {:push_token, platform, token}
  │
SessionClient.register_push ───ws──▶ Channel "register_push"
                                      │
                                      ▼
                              Casein.Push.Registry         (token store, in-memory)
                                      │  Dispatcher.watch(workspace_id)
                                      ▼
  audit alert / needs_review card ─▶ Casein.Push.Dispatcher (subscribes spines)
                                      │  Push.provider()
                                      ▼
                              Casein.Push.NativeProvider   (routes by platform)
                                ├ android → FCMProvider  (HTTP v1 + OAuth)
                                └ ios     → APNSProvider  (ES256 JWT)
                                      │
                                      ▼  HTTP seam (Req in prod, stub in tests)
                                  FCM / APNs ──push──▶ device
```

Token acquisition is real on both platforms:

- **iOS** — `native/casein_mob/ios/AppDelegate.m`
  (`didRegisterForRemoteNotificationsWithDeviceToken`) hex-encodes the APNs
  device token and emits `{:push_token, :ios, token}`.
- **Android** — `native/casein_mob/android/.../io/mob/notify/MobNotifyBridge.kt`
  resolves the FCM token via `FirebaseMessaging.getInstance().token`; refreshes
  flow through `MobFirebaseService`.

`SessionDashboardScreen` drives the permission → token → register lifecycle and
re-registers on reconnect. The handoff and server pipeline are complete and
covered by tests (see "Verifying" below); the only thing standing between the
code and a real notification is **provider credentials**.

## Configuration (runtime.exs)

`config/runtime.exs` reads the environment and selects the provider. Nothing is
hardcoded — with no env set, the provider stays `Casein.Push.LogProvider` and
push is inert (logs only). Set credentials to go live.

### Provider selection

| `CASEIN_PUSH_PROVIDER` | Effect |
|-------------------------|--------|
| `native` | Route per-platform: Android→FCM, iOS→APNs (**recommended**) |
| `fcm` / `firebase` | Force every token through FCM |
| `apns` | Force every token through APNs |
| _unset_ | Auto-select `native` if any FCM/APNs env is present; otherwise stay on `LogProvider` |

### FCM (Android)

| Env var | Purpose |
|---------|---------|
| `CASEIN_FCM_PROJECT_ID` | Firebase project id (optional — inferred from the service account if omitted) |
| `CASEIN_FCM_SERVICE_ACCOUNT_JSON` | Raw service-account JSON |
| `CASEIN_FCM_SERVICE_ACCOUNT_PATH` / `GOOGLE_APPLICATION_CREDENTIALS` | Path to service-account JSON |
| `CASEIN_FCM_ACCESS_TOKEN` | Pre-minted OAuth token — handy for a quick smoke test without a service account |
| `CASEIN_FCM_TOKEN_URI` | Override the Google OAuth token endpoint (tests) |

`Casein.Push.FCMToken` mints and caches short-lived OAuth access tokens from the
service account (Google JWT-bearer flow), so no extra credential dependency is
needed.

### APNs (iOS)

| Env var | Purpose |
|---------|---------|
| `CASEIN_APNS_TEAM_ID` | Apple developer team id |
| `CASEIN_APNS_KEY_ID` | APNs auth key id (the `.p8`'s key id) |
| `CASEIN_APNS_TOPIC` | iOS app bundle id — **must match the signed build** (`com.alexandrefamilyfarm.casein-mob`, from `ios/Info.plist` / `ios/Provision.xcodeproj`). A mismatch is rejected with `DeviceTokenNotForTopic`. Note this is the iOS bundle id; Android's FCM applicationId is independent. |
| `CASEIN_APNS_PRIVATE_KEY` | The `.p8` PEM contents inline |
| `CASEIN_APNS_PRIVATE_KEY_PATH` | Path to the `.p8` file (alternative to inline) |
| `CASEIN_APNS_ENV` | `sandbox` (default) or `production` |

The provider mints the ES256 JWT itself and converts the DER ECDSA signature to
the raw 64-byte form APNs requires.

### Web Push (installed PWA)

| Env var | Purpose |
|---------|---------|
| `CASEIN_VAPID_PUBLIC_KEY` | VAPID public key (base64url) — also served to the browser so it can subscribe |
| `CASEIN_VAPID_PRIVATE_KEY` | VAPID private key (base64url) |
| `CASEIN_VAPID_SUBJECT` | `mailto:` / `https:` contact for the push service (default `mailto:admin@localhost`) |

With VAPID keys present, `NativeProvider` routes `"web"` tokens to
`Casein.Push.WebPushProvider`, so browser and native pushes coexist. The
browser subscribes via `assets/js/web_push.js` and the payload is delivered to
the `push` handler in `priv/static/service-worker.js`.

Two things are load-bearing for a desktop PWA, and both were broken until
2026-08-03:

- **Deep links must be http.** Notifications carry a native `casein://` deep
  link that no browser can open. `Casein.Push.WebLink` rewrites it into a real
  workspace URL (`/workspaces/{id}?session=…&window=…`, see
  [`../deep_links.md`](../deep_links.md)), carrying the card's locator so the
  click lands on the pane the agent is waiting in. Only a notification with no
  workspace at all falls back to `/` — and `/` mounts the **scratch**
  workspace, which is exactly the symptom of a lost deep link.
- **Clicks must reuse an open window.** `notificationclick` prefers a window
  already on the target workspace (focus + attach in place), then any other
  window of ours (focus + `navigate`), and only opens a new window when nothing
  is running. Without that, every click spawned a browser tab beside the
  installed app windows the operator already had open.

Payloads name the workspace in the title (`dev-ide — Agent needs
clarification`) because the OS shows only the app name, and they tag per
waiting agent (`casein:{attention_key}`) rather than per workspace, so two
agents in one workspace do not overwrite each other's notification.

## Going live

### FCM, fastest path

1. In Firebase, create/download a service-account JSON with the Cloud Messaging
   role.
2. Export and start:
   ```bash
   export CASEIN_PUSH_PROVIDER=native
   export CASEIN_FCM_SERVICE_ACCOUNT_PATH=/run/secrets/firebase-service-account.json
   ```
3. Verify readiness (no send): `mix casein.push.check --platform android`
4. Pair a device, trigger a `needs_review` (an agent approval request), confirm
   the banner arrives with the app backgrounded.

### APNs

The iOS app id and its push entitlement are registered with Apple by signing
`ios/Provision.xcodeproj` (bundle id `com.alexandrefamilyfarm.casein-mob`,
entitlement `aps-environment: development` → **sandbox**). That gives you the
provisioning profile and entitlement, but **not** the server credential — the
server authenticates to APNs with a `.p8` **auth key** you create separately.

1. Create the APNs auth key (one-time): Apple Developer portal → **Certificates,
   Identifiers & Profiles** → **Keys** → **+** → enable **Apple Push
   Notifications service (APNs)** → register → **download the `.p8`** (only
   downloadable once). Note the **Key ID** shown next to it.
2. Note your **Team ID** (Membership page, 10 chars) and the **bundle id** of the
   build that mints the token (`com.alexandrefamilyfarm.casein-mob`). The topic
   must equal that bundle id.
3. Export and start:
   ```bash
   export CASEIN_PUSH_PROVIDER=native
   export CASEIN_APNS_TEAM_ID=ABCDE12345              # your team id
   export CASEIN_APNS_KEY_ID=KEY1234567               # the .p8's key id
   export CASEIN_APNS_TOPIC=com.alexandrefamilyfarm.casein-mob
   export CASEIN_APNS_PRIVATE_KEY_PATH=/run/secrets/AuthKey_KEY1234567.p8
   export CASEIN_APNS_ENV=sandbox   # development builds register against sandbox
   ```
4. Verify: `mix casein.push.check --platform ios`
5. The device token comes from the **real `casein_mob` build** (not the
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
> dedicated HTTP/2 Finch pool (`Casein.Push.APNS.Finch`, started in
> `Casein.Supervision.PlatformServices`), so this is handled — but it means
> APNs delivery cannot be proven by the stub-based tests or `push.check` alone;
> a real send (even with a dummy token → `BadDeviceToken`) is what exercises the
> transport. A `403 InvalidProviderToken` instead means the team id / key id /
> `.p8` are wrong; a `400 BadDeviceToken` means auth is good and only the token
> is bad.

## Verifying

- `mix casein.push.check` — config readiness for both platforms (exits non-zero
  if any requested platform is not ready). Each `not ready` line prints the
  specific missing env. This is a configuration check, not a send probe.
- **Offline end-to-end proof** (no credentials, no devices):
  - `test/casein/push/delivery_integration_test.exs` drives a real spine event
    through `Dispatcher → NativeProvider → FCM/APNs provider → HTTP seam` and
    asserts the exact outbound URL, headers (incl. a real ES256 JWT / FCM bearer
    token), and JSON envelope.
  - `test/casein/push_test.exs` covers dispatcher fan-out, workspace/user
    scoping, dedupe, and invalid-token auto-unregister against a fake provider.
  - `test/casein/push/registry_test.exs` covers the token store directly.
  - Per-provider request shaping: `apns_provider_test.exs`,
    `fcm_provider_test.exs`, `fcm_token_test.exs`, `native_provider_test.exs`.
  - Web Push: `web_link_test.exs` (URL rewriting), `web_push_provider_test.exs`
    (payload shape — the wire body is encrypted, so the payload builder is the
    only readable seam), and `assets/test/service_worker_notification_click.test.mjs`,
    which evaluates the real `service-worker.js` in a VM and drives its
    `notificationclick` listener against fake windows.

## Known simplifications

- **`Casein.Push.Registry` is in-memory** — tokens do not survive a restart.
  Devices re-register on reconnect, so this self-heals for connected devices but
  drops pushes to a device that never reconnects after a server restart. Swap
  for an Ecto-backed store when durability matters.
- **`CaseinWeb.UserSocket` hardcodes `role: :owner`** for user-token
  connections — a placeholder until real auth roles land. See
  `lib/casein_web/channel_auth.ex`.

## Related

- Deep-link scheme the payloads use: [`../deep_links.md`](../deep_links.md)
- Alert taxonomy shared with the live channel: `lib/casein/alerts.ex`
- Card lifecycle that produces `needs_review` pushes: `lib/casein/mobile/`
