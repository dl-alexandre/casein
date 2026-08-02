import assert from "node:assert/strict";
import { test } from "node:test";
import { diagnoseChromium } from "./preview_runtime_diagnostic.mjs";

function fakeChromium(overrides = {}) {
  return {
    executablePath: () => "C:\\Casein\\chromium.exe",
    launch: async () => ({
      newPage: async () => ({
        setContent: async () => {},
        locator: () => ({ textContent: async () => "ready" }),
      }),
      close: async () => {},
    }),
    ...overrides,
  };
}

test("reports the release-local Chromium path after a headless launch", async () => {
  const result = await diagnoseChromium(fakeChromium(), {
    stat: async () => ({ isFile: () => true }),
    nodeVersion: "v-test",
  });

  assert.deepEqual(result, {
    status: "ready",
    node_version: "v-test",
    chromium_executable: "C:\\Casein\\chromium.exe",
  });
});

test("missing Chromium has an actionable offline repair message", async () => {
  await assert.rejects(
    diagnoseChromium(fakeChromium(), {
      stat: async () => {
        throw new Error("ENOENT");
      },
    }),
    /chromium_missing: ENOENT.*reinstall Casein from a verified package or roll back/
  );
});

test("launch failures close the browser and retain the executable path", async () => {
  let closed = false;
  const chromium = fakeChromium({
    launch: async () => ({
      newPage: async () => {
        throw new Error("missing runtime DLL");
      },
      close: async () => {
        closed = true;
      },
    }),
  });

  await assert.rejects(
    diagnoseChromium(chromium, { stat: async () => ({ isFile: () => true }) }),
    /chromium_launch_failed: missing runtime DLL.*executable=C:\\Casein\\chromium.exe/
  );
  assert.equal(closed, true);
});
