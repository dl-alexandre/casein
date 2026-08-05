import assert from "node:assert/strict"
import test from "node:test"
import {readFileSync} from "node:fs"
import {createContext, runInContext} from "node:vm"
import {dirname, join} from "node:path"
import {fileURLToPath} from "node:url"

// service-worker.js is a classic worker script served straight out of
// priv/static (no bundler, no exports), so we evaluate it in a VM with a fake
// worker global and drive the real notificationclick listener.
const SW_PATH = join(
  dirname(fileURLToPath(import.meta.url)),
  "..",
  "..",
  "priv",
  "static",
  "service-worker.js"
)
const SW_SOURCE = readFileSync(SW_PATH, "utf8")
const ORIGIN = "https://casein.example"

function loadServiceWorker({windows = [], openWindow = () => null} = {}) {
  const listeners = {}
  const opened = []

  const clients = {
    matchAll: async () => windows,
    openWindow: async (url) => {
      opened.push(url)
      return openWindow(url)
    },
    claim: async () => {}
  }

  const self = {
    addEventListener: (type, handler) => {
      listeners[type] = handler
    },
    location: {origin: ORIGIN},
    registration: {showNotification: async () => {}},
    skipWaiting: async () => {},
    clients
  }

  const context = createContext({
    self,
    clients,
    caches: {open: async () => ({addAll: async () => {}}), keys: async () => []},
    URL,
    console
  })

  runInContext(SW_SOURCE, context)

  return {listeners, opened}
}

function fakeWindow(url, overrides = {}) {
  const record = {
    url,
    focused: false,
    visibilityState: "hidden",
    messages: [],
    navigatedTo: null,
    focusCount: 0,
    ...overrides
  }

  record.focus = async () => {
    record.focusCount += 1
    return record
  }
  record.postMessage = (message) => record.messages.push(message)
  record.navigate = async (target) => {
    if (record.navigateFails) throw new Error("not controlled")
    record.navigatedTo = target
    return record
  }

  return record
}

function clickNotification(listeners, {url, detail = {}}) {
  let closed = false
  const pending = []

  listeners.notificationclick({
    notification: {
      data: {url, ...detail},
      close: () => {
        closed = true
      }
    },
    waitUntil: (promise) => pending.push(promise)
  })

  return Promise.all(pending).then(() => ({closed}))
}

test("focuses a window already on the notification's workspace", async () => {
  const onWorkspace = fakeWindow(`${ORIGIN}/workspaces/ws-1?session=other`)
  const {listeners, opened} = loadServiceWorker({windows: [onWorkspace]})

  await clickNotification(listeners, {
    url: "/workspaces/ws-1?session=u-dev-abc",
    detail: {session_id: "u-dev-abc"}
  })

  assert.equal(onWorkspace.focusCount, 1)
  assert.equal(onWorkspace.navigatedTo, null)
  assert.deepEqual(opened, [])
  assert.equal(onWorkspace.messages[0].type, "CASEIN_AGENT_QUIET_OPEN")
  assert.equal(onWorkspace.messages[0].detail.session_id, "u-dev-abc")
})

test("navigates an existing window instead of opening a browser tab", async () => {
  // The desktop regression: an installed app window sitting on another
  // workspace (or the scratch root) used to be ignored, and the click opened a
  // fresh browser tab on "/".
  const scratch = fakeWindow(`${ORIGIN}/`, {focused: true})
  const {listeners, opened} = loadServiceWorker({windows: [scratch]})

  await clickNotification(listeners, {url: "/workspaces/ws-1?session=u-dev-abc"})

  assert.equal(scratch.navigatedTo, `${ORIGIN}/workspaces/ws-1?session=u-dev-abc`)
  assert.equal(scratch.focusCount, 1)
  assert.deepEqual(opened, [])
})

test("never pulls a window off its workspace onto the scratch root", async () => {
  const working = fakeWindow(`${ORIGIN}/workspaces/ws-9?session=u-dev-abc`)
  const {listeners, opened} = loadServiceWorker({windows: [working]})

  // An in-page notification with no workspace URL of its own.
  await clickNotification(listeners, {url: "/", detail: {type: "agent_quiet"}})

  assert.equal(working.navigatedTo, null)
  assert.equal(working.focusCount, 1)
  assert.deepEqual(opened, [])
  assert.equal(working.messages[0].detail.type, "agent_quiet")
})

test("prefers the window the operator is looking at", async () => {
  const background = fakeWindow(`${ORIGIN}/workspaces/ws-9`)
  const visible = fakeWindow(`${ORIGIN}/workspaces/ws-9`, {visibilityState: "visible"})
  const {listeners} = loadServiceWorker({windows: [background, visible]})

  await clickNotification(listeners, {url: "/workspaces/ws-9"})

  assert.equal(visible.focusCount, 1)
  assert.equal(background.focusCount, 0)
})

test("ignores windows from another origin", async () => {
  const foreign = fakeWindow("https://elsewhere.example/workspaces/ws-1")
  const {listeners, opened} = loadServiceWorker({windows: [foreign]})

  await clickNotification(listeners, {url: "/workspaces/ws-1"})

  assert.equal(foreign.focusCount, 0)
  assert.deepEqual(opened, [`${ORIGIN}/workspaces/ws-1`])
})

test("opens a window when navigate is not permitted", async () => {
  const uncontrolled = fakeWindow(`${ORIGIN}/`, {navigateFails: true})
  const target = fakeWindow(`${ORIGIN}/workspaces/ws-1`)
  const {listeners, opened} = loadServiceWorker({
    windows: [uncontrolled],
    openWindow: () => target
  })

  await clickNotification(listeners, {
    url: "/workspaces/ws-1",
    detail: {session_id: "u-dev-abc"}
  })

  assert.deepEqual(opened, [`${ORIGIN}/workspaces/ws-1`])
  assert.equal(target.messages[0].detail.session_id, "u-dev-abc")
})

test("opens a window when nothing of ours is running", async () => {
  const {listeners, opened} = loadServiceWorker({windows: []})

  await clickNotification(listeners, {url: "/workspaces/ws-1?session=u-dev-abc"})

  assert.deepEqual(opened, [`${ORIGIN}/workspaces/ws-1?session=u-dev-abc`])
})

test("closes the notification on click", async () => {
  const {listeners} = loadServiceWorker({windows: []})

  const {closed} = await clickNotification(listeners, {url: "/workspaces/ws-1"})

  assert.equal(closed, true)
})
