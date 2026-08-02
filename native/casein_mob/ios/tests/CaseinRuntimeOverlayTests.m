#import <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

// Include the implementation so the harness can exercise the path-injected
// static entry point without adding a production testing surface.
#import "../CaseinRuntimeOverlay.m"

static NSUInteger sAssertions = 0;

static void Require(BOOL condition, NSString *message) {
  sAssertions++;
  if (!condition) {
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(1);
  }
}

static NSData *Digest(NSData *data) {
  unsigned char bytes[CC_SHA256_DIGEST_LENGTH];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  CC_SHA256(data.bytes, (CC_LONG)data.length, bytes);
#pragma clang diagnostic pop
  return [NSData dataWithBytes:bytes length:sizeof(bytes)];
}

static NSString *NewRoot(void) {
  NSString *root = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"casein-overlay-test-%@",
                                     NSUUID.UUID.UUIDString]];
  NSError *error = nil;
  Require([[NSFileManager defaultManager] createDirectoryAtPath:root
                                    withIntermediateDirectories:YES
                                                     attributes:nil
                                                          error:&error],
          [NSString stringWithFormat:@"create root: %@", error]);
  return root;
}

static NSString *MakeDirectory(NSString *base, NSString *relative) {
  NSString *path = [base stringByAppendingPathComponent:relative];
  NSError *error = nil;
  Require(
      [[NSFileManager defaultManager] createDirectoryAtPath:path
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:&error],
      [NSString stringWithFormat:@"create directory %@: %@", relative, error]);
  return path;
}

static void WriteFile(NSString *base, NSString *relative, NSData *data) {
  NSString *path = [base stringByAppendingPathComponent:relative];
  MakeDirectory(base, [relative stringByDeletingLastPathComponent]);
  Require([data writeToFile:path atomically:NO],
          [NSString stringWithFormat:@"write %@", relative]);
}

static void WriteManifest(NSString *bundle,
                          NSDictionary<NSString *, id> *files2) {
  NSString *signature = MakeDirectory(bundle, @"_CodeSignature");
  NSError *error = nil;
  NSData *plist = [NSPropertyListSerialization
      dataWithPropertyList:@{@"files2" : files2}
                    format:NSPropertyListBinaryFormat_v1_0
                   options:0
                     error:&error];
  Require(plist != nil && error == nil,
          [NSString stringWithFormat:@"encode manifest: %@", error]);
  Require([plist
              writeToFile:[signature
                              stringByAppendingPathComponent:@"CodeResources"]
               atomically:NO],
          @"write manifest");
}

static NSDictionary<NSString *, id> *
Seal(NSDictionary<NSString *, NSData *> *files) {
  NSMutableDictionary<NSString *, id> *sealed =
      [NSMutableDictionary dictionary];
  for (NSString *relative in files) {
    NSString *key = [@"otp/casein_mob" stringByAppendingPathComponent:relative];
    sealed[key] = @{@"hash2" : Digest(files[relative])};
  }
  // An unrelated signed resource must not become part of the overlay set.
  sealed[@"Info.plist"] = @{@"hash2" : Digest([NSData data])};
  return sealed;
}

static NSDictionary<NSString *, NSString *> *
Setup(NSString *root, NSDictionary<NSString *, NSData *> *files) {
  NSString *bundle = MakeDirectory(root, @"Casein.app");
  NSString *documents = MakeDirectory(root, @"Documents");
  NSString *overlay = MakeDirectory(documents, @"otp/casein_mob");
  for (NSString *relative in files) {
    WriteFile(overlay, relative, files[relative]);
  }
  WriteManifest(bundle, Seal(files));
  return @{@"bundle" : bundle, @"documents" : documents, @"overlay" : overlay};
}

static NSArray<NSString *> *QuarantineEntries(NSString *documents) {
  NSString *otp = [documents stringByAppendingPathComponent:@"otp"];
  NSArray<NSString *> *entries =
      [[NSFileManager defaultManager] contentsOfDirectoryAtPath:otp error:nil]
          ?: @[];
  NSPredicate *predicate = [NSPredicate
      predicateWithBlock:^BOOL(NSString *value, NSDictionary *bindings) {
        (void)bindings;
        return [value hasPrefix:@".casein-quarantine-"];
      }];
  return [entries filteredArrayUsingPredicate:predicate];
}

static void Cleanup(NSString *root) {
  NSError *error = nil;
  Require([[NSFileManager defaultManager] removeItemAtPath:root error:&error],
          [NSString stringWithFormat:@"cleanup: %@", error]);
}

