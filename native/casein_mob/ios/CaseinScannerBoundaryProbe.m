#import "CaseinScannerBoundaryProbe.h"

#import <Foundation/Foundation.h>

#define CASEIN_SCANNER_BOUNDARY_PROBE_MAX_ATTEMPTS 40
#define CASEIN_SCANNER_BOUNDARY_PROBE_RETRY_NSEC (250 * NSEC_PER_MSEC)

#ifndef CASEIN_SCANNER_BOUNDARY_PROBE_TESTING
#import <Security/SecBase.h>
#include <erl_nif.h>
#include <string.h>

// SecTask is exported by the iOS Security framework but its declaration is
// absent from the iPhoneOS SDK headers. Keep the minimal declarations local so
// this diagnostic can prove at runtime that get-task-allow is present.
typedef struct CF_BRIDGED_TYPE(id) __SecTask *SecTaskRef;
extern SecTaskRef _Nullable SecTaskCreateFromSelf(
    CFAllocatorRef _Nullable allocator);
extern CFTypeRef _Nullable SecTaskCopyValueForEntitlement(
    SecTaskRef task, CFStringRef entitlement,
    CFErrorRef _Nullable *_Nullable error);
#endif

// Public, non-secret structural fixture shared with
// test/fixtures/compact_pairing_vectors.json. It is not a server-issued
// credential: the handle is the fixed all-"A" fixture.
static const char *kCaseinScannerBoundaryGoldenURI =
    "casein://pair/eyJoIjoiQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQSIsIm8iOiJodHRwczovL2Nhc2Vpbi5kZXZib3gubWlsY2dyb3VwLmNvbSIsInYiOjF9";

static BOOL sCaseinScannerBoundaryPending = NO;
static BOOL sCaseinScannerBoundaryRetryScheduled = NO;
static NSUInteger sCaseinScannerBoundaryAttempts = 0;

static BOOL CaseinScannerBoundaryProbeURLMatches(NSURL *url) {
  if (![url isKindOfClass:[NSURL class]]) {
    return NO;
  }

  NSURLComponents *components =
      [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];

  return components != nil && [components.scheme isEqualToString:@"casein"] &&
         [components.host isEqualToString:@"diagnostic"] &&
         [components.percentEncodedPath isEqualToString:@"/scanner-boundary"] &&
         components.percentEncodedQuery == nil && components.fragment == nil &&
         components.user == nil && components.password == nil &&
         components.port == nil;
}

#ifdef CASEIN_SCANNER_BOUNDARY_PROBE_TESTING
static BOOL sCaseinScannerBoundaryTestingDevelopmentSigned = YES;
static BOOL sCaseinScannerBoundaryTestingReceiverReady = NO;
static NSUInteger sCaseinScannerBoundaryTestingSendAttempts = 0;
static NSUInteger sCaseinScannerBoundaryTestingDeliveries = 0;

static BOOL CaseinScannerBoundaryProbeDevelopmentSigned(void) {
  return sCaseinScannerBoundaryTestingDevelopmentSigned;
}

static BOOL CaseinScannerBoundaryProbeSendGolden(void) {
  sCaseinScannerBoundaryTestingSendAttempts++;
  if (!sCaseinScannerBoundaryTestingReceiverReady) {
    return NO;
  }

  sCaseinScannerBoundaryTestingDeliveries++;
  return YES;
}
#else
static BOOL CaseinScannerBoundaryProbeDevelopmentSigned(void) {
  SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
  if (!task) {
    return NO;
  }

  CFTypeRef value =
      SecTaskCopyValueForEntitlement(task, CFSTR("get-task-allow"), NULL);
  BOOL allowed = value != NULL && CFGetTypeID(value) == CFBooleanGetTypeID() &&
                 CFBooleanGetValue((CFBooleanRef)value);

  if (value) {
    CFRelease(value);
  }
  CFRelease(task);
  return allowed;
}

static BOOL CaseinScannerBoundaryProbeSendGolden(void) {
  ErlNifEnv *env = enif_alloc_env();
  if (!env) {
    return NO;
  }

  ErlNifPid receiver;
  ERL_NIF_TERM receiverName =
      enif_make_atom(env, "casein_scanner_boundary_probe");
  if (!enif_whereis_pid(env, receiverName, &receiver)) {
    enif_free_env(env);
    return NO;
  }

  const char *value = kCaseinScannerBoundaryGoldenURI;
  size_t valueLength = strlen(value);
  ErlNifBinary valueBinary;
  if (!enif_alloc_binary(valueLength, &valueBinary)) {
    enif_free_env(env);
    return NO;
  }
  memcpy(valueBinary.data, value, valueLength);

  // This intentionally matches mob_scanner's iOS result-construction
  // boundary: {:scan, :result, %{type: :qr, value: binary}}.
  ERL_NIF_TERM keys[2] = {enif_make_atom(env, "type"),
                          enif_make_atom(env, "value")};
  ERL_NIF_TERM values[2] = {enif_make_atom(env, "qr"),
                            enif_make_binary(env, &valueBinary)};
  ERL_NIF_TERM resultMap;
  if (!enif_make_map_from_arrays(env, keys, values, 2, &resultMap)) {
    enif_free_env(env);
    return NO;
  }

  ERL_NIF_TERM message =
      enif_make_tuple3(env, enif_make_atom(env, "scan"),
                       enif_make_atom(env, "result"), resultMap);
  BOOL sent = enif_send(NULL, &receiver, env, message) == 1;
  enif_free_env(env);
  return sent;
}
#endif

