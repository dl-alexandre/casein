#ifndef CASEIN_SCANNER_BOUNDARY_PROBE_H
#define CASEIN_SCANNER_BOUNDARY_PROBE_H

#import <Foundation/Foundation.h>

// Handles only the exact development-signed, app-scoped diagnostic URL. The
// probe sends one checked-in public fixture to a dedicated parser-only BEAM
// process; it never opens the scanner or enters the pairing path.
FOUNDATION_EXPORT BOOL CaseinScannerBoundaryProbeHandleURL(NSURL *url);

#endif
