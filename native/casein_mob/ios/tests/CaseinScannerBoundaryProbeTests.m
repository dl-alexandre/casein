#import <Foundation/Foundation.h>

#define CASEIN_SCANNER_BOUNDARY_PROBE_TESTING 1
#import "../CaseinScannerBoundaryProbe.m"

static NSUInteger sAssertions = 0;

static void Require(BOOL condition, NSString *message) {
  sAssertions++;
  if (!condition) {
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(1);
  }
}

static void TestExactURL(void) {
  CaseinScannerBoundaryProbeResetForTesting();
  Require(CaseinScannerBoundaryProbeURLMatches(
              [NSURL URLWithString:@"casein://diagnostic/scanner-boundary"]),
          @"exact app-scoped diagnostic URL is accepted");

  NSArray<NSString *> *rejected = @[
    @"casein://pair/scanner-boundary",
    @"casein://diagnostic/scanner-boundary/extra",
    @"casein://diagnostic/%73canner-boundary",
    @"casein://diagnostic/scanner-boundary?code=one",
    @"casein://diagnostic/scanner-boundary#fragment",
    @"casein://user@diagnostic/scanner-boundary",
    @"casein://diagnostic:443/scanner-boundary",
    @"https://diagnostic/scanner-boundary"
  ];

  for (NSString *value in rejected) {
    Require(!CaseinScannerBoundaryProbeURLMatches([NSURL URLWithString:value]),
            @"nearby URL is rejected");
    Require(!CaseinScannerBoundaryProbeHandleURL([NSURL URLWithString:value]),
            @"nearby URL never enters the handler");
  }
  Require(!CaseinScannerBoundaryProbeURLMatches(nil), @"nil URL is rejected");
  Require(!CaseinScannerBoundaryProbeHandleURL(nil),
          @"nil URL never enters the handler");
}

static void TestDevelopmentSignatureGate(void) {
  CaseinScannerBoundaryProbeResetForTesting();
  sCaseinScannerBoundaryTestingDevelopmentSigned = NO;

  Require(!CaseinScannerBoundaryProbeHandleURL(
              [NSURL URLWithString:@"casein://diagnostic/scanner-boundary"]),
          @"non-development signature is rejected");
  Require(!sCaseinScannerBoundaryPending,
          @"rejected signature does not retain a pending signal");
  Require(!sCaseinScannerBoundaryRetryScheduled,
          @"rejected signature does not schedule work");
}

static void TestColdReceiverDrainsExactlyOnce(void) {
  CaseinScannerBoundaryProbeResetForTesting();
  NSURL *url = [NSURL URLWithString:@"casein://diagnostic/scanner-boundary"];

  Require(CaseinScannerBoundaryProbeHandleURL(url),
          @"cold diagnostic URL is consumed");
  Require(sCaseinScannerBoundaryPending,
          @"cold diagnostic signal remains pending");
  Require(sCaseinScannerBoundaryRetryScheduled,
          @"cold diagnostic schedules one attempt");
  Require(sCaseinScannerBoundaryTestingSendAttempts == 0,
          @"cold callback never enters the NIF boundary synchronously");

  CaseinScannerBoundaryProbeRunScheduledAttemptForTesting();
  Require(sCaseinScannerBoundaryTestingSendAttempts == 1,
          @"missing receiver performs one bounded attempt");
  Require(sCaseinScannerBoundaryPending,
          @"missing receiver preserves the signal");
  Require(sCaseinScannerBoundaryRetryScheduled,
          @"missing receiver schedules the next bounded attempt");

  sCaseinScannerBoundaryTestingReceiverReady = YES;
  CaseinScannerBoundaryProbeRunScheduledAttemptForTesting();
  Require(sCaseinScannerBoundaryTestingDeliveries == 1,
          @"late receiver gets exactly one delivery");
  Require(!sCaseinScannerBoundaryPending,
          @"successful delivery clears pending state");
  Require(!sCaseinScannerBoundaryRetryScheduled,
          @"successful delivery stops retries");

  CaseinScannerBoundaryProbeRunScheduledAttemptForTesting();
  Require(sCaseinScannerBoundaryTestingDeliveries == 1,
          @"drained signal cannot replay");
}

static void TestDuplicateColdSignalCoalesces(void) {
  CaseinScannerBoundaryProbeResetForTesting();
  NSURL *url = [NSURL URLWithString:@"casein://diagnostic/scanner-boundary"];

  Require(CaseinScannerBoundaryProbeHandleURL(url), @"first URL is consumed");
  Require(CaseinScannerBoundaryProbeHandleURL(url), @"second URL is consumed");
  Require(sCaseinScannerBoundaryRetryScheduled,
          @"duplicate URL shares the pending attempt chain");

  CaseinScannerBoundaryProbeRunScheduledAttemptForTesting();
  sCaseinScannerBoundaryTestingReceiverReady = YES;
  CaseinScannerBoundaryProbeRunScheduledAttemptForTesting();

  Require(sCaseinScannerBoundaryTestingSendAttempts == 2,
          @"coalesced signal uses one missing and one successful attempt");
  Require(sCaseinScannerBoundaryTestingDeliveries == 1,
          @"duplicate cold URLs cannot double-deliver");
}

static void TestMissingReceiverExpiresBoundedly(void) {
  CaseinScannerBoundaryProbeResetForTesting();
  Require(CaseinScannerBoundaryProbeHandleURL(
              [NSURL URLWithString:@"casein://diagnostic/scanner-boundary"]),
          @"diagnostic URL is consumed before bounded expiry");

  for (NSUInteger attempt = 0;
       attempt < CASEIN_SCANNER_BOUNDARY_PROBE_MAX_ATTEMPTS; attempt++) {
    CaseinScannerBoundaryProbeRunScheduledAttemptForTesting();
  }

  Require(sCaseinScannerBoundaryTestingSendAttempts ==
              CASEIN_SCANNER_BOUNDARY_PROBE_MAX_ATTEMPTS,
          @"retry count is strictly bounded");
  Require(!sCaseinScannerBoundaryPending,
          @"expired signal is discarded without mutation");
  Require(!sCaseinScannerBoundaryRetryScheduled,
          @"expired signal leaves no scheduled work");
  Require(sCaseinScannerBoundaryTestingDeliveries == 0,
          @"missing receiver never fabricates a delivery");
}

static void TestGoldenVectorIsPublicAndBounded(void) {
  NSString *value = [NSString stringWithUTF8String:kCaseinScannerBoundaryGoldenURI];
  Require([value hasPrefix:@"casein://pair/"], @"fixture has compact prefix");
  Require([value lengthOfBytesUsingEncoding:NSUTF8StringEncoding] == 146,
          @"fixture byte count remains exact");
  Require([value containsString:@"token"] == NO,
          @"fixture never carries a token field");
}

int main(void) {
  @autoreleasepool {
    TestExactURL();
    TestDevelopmentSignatureGate();
    TestColdReceiverDrainsExactlyOnce();
    TestDuplicateColdSignalCoalesces();
    TestMissingReceiverExpiresBoundedly();
    TestGoldenVectorIsPublicAndBounded();
    printf("CaseinScannerBoundaryProbeTests: %lu assertions passed\n",
           (unsigned long)sAssertions);
  }
  return 0;
}
