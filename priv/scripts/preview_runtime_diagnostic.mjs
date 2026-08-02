import fs from "fs/promises";

export async function diagnoseChromium(chromium, options = {}) {
  const executablePath = chromium.executablePath();

  try {
    const stat = await (options.stat || fs.stat)(executablePath);
    if (!stat.isFile()) throw new Error("resolved Chromium path is not a file");
  } catch (error) {
    throw diagnosticError("chromium_missing", error, executablePath);
  }

  let browser;

  try {
    browser = await chromium.launch({
      headless: true,
      args: options.launchArgs || [],
    });
    const page = await browser.newPage();
    await page.setContent('<title>Casein preview diagnostic</title><p id="ready">ready</p>');
    const ready = await page.locator("#ready").textContent();
    if (ready !== "ready") throw new Error("headless page verification failed");

    return {
      status: "ready",
      node_version: options.nodeVersion || process.version,
      chromium_executable: executablePath,
    };
  } catch (error) {
    throw diagnosticError("chromium_launch_failed", error, executablePath);
  } finally {
    if (browser) await browser.close().catch(() => {});
  }
}

function diagnosticError(code, error, executablePath) {
  const detail = error?.message || String(error);
  return new Error(
    `${code}: ${detail}; executable=${executablePath}; ` +
      "reinstall Casein from a verified package or roll back to the previous release"
  );
}