static void TestAbsentUsesBundle(void) {
  NSString *root = NewRoot();
  NSString *bundle = MakeDirectory(root, @"Casein.app");
  NSString *documents = MakeDirectory(root, @"Documents");
  Require(CaseinRuntimeOverlayPrepareAtPaths(bundle, documents, "casein_mob") ==
              CaseinRuntimeOverlayStateSignedBundle,
          @"absent overlay uses signed bundle");
  Cleanup(root);
}

static void TestExactOverlay(void) {
  NSString *root = NewRoot();
  NSDictionary *files = @{
    @"Elixir.CaseinMob.beam" :
        [@"beam-one" dataUsingEncoding:NSUTF8StringEncoding],
    @"priv/repo/migrations/001.exs" :
        [@"migration" dataUsingEncoding:NSUTF8StringEncoding]
  };
  NSDictionary *paths = Setup(root, files);
  Require(CaseinRuntimeOverlayPrepareAtPaths(
              paths[@"bundle"], paths[@"documents"], "casein_mob") ==
              CaseinRuntimeOverlayStateVerifiedOverlay,
          @"exact overlay verifies");
  Require([[NSFileManager defaultManager] fileExistsAtPath:paths[@"overlay"]],
          @"verified overlay remains selected");
  Require(QuarantineEntries(paths[@"documents"]).count == 0,
          @"verified overlay is not quarantined");
  Cleanup(root);
}

static void TestMutationQuarantines(void) {
  NSString *root = NewRoot();
  NSDictionary *files =
      @{@"app.beam" : [@"signed" dataUsingEncoding:NSUTF8StringEncoding]};
  NSDictionary *paths = Setup(root, files);
  WriteFile(paths[@"overlay"], @"app.beam",
            [@"mutated" dataUsingEncoding:NSUTF8StringEncoding]);
  Require(CaseinRuntimeOverlayPrepareAtPaths(
              paths[@"bundle"], paths[@"documents"], "casein_mob") ==
              CaseinRuntimeOverlayStateSignedBundleAfterQuarantine,
          @"mutated overlay quarantines");
  Require(![[NSFileManager defaultManager] fileExistsAtPath:paths[@"overlay"]],
          @"mutated selected path is gone");
  Require(QuarantineEntries(paths[@"documents"]).count == 1,
          @"mutated data is preserved in quarantine");
  Cleanup(root);
}

static void TestMissingExtraAndEmptyDirectory(void) {
  NSDictionary *files = @{
    @"one.beam" : [@"one" dataUsingEncoding:NSUTF8StringEncoding],
    @"nested/two.beam" : [@"two" dataUsingEncoding:NSUTF8StringEncoding]
  };

  NSString *missingRoot = NewRoot();
  NSDictionary *missing = Setup(missingRoot, files);
  Require([[NSFileManager defaultManager]
              removeItemAtPath:[missing[@"overlay"]
                                   stringByAppendingPathComponent:@"one.beam"]
                         error:nil],
          @"remove fixture file");
  Require(CaseinRuntimeOverlayPrepareAtPaths(
              missing[@"bundle"], missing[@"documents"], "casein_mob") ==
              CaseinRuntimeOverlayStateSignedBundleAfterQuarantine,
          @"missing file rejects exact set");
  Cleanup(missingRoot);

  NSString *extraRoot = NewRoot();
  NSDictionary *extra = Setup(extraRoot, files);
  WriteFile(extra[@"overlay"], @"extra.beam", [NSData data]);
  Require(CaseinRuntimeOverlayPrepareAtPaths(
              extra[@"bundle"], extra[@"documents"], "casein_mob") ==
              CaseinRuntimeOverlayStateSignedBundleAfterQuarantine,
          @"extra file rejects exact set");
  Cleanup(extraRoot);

  NSString *directoryRoot = NewRoot();
  NSDictionary *directory = Setup(directoryRoot, files);
  MakeDirectory(directory[@"overlay"], @"unexpected-empty");
  Require(CaseinRuntimeOverlayPrepareAtPaths(
              directory[@"bundle"], directory[@"documents"], "casein_mob") ==
              CaseinRuntimeOverlayStateSignedBundleAfterQuarantine,
          @"extra directory rejects exact set");
  Cleanup(directoryRoot);
}