static void CaseinScannerBoundaryProbeAttemptPending(void);

#ifdef CASEIN_SCANNER_BOUNDARY_PROBE_TESTING
static void CaseinScannerBoundaryProbeScheduleAttempt(void) {
  sCaseinScannerBoundaryRetryScheduled = YES;
}
#else
static dispatch_queue_t CaseinScannerBoundaryProbeQueue(void) {
  static dispatch_queue_t queue;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    queue = dispatch_queue_create("com.casein.scanner-boundary-probe",
                                  DISPATCH_QUEUE_SERIAL);
  });
  return queue;
}

static void CaseinScannerBoundaryProbeScheduleAttempt(void) {
  sCaseinScannerBoundaryRetryScheduled = YES;

  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                               CASEIN_SCANNER_BOUNDARY_PROBE_RETRY_NSEC),
                 CaseinScannerBoundaryProbeQueue(), ^{
                   sCaseinScannerBoundaryRetryScheduled = NO;
                   CaseinScannerBoundaryProbeAttemptPending();
                 });
}
#endif

static void CaseinScannerBoundaryProbeAttemptPending(void) {
  if (!sCaseinScannerBoundaryPending) {
    return;
  }

  if (CaseinScannerBoundaryProbeSendGolden()) {
    sCaseinScannerBoundaryPending = NO;
    sCaseinScannerBoundaryAttempts = 0;
    return;
  }

  sCaseinScannerBoundaryAttempts++;
  if (sCaseinScannerBoundaryAttempts >=
      CASEIN_SCANNER_BOUNDARY_PROBE_MAX_ATTEMPTS) {
    sCaseinScannerBoundaryPending = NO;
    return;
  }

  CaseinScannerBoundaryProbeScheduleAttempt();
}

static void CaseinScannerBoundaryProbeMarkPending(void) {
  if (!sCaseinScannerBoundaryPending) {
    sCaseinScannerBoundaryPending = YES;
    sCaseinScannerBoundaryAttempts = 0;
  }

  // Repeated opens coalesce while the one bounded signal is pending. There is
  // never more than one scheduled attempt chain, so a late receiver can get
  // exactly one scanner-shaped message.
  if (!sCaseinScannerBoundaryRetryScheduled) {
    CaseinScannerBoundaryProbeScheduleAttempt();
  }
}

#ifdef CASEIN_SCANNER_BOUNDARY_PROBE_TESTING
static void CaseinScannerBoundaryProbeResetForTesting(void) {
  sCaseinScannerBoundaryPending = NO;
  sCaseinScannerBoundaryRetryScheduled = NO;
  sCaseinScannerBoundaryAttempts = 0;
  sCaseinScannerBoundaryTestingDevelopmentSigned = YES;
  sCaseinScannerBoundaryTestingReceiverReady = NO;
  sCaseinScannerBoundaryTestingSendAttempts = 0;
  sCaseinScannerBoundaryTestingDeliveries = 0;
}

static void CaseinScannerBoundaryProbeRunScheduledAttemptForTesting(void) {
  if (!sCaseinScannerBoundaryRetryScheduled) {
    return;
  }

  sCaseinScannerBoundaryRetryScheduled = NO;
  CaseinScannerBoundaryProbeAttemptPending();
}
#endif

BOOL CaseinScannerBoundaryProbeHandleURL(NSURL *url) {
  if (!CaseinScannerBoundaryProbeURLMatches(url) ||
      !CaseinScannerBoundaryProbeDevelopmentSigned()) {
    return NO;
  }

  // Never call the NIF boundary from the cold-launch callback. The scene is
  // connected after the BEAM thread is created but before its named receiver
  // is necessarily registered, so retain one bounded, non-secret signal and
  // drain it once registration becomes visible.
#ifdef CASEIN_SCANNER_BOUNDARY_PROBE_TESTING
  CaseinScannerBoundaryProbeMarkPending();
#else
  dispatch_async(CaseinScannerBoundaryProbeQueue(), ^{
    CaseinScannerBoundaryProbeMarkPending();
  });
#endif
  return YES;
}
