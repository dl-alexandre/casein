/**
 * Path helpers for the Casein preview Playwright bridge.
 *
 * Windows desktop installs pass absolute storage_state_path values with
 * backslashes (and drive letters). Node's default path API follows the host
 * OS, so a Linux or POSIX-only dirname would treat "C:\\…\\state.json" as a
 * single segment and mkdir/write into the wrong place. Always pick win32 vs
 * posix from the path shape, not from process.platform.
 */

import path from "node:path";

export function looksWindowsPath(filePath) {
  if (typeof filePath !== "string" || filePath.length === 0) return false;
  return (
    /^[A-Za-z]:[\\/]/.test(filePath) ||
    filePath.includes("\\") ||
    filePath.startsWith("\\\\")
  );
}

export function pathApiFor(filePath) {
  return looksWindowsPath(filePath) ? path.win32 : path.posix;
}

/**
 * Directory containing `filePath`, using the path API that matches the string.
 * Empty/invalid input yields "." (same contract as the previous helper).
 */
export function dirnameOf(filePath) {
  if (typeof filePath !== "string" || filePath.length === 0) return ".";

  const api = pathApiFor(filePath);
  const dir = api.dirname(filePath);

  if (typeof dir !== "string" || dir.length === 0) return ".";
  return dir;
}

/**
 * Accept a storage_state_path from the control session metadata.
 * Reject empty values, NULs, and bare relative traversal that would escape
 * the intended private storage root when joined later by the OS.
 */
export function sanitizeStorageStatePath(filePath) {
  if (typeof filePath !== "string" || filePath.length === 0) return null;
  if (filePath.includes("\0")) return null;
  if (/[\u0001-\u001f]/.test(filePath)) return null;

  const api = pathApiFor(filePath);
  const normalized = api.normalize(filePath);

  if (typeof normalized !== "string" || normalized.length === 0) return null;
  if (normalized.includes("\0")) return null;

  // Reject pure relative escapes after normalize (".." / "../x").
  if (normalized === ".." || normalized.startsWith(`..${api.sep}`)) return null;

  return normalized;
}
