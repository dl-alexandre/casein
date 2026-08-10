%% mob_scanner_nif — Erlang NIF module for the QR/barcode scanner tier-1 plugin.
%%
%% iOS: priv/native/ios/mob_scanner_nif.m (Objective-C: AVCaptureMetadataOutput
%% in a full-screen view controller). Android: priv/native/jni/mob_scanner_nif.zig
%% bridging to the plugin-owned io.mob.scanner.MobScannerActivity (CameraX +
%% ML Kit BarcodeScanning) via the io.mob.scanner.MobScannerBridge Kotlin
%% bridge. Both register this module via ERL_NIF_INIT and are statically
%% linked into the host binary on device. On a host dev build neither is
%% linked, so on_load tolerates the failure and the NIF falls back to
%% nif_error until the native merge links one.
-module(mob_scanner_nif).
-export([scanner_scan/1]).
-on_load(init/0).

init() ->
    case erlang:load_nif("mob_scanner_nif", 0) of
        ok -> ok;
        {error, _} -> ok
    end.

scanner_scan(_FormatsJson) ->
    erlang:nif_error(nif_not_loaded).