static void TestSymlinkAndNonDirectory(void) {
  NSString *root = NewRoot();
  NSDictionary *files =
      @{@"link.beam" : [@"target" dataUsingEncoding:NSUTF8StringEncoding]};
  NSDictionary *paths = Setup(root, files);
  Require([[NSFileManager defaultManager]
              removeItemAtPath:[paths[@"overlay"]
                                   stringByAppendingPathComponent:@"link.beam"]
                         error:nil],
          @"remove link fixture");
  NSString *external = [root stringByAppendingPathComponent:@"external"];
  Require([files[@"link.beam"] writeToFile:external atomically:NO],
          @"write external target");
  NSError *linkError = nil;
  Require(
      [[NSFileManager defaultManager]
          createSymbolicLinkAtPath:
              [paths[@"overlay"] stringByAppendingPathComponent:@"link.beam"]
               withDestinationPath:external
                             error:&linkError],
      [NSString stringWithFormat:@"create symlink: %@", linkError]);
  Require(CaseinRuntimeOverlayPrepareAtPaths(
              paths[@"bundle"], paths[@"documents"], "casein_mob") ==
              CaseinRuntimeOverlayStateSignedBundleAfterQuarantine,
          @"symlink overlay entry rejects");
  Cleanup(root);

  NSString *fileRoot = NewRoot();
  NSString *bundle = MakeDirectory(fileRoot, @"Casein.app");
  NSString *documents = MakeDirectory(fileRoot, @"Documents");
  MakeDirectory(documents, @"otp");
  WriteFile(documents, @"otp/casein_mob", [NSData data]);
  WriteManifest(bundle, Seal(@{@"app.beam" : [NSData data]}));
  Require(CaseinRuntimeOverlayPrepareAtPaths(bundle, documents, "casein_mob") ==
              CaseinRuntimeOverlayStateSignedBundleAfterQuarantine,
          @"non-directory candidate quarantines");
  Cleanup(fileRoot);
}

static void TestSignedSymlinkRuleQuarantines(void) {
  NSString *root = NewRoot();
  NSDictionary *paths = Setup(
      root, @{@"app.beam" : [@"beam" dataUsingEncoding:NSUTF8StringEncoding]});
  WriteManifest(
      paths[@"bundle"], @{
        @"otp/casein_mob/app.beam" : @{
          @"hash2" : Digest([@"beam" dataUsingEncoding:NSUTF8StringEncoding])
        },
        @"otp/casein_mob/priv/lib/runtime.dylib" :
            @{@"symlink" : @"runtime.1.dylib"}
      });
  Require(CaseinRuntimeOverlayPrepareAtPaths(
              paths[@"bundle"], paths[@"documents"], "casein_mob") ==
              CaseinRuntimeOverlayStateSignedBundleAfterQuarantine,
          @"sealed symlink rule rejects overlay but preserves bundle fallback");
  Require(QuarantineEntries(paths[@"documents"]).count == 1,
          @"sealed symlink rejection quarantines candidate");
  Cleanup(root);
}

static void TestManifestFailuresBlock(void) {
  NSString *traversalRoot = NewRoot();
  NSDictionary *traversal =
      Setup(traversalRoot,
            @{@"app.beam" : [@"beam" dataUsingEncoding:NSUTF8StringEncoding]});
  WriteManifest(
      traversal[@"bundle"],
      @{@"otp/casein_mob/../escape" : @{@"hash2" : Digest([NSData data])}});
  Require(CaseinRuntimeOverlayPrepareAtPaths(
              traversal[@"bundle"], traversal[@"documents"], "casein_mob") ==
              CaseinRuntimeOverlayStateBlocked,
          @"manifest traversal blocks startup");
  Require(
      [[NSFileManager defaultManager] fileExistsAtPath:traversal[@"overlay"]],
      @"unverifiable overlay is not destructively changed");
  Cleanup(traversalRoot);

  NSString *hashRoot = NewRoot();
  NSDictionary *hash =
      Setup(hashRoot,
            @{@"app.beam" : [@"beam" dataUsingEncoding:NSUTF8StringEncoding]});
  WriteManifest(
      hash[@"bundle"],
      @{@"otp/casein_mob/app.beam" : @{@"hash2" : [NSData data]}});
  Require(CaseinRuntimeOverlayPrepareAtPaths(
              hash[@"bundle"], hash[@"documents"], "casein_mob") ==
              CaseinRuntimeOverlayStateBlocked,
          @"malformed hash2 blocks startup");
  Cleanup(hashRoot);

  NSString *sizeRoot = NewRoot();
  NSDictionary *size =
      Setup(sizeRoot,
            @{@"app.beam" : [@"beam" dataUsingEncoding:NSUTF8StringEncoding]});
  NSString *resources = [size[@"bundle"]
      stringByAppendingPathComponent:@"_CodeSignature/CodeResources"];
  int manifestFD = open(resources.fileSystemRepresentation, O_WRONLY | O_TRUNC);
  Require(manifestFD >= 0, @"open manifest fixture");
  Require(ftruncate(manifestFD, (off_t)kCaseinManifestMaxBytes + 1) == 0,
          @"make oversized manifest fixture");
  close(manifestFD);
  Require(CaseinRuntimeOverlayPrepareAtPaths(
              size[@"bundle"], size[@"documents"], "casein_mob") ==
              CaseinRuntimeOverlayStateBlocked,
          @"oversized manifest blocks startup");
  Cleanup(sizeRoot);
}

