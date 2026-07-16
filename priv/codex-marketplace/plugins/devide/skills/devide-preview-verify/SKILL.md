---
name: devide-preview-verify
description: Verify web UI behavior through DevIDE's operator-visible Preview MCP surface. Use after changing Phoenix LiveView, HTML, CSS, JavaScript, navigation, forms, responsive layout, or other browser-visible behavior.
---

# DevIDE preview verification

1. Resolve the workspace and call `preview_surfaces` before opening when the target is unclear.
2. Open the app with `preview_open_app` or the appropriate `preview_open` mode.
3. Confirm `operator_visible` and `browser_loaded`; a running server alone is not visual proof.
4. Observe the hydrated page with `preview_observe_live`, then use `preview_elements` to obtain stable element ids.
5. Drive the relevant flow with `preview_click`, `preview_type`, and `preview_press`. Prefer element ids over guessed selectors.
6. Capture a screenshot when layout or visual state matters, and inspect reported browser errors.
7. Close the preview with `preview_close` after verification unless the operator asked to keep it open.

Report the exact flow checked and any behavior that could not be verified.
