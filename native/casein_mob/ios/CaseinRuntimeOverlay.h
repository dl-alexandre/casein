#ifndef CASEIN_RUNTIME_OVERLAY_H
#define CASEIN_RUNTIME_OVERLAY_H

#import <Foundation/Foundation.h>

// These are the only externally visible outcomes.  Deliberately do not expose
// paths, hashes, manifest contents, or filesystem errors to the app surface.
typedef NS_ENUM(NSUInteger, CaseinRuntimeOverlayState) {
  CaseinRuntimeOverlayStateSignedBundle = 0,
  CaseinRuntimeOverlayStateVerifiedOverlay = 1,
  CaseinRuntimeOverlayStateSignedBundleAfterQuarantine = 2,
  CaseinRuntimeOverlayStateBlocked = 3,
};

// Validate Documents/otp/<app_module> against the signed bundle's
// _CodeSignature/CodeResources files2/hash2 seal.  A rejected overlay is moved
// atomically to a sibling quarantine entry so Mob falls back to the signed
// bundle.  Blocked means the caller must not start the BEAM.
FOUNDATION_EXPORT CaseinRuntimeOverlayState
CaseinRuntimeOverlayPrepare(const char *app_module);

FOUNDATION_EXPORT const char *
CaseinRuntimeOverlayStateName(CaseinRuntimeOverlayState state);

#endif