static void TestOversizedOverlayQuarantines(void) {
  NSString *root = NewRoot();
  NSDictionary *paths = Setup(root, @{@"large.beam" : [NSData data]});
  NSString *large =
      [paths[@"overlay"] stringByAppendingPathComponent:@"large.beam"];
  int fd = open(large.fileSystemRepresentation, O_WRONLY | O_TRUNC);
  Require(fd >= 0, @"open large fixture");
  Require(ftruncate(fd, (off_t)kCaseinOverlayFileMaxBytes + 1) == 0,
          @"make sparse oversized overlay fixture");
  close(fd);
  Require(CaseinRuntimeOverlayPrepareAtPaths(
              paths[@"bundle"], paths[@"documents"], "casein_mob") ==
              CaseinRuntimeOverlayStateSignedBundleAfterQuarantine,
          @"oversized overlay quarantines");
  Cleanup(root);
}

static void TestQuarantineFailureBlocks(void) {
  NSString *root = NewRoot();
  NSDictionary *paths = Setup(
      root,
      @{@"app.beam" : [@"signed" dataUsingEncoding:NSUTF8StringEncoding]});
  WriteFile(paths[@"overlay"], @"app.beam",
            [@"mutated" dataUsingEncoding:NSUTF8StringEncoding]);
  NSString *otp = [paths[@"documents"] stringByAppendingPathComponent:@"otp"];
  Require(chmod(otp.fileSystemRepresentation, 0500) == 0,
          @"lock quarantine parent");
  CaseinRuntimeOverlayState state = CaseinRuntimeOverlayPrepareAtPaths(
      paths[@"bundle"], paths[@"documents"], "casein_mob");
  Require(chmod(otp.fileSystemRepresentation, 0700) == 0,
          @"restore quarantine parent");
  Require(state == CaseinRuntimeOverlayStateBlocked,
          @"failed quarantine blocks startup");
  Require([[NSFileManager defaultManager] fileExistsAtPath:paths[@"overlay"]],
          @"failed quarantine preserves candidate");
  Cleanup(root);
}

static void TestInvalidModuleBlocks(void) {
  NSString *root = NewRoot();
  NSString *bundle = MakeDirectory(root, @"Casein.app");
  NSString *documents = MakeDirectory(root, @"Documents");
  Require(
      CaseinRuntimeOverlayPrepareAtPaths(bundle, documents, "../casein_mob") ==
          CaseinRuntimeOverlayStateBlocked,
      @"invalid module blocks before path construction");
  Cleanup(root);
}

static void TestBoundedStateNames(void) {
  Require(strcmp(CaseinRuntimeOverlayStateName(
                     CaseinRuntimeOverlayStateSignedBundle),
                 "signed_bundle") == 0,
          @"bundle state is bounded");
  Require(strcmp(CaseinRuntimeOverlayStateName(
                     CaseinRuntimeOverlayStateVerifiedOverlay),
                 "verified_overlay") == 0,
          @"verified state is bounded");
  Require(strcmp(CaseinRuntimeOverlayStateName(
                     CaseinRuntimeOverlayStateSignedBundleAfterQuarantine),
                 "signed_bundle_after_quarantine") == 0,
          @"quarantine state is bounded");
  Require(
      strcmp(CaseinRuntimeOverlayStateName(CaseinRuntimeOverlayStateBlocked),
             "blocked") == 0,
      @"blocked state is bounded");
}

int main(void) {
  @autoreleasepool {
    TestAbsentUsesBundle();
    TestExactOverlay();
    TestMutationQuarantines();
    TestMissingExtraAndEmptyDirectory();
    TestSymlinkAndNonDirectory();
    TestSignedSymlinkRuleQuarantines();
    TestManifestFailuresBlock();
    TestOversizedOverlayQuarantines();
    TestQuarantineFailureBlocks();
    TestInvalidModuleBlocks();
    TestBoundedStateNames();
    printf("CaseinRuntimeOverlayTests: %lu assertions passed\n",
           (unsigned long)sAssertions);
  }
  return 0;
}
