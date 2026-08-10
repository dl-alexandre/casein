import assert from "node:assert/strict";
import { test } from "node:test";
import {
  dirnameOf,
  looksWindowsPath,
  pathApiFor,
  sanitizeStorageStatePath,
} from "./preview_playwright_paths.mjs";
import path from "node:path";

test("looksWindowsPath detects drive letters, backslashes, and UNC", () => {
  assert.equal(looksWindowsPath("C:\\Casein\\state.json"), true);
  assert.equal(looksWindowsPath("c:/Casein/state.json"), true);
  assert.equal(looksWindowsPath("\\\\server\\share\\state.json"), true);
  assert.equal(looksWindowsPath("/var/casein/state.json"), false);
  assert.equal(looksWindowsPath(""), false);
  assert.equal(looksWindowsPath(null), false);
});

test("pathApiFor selects win32 for Windows-shaped paths", () => {
  assert.equal(pathApiFor("D:\\a\\b.json"), path.win32);
  assert.equal(pathApiFor("/tmp/a/b.json"), path.posix);
});

test("dirnameOf handles Windows absolute storage paths (the packaging bug)", () => {
  assert.equal(
    dirnameOf("C:\\Users\\casein\\AppData\\Local\\Casein\\preview\\ws\\ab\\workspace.json"),
    "C:\\Users\\casein\\AppData\\Local\\Casein\\preview\\ws\\ab"
  );
  assert.equal(dirnameOf("C:\\state.json"), "C:\\");
  assert.equal(dirnameOf("\\\\server\\share\\a\\b.json"), "\\\\server\\share\\a");
});

test("dirnameOf still handles POSIX absolute paths", () => {
  assert.equal(dirnameOf("/var/casein/preview/ws/ab/workspace.json"), "/var/casein/preview/ws/ab");
  assert.equal(dirnameOf("/tmp/state.json"), "/tmp");
});

test("dirnameOf rejects empty input with '.'", () => {
  assert.equal(dirnameOf(""), ".");
  assert.equal(dirnameOf(undefined), ".");
});

test("sanitizeStorageStatePath accepts Windows and POSIX absolutes", () => {
  assert.equal(
    sanitizeStorageStatePath("C:\\Casein\\preview\\state.json"),
    "C:\\Casein\\preview\\state.json"
  );
  assert.equal(
    sanitizeStorageStatePath("/var/casein/preview/state.json"),
    "/var/casein/preview/state.json"
  );
});

test("sanitizeStorageStatePath rejects NUL, controls, empty, and bare traversal", () => {
  assert.equal(sanitizeStorageStatePath(""), null);
  assert.equal(sanitizeStorageStatePath(null), null);
  assert.equal(sanitizeStorageStatePath("a\0b.json"), null);
  assert.equal(sanitizeStorageStatePath("a\nb.json"), null);
  assert.equal(sanitizeStorageStatePath(".."), null);
  assert.equal(sanitizeStorageStatePath("../escape.json"), null);
});

test("sanitizeStorageStatePath normalizes redundant separators without collapsing roots", () => {
  assert.equal(
    sanitizeStorageStatePath("C:\\\\Casein\\\\preview\\\\state.json"),
    "C:\\Casein\\preview\\state.json"
  );
  assert.equal(
    sanitizeStorageStatePath("/var//casein///preview/state.json"),
    "/var/casein/preview/state.json"
  );
});
