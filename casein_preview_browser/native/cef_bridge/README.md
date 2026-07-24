# cef_bridge

Dormant scaffold for a possible future Rustler/CEF backend.

This crate is intentionally not wired into `mix.exs`, CI, or runtime startup.
The first real backend is the external-process protocol in
`DevIDEPreviewBrowser.ExternalBackend`, which keeps browser crashes outside the
BEAM VM. If a native CEF backend becomes worth pursuing, keep this boundary
narrow and implement only the functions sketched in `src/lib.rs`.

