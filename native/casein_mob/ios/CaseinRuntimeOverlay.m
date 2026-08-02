#import "CaseinRuntimeOverlay.h"

#import <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// The overlay contains app BEAMs and priv assets, not the full OTP runtime.
// These bounds are intentionally generous for Casein while making every parse,
// traversal, and digest operation finite.
static const unsigned long long kCaseinManifestMaxBytes =
    32ULL * 1024ULL * 1024ULL;
static const unsigned long long kCaseinOverlayFileMaxBytes =
    64ULL * 1024ULL * 1024ULL;
static const unsigned long long kCaseinOverlayTotalMaxBytes =
    512ULL * 1024ULL * 1024ULL;
static const NSUInteger kCaseinOverlayMaxEntries = 32768;
static const NSUInteger kCaseinOverlayMaxPathBytes = 1024;
static const NSUInteger kCaseinOverlayMaxDepth = 32;

typedef NS_ENUM(NSUInteger, CaseinOverlayValidation) {
  CaseinOverlayValidationVerified = 0,
  CaseinOverlayValidationRejected = 1,
  CaseinOverlayValidationUnavailable = 2,
};

static BOOL CaseinValidAppModule(const char *appModule) {
  if (!appModule) {
    return NO;
  }

  size_t length = strnlen(appModule, 129);
  if (length == 0 || length > 128) {
    return NO;
  }

  for (size_t index = 0; index < length; index++) {
    unsigned char value = (unsigned char)appModule[index];
    BOOL allowed =
        (value >= 'a' && value <= 'z') || (value >= 'A' && value <= 'Z') ||
        (value >= '0' && value <= '9') || value == '_' || value == '-';
    if (!allowed) {
      return NO;
    }
  }

  return YES;
}

static BOOL CaseinValidRelativePath(NSString *path) {
  if (![path isKindOfClass:[NSString class]] || path.length == 0 ||
      [path hasPrefix:@"/"] || [path hasSuffix:@"/"] ||
      [path containsString:@"//"] || [path containsString:@"\\"]) {
    return NO;
  }

  NSData *utf8 = [path dataUsingEncoding:NSUTF8StringEncoding];
  if (!utf8 || utf8.length == 0 || utf8.length > kCaseinOverlayMaxPathBytes) {
    return NO;
  }

  NSArray<NSString *> *components = [path componentsSeparatedByString:@"/"];
  if (components.count == 0 || components.count > kCaseinOverlayMaxDepth) {
    return NO;
  }

  NSCharacterSet *controls = [NSCharacterSet controlCharacterSet];
  for (NSString *component in components) {
    if (component.length == 0 || [component isEqualToString:@"."] ||
        [component isEqualToString:@".."] ||
        [component rangeOfCharacterFromSet:controls].location != NSNotFound) {
      return NO;
    }
  }

  return YES;
}

static BOOL CaseinLstat(NSString *path, struct stat *info, BOOL *missing) {
  if (missing) {
    *missing = NO;
  }

  if (lstat(path.fileSystemRepresentation, info) == 0) {
    return YES;
  }

  if (missing && errno == ENOENT) {
    *missing = YES;
  }
  return NO;
}

static BOOL CaseinSafeDirectory(NSString *path) {
  struct stat info;
  BOOL missing = NO;
  return CaseinLstat(path, &info, &missing) && !missing &&
         S_ISDIR(info.st_mode) && !S_ISLNK(info.st_mode);
}

static NSDictionary<NSString *, NSData *> *
CaseinExpectedHashes(NSString *bundlePath, NSString *appModule,
                     BOOL *containsSealedSymlink) {
  if (containsSealedSymlink) {
    *containsSealedSymlink = NO;
  }

  NSString *resourcesPath = [bundlePath
      stringByAppendingPathComponent:@"_CodeSignature/CodeResources"];

  struct stat info;
  BOOL missing = NO;
  if (!CaseinLstat(resourcesPath, &info, &missing) || missing ||
      !S_ISREG(info.st_mode) || S_ISLNK(info.st_mode) || info.st_size <= 0 ||
      (unsigned long long)info.st_size > kCaseinManifestMaxBytes) {
    return nil;
  }

  NSError *readError = nil;
  NSData *data = [NSData dataWithContentsOfFile:resourcesPath
                                        options:0
                                          error:&readError];
  if (readError || !data || data.length != (NSUInteger)info.st_size) {
    return nil;
  }

  NSError *plistError = nil;
  id root =
      [NSPropertyListSerialization propertyListWithData:data
                                                options:NSPropertyListImmutable
                                                 format:nil
                                                  error:&plistError];
  if (plistError || ![root isKindOfClass:[NSDictionary class]]) {
    return nil;
  }

  id filesValue = ((NSDictionary *)root)[@"files2"];
  if (![filesValue isKindOfClass:[NSDictionary class]] ||
      [(NSDictionary *)filesValue count] > kCaseinOverlayMaxEntries) {
    return nil;
  }

  NSString *prefix = [NSString stringWithFormat:@"otp/%@/", appModule];
  NSMutableDictionary<NSString *, NSData *> *expected =
      [NSMutableDictionary dictionary];

  for (id keyValue in (NSDictionary *)filesValue) {
    if (![keyValue isKindOfClass:[NSString class]]) {
      return nil;
    }

    NSString *key = keyValue;
    if (![key hasPrefix:prefix]) {
      continue;
    }

    NSString *relative = [key substringFromIndex:prefix.length];
    id entryValue = ((NSDictionary *)filesValue)[key];
    if (!CaseinValidRelativePath(relative) ||
        ![entryValue isKindOfClass:[NSDictionary class]]) {
      return nil;
    }

    NSDictionary *entry = entryValue;
    id hashValue = entry[@"hash2"];
    id symlinkValue = entry[@"symlink"];
    if ([hashValue isKindOfClass:[NSData class]] &&
        [(NSData *)hashValue length] == CC_SHA256_DIGEST_LENGTH &&
        symlinkValue == nil) {
      if (expected[relative] != nil ||
          expected.count >= kCaseinOverlayMaxEntries) {
        return nil;
      }
      expected[relative] = hashValue;
      continue;
    }

    // CodeResources represents a sealed symlink as {symlink = "target"}
    // without hash2. Casein never accepts a mutable overlay containing one,
    // but this is a valid signed manifest shape. Mark the whole overlay as
    // rejected (and therefore quarantined) rather than treating the signed
    // manifest as corrupt and blocking the signed-bundle fallback.
    if (hashValue == nil && [symlinkValue isKindOfClass:[NSString class]]) {
      NSData *target =
          [(NSString *)symlinkValue dataUsingEncoding:NSUTF8StringEncoding];
      if (!target || target.length == 0 ||
          target.length > kCaseinOverlayMaxPathBytes ||
          [(NSString *)symlinkValue
              rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]]
                  .location != NSNotFound) {
        return nil;
      }
      if (containsSealedSymlink) {
        *containsSealedSymlink = YES;
      }
      continue;
    }

    return nil;
  }

  return expected.count > 0 ? [expected copy] : nil;
}

static NSSet<NSString *> *CaseinExpectedDirectories(NSSet<NSString *> *files) {
  NSMutableSet<NSString *> *directories = [NSMutableSet set];
  for (NSString *file in files) {
    NSString *parent = [file stringByDeletingLastPathComponent];
    while (parent.length > 0 && ![parent isEqualToString:@"."]) {
      [directories addObject:parent];
      NSString *next = [parent stringByDeletingLastPathComponent];
      if ([next isEqualToString:parent]) {
        return nil;
      }
      parent = next;
    }
  }
  return [directories copy];
}

static NSData *CaseinHashRegularFile(NSString *path,
                                     unsigned long long *byteCount) {
  int fd =
      open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (fd < 0) {
    return nil;
  }

  struct stat info;
  if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size < 0 ||
      (unsigned long long)info.st_size > kCaseinOverlayFileMaxBytes) {
    close(fd);
    return nil;
  }

  CC_SHA256_CTX context;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  CC_SHA256_Init(&context);
#pragma clang diagnostic pop

  unsigned char buffer[64 * 1024];
  unsigned long long readTotal = 0;
  while (YES) {
    ssize_t count = read(fd, buffer, sizeof(buffer));
    if (count == 0) {
      break;
    }
    if (count < 0) {
      if (errno == EINTR) {
        continue;
      }
      close(fd);
      return nil;
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_SHA256_Update(&context, buffer, (CC_LONG)count);
#pragma clang diagnostic pop
    readTotal += (unsigned long long)count;
    if (readTotal > kCaseinOverlayFileMaxBytes) {
      close(fd);
      return nil;
    }
  }

  struct stat finalInfo;
  if (fstat(fd, &finalInfo) != 0 || finalInfo.st_dev != info.st_dev ||
      finalInfo.st_ino != info.st_ino || finalInfo.st_size != info.st_size ||
      readTotal != (unsigned long long)info.st_size) {
    close(fd);
    return nil;
  }
  close(fd);

  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  CC_SHA256_Final(digest, &context);
#pragma clang diagnostic pop

  if (byteCount) {
    *byteCount = readTotal;
  }
  return [NSData dataWithBytes:digest length:sizeof(digest)];
}

static CaseinOverlayValidation CaseinValidateOverlay(NSString *bundlePath,
                                                     NSString *overlayPath,
                                                     NSString *appModule) {
  BOOL containsSealedSymlink = NO;
  NSDictionary<NSString *, NSData *> *expected =
      CaseinExpectedHashes(bundlePath, appModule, &containsSealedSymlink);
  if (!expected) {
    return CaseinOverlayValidationUnavailable;
  }
  if (containsSealedSymlink) {
    return CaseinOverlayValidationRejected;
  }

  struct stat rootInfo;
  BOOL rootMissing = NO;
  if (!CaseinLstat(overlayPath, &rootInfo, &rootMissing) || rootMissing ||
      !S_ISDIR(rootInfo.st_mode) || S_ISLNK(rootInfo.st_mode)) {
    return CaseinOverlayValidationRejected;
  }

  NSSet<NSString *> *expectedFiles = [NSSet setWithArray:expected.allKeys];
  NSSet<NSString *> *expectedDirectories =
      CaseinExpectedDirectories(expectedFiles);
  if (!expectedDirectories) {
    return CaseinOverlayValidationUnavailable;
  }

  NSMutableSet<NSString *> *actualFiles = [NSMutableSet set];
  NSMutableSet<NSString *> *actualDirectories = [NSMutableSet set];
  __block BOOL enumerationSucceeded = YES;
  // NSDirectoryEnumerator canonicalizes the system /var -> /private/var
  // alias on Apple platforms. Resolve only the already-lstat'd root so its
  // child paths share one prefix; descendant symlinks remain forbidden and
  // are checked with lstat/O_NOFOLLOW below.
  char resolvedRoot[PATH_MAX];
  if (!realpath(overlayPath.fileSystemRepresentation, resolvedRoot)) {
    return CaseinOverlayValidationRejected;
  }
  NSString *resolvedOverlayPath = [[NSFileManager defaultManager]
      stringWithFileSystemRepresentation:resolvedRoot
                                  length:strlen(resolvedRoot)];
  if (!resolvedOverlayPath) {
    return CaseinOverlayValidationRejected;
  }
  NSURL *overlayURL = [NSURL fileURLWithPath:resolvedOverlayPath
                                 isDirectory:YES];
  NSDirectoryEnumerator<NSURL *> *enumerator = [[NSFileManager defaultManager]
                 enumeratorAtURL:overlayURL
      includingPropertiesForKeys:nil
                         options:0
                    errorHandler:^BOOL(NSURL *url, NSError *error) {
                      (void)url;
                      (void)error;
                      enumerationSucceeded = NO;
                      return NO;
                    }];
  if (!enumerator) {
    return CaseinOverlayValidationRejected;
  }

  NSString *rootPrefix = [overlayURL.path stringByAppendingString:@"/"];
  unsigned long long totalBytes = 0;
  NSUInteger entryCount = 0;

  for (NSURL *entryURL in enumerator) {
    entryCount++;
    if (entryCount > kCaseinOverlayMaxEntries) {
      enumerationSucceeded = NO;
      break;
    }

    NSString *path = entryURL.path;
    if (![path hasPrefix:rootPrefix]) {
      enumerationSucceeded = NO;
      break;
    }

    NSString *relative = [path substringFromIndex:rootPrefix.length];
    if (!CaseinValidRelativePath(relative)) {
      enumerationSucceeded = NO;
      break;
    }

    struct stat info;
    BOOL missing = NO;
    if (!CaseinLstat(path, &info, &missing) || missing ||
        S_ISLNK(info.st_mode)) {
      enumerationSucceeded = NO;
      break;
    }

    if (S_ISDIR(info.st_mode)) {
      [actualDirectories addObject:relative];
      continue;
    }
    if (!S_ISREG(info.st_mode)) {
      enumerationSucceeded = NO;
      break;
    }

    NSData *expectedHash = expected[relative];
    unsigned long long fileBytes = 0;
    NSData *actualHash =
        expectedHash ? CaseinHashRegularFile(path, &fileBytes) : nil;
    if (!expectedHash || !actualHash ||
        ![actualHash isEqualToData:expectedHash] ||
        totalBytes > kCaseinOverlayTotalMaxBytes - fileBytes) {
      enumerationSucceeded = NO;
      break;
    }

    totalBytes += fileBytes;
    [actualFiles addObject:relative];
  }

  if (!enumerationSucceeded || ![actualFiles isEqualToSet:expectedFiles] ||
      ![actualDirectories isEqualToSet:expectedDirectories]) {
    return CaseinOverlayValidationRejected;
  }

  return CaseinOverlayValidationVerified;
}

static BOOL CaseinQuarantineOverlay(NSString *otpDirectory,
                                    NSString *overlayPath) {
  if (!CaseinSafeDirectory(otpDirectory)) {
    return NO;
  }

  for (NSUInteger attempt = 0; attempt < 4; attempt++) {
    NSString *leaf = [NSString
        stringWithFormat:@".casein-quarantine-%@", NSUUID.UUID.UUIDString];
    NSString *destination = [otpDirectory stringByAppendingPathComponent:leaf];
    struct stat destinationInfo;
    BOOL destinationMissing = NO;
    if (CaseinLstat(destination, &destinationInfo, &destinationMissing) ||
        !destinationMissing) {
      continue;
    }

    if (rename(overlayPath.fileSystemRepresentation,
               destination.fileSystemRepresentation) == 0) {
      struct stat oldInfo;
      BOOL oldMissing = NO;
      struct stat newInfo;
      BOOL newMissing = NO;
      BOOL oldGone =
          !CaseinLstat(overlayPath, &oldInfo, &oldMissing) && oldMissing;
      BOOL newPresent =
          CaseinLstat(destination, &newInfo, &newMissing) && !newMissing;
      return oldGone && newPresent;
    }
  }

  return NO;
}

static CaseinRuntimeOverlayState
CaseinRuntimeOverlayPrepareAtPaths(NSString *bundlePath,
                                   NSString *documentsPath,
                                   const char *appModuleCString) {
  if (!CaseinValidAppModule(appModuleCString) || bundlePath.length == 0 ||
      documentsPath.length == 0 || !CaseinSafeDirectory(bundlePath) ||
      !CaseinSafeDirectory(documentsPath)) {
    return CaseinRuntimeOverlayStateBlocked;
  }

  NSString *appModule = [NSString stringWithUTF8String:appModuleCString];
  if (!appModule) {
    return CaseinRuntimeOverlayStateBlocked;
  }

  NSString *otpDirectory =
      [documentsPath stringByAppendingPathComponent:@"otp"];
  NSString *overlayPath =
      [otpDirectory stringByAppendingPathComponent:appModule];
  struct stat overlayInfo;
  BOOL overlayMissing = NO;
  if (!CaseinLstat(overlayPath, &overlayInfo, &overlayMissing)) {
    return overlayMissing ? CaseinRuntimeOverlayStateSignedBundle
                          : CaseinRuntimeOverlayStateBlocked;
  }

  if (!CaseinSafeDirectory(otpDirectory)) {
    return CaseinRuntimeOverlayStateBlocked;
  }

  switch (CaseinValidateOverlay(bundlePath, overlayPath, appModule)) {
  case CaseinOverlayValidationVerified:
    return CaseinRuntimeOverlayStateVerifiedOverlay;
  case CaseinOverlayValidationRejected:
    return CaseinQuarantineOverlay(otpDirectory, overlayPath)
               ? CaseinRuntimeOverlayStateSignedBundleAfterQuarantine
               : CaseinRuntimeOverlayStateBlocked;
  case CaseinOverlayValidationUnavailable:
    return CaseinRuntimeOverlayStateBlocked;
  }

  return CaseinRuntimeOverlayStateBlocked;
}

CaseinRuntimeOverlayState CaseinRuntimeOverlayPrepare(const char *appModule) {
  NSArray<NSString *> *documentPaths = NSSearchPathForDirectoriesInDomains(
      NSDocumentDirectory, NSUserDomainMask, YES);
  NSString *documentsPath = documentPaths.firstObject;
  return CaseinRuntimeOverlayPrepareAtPaths(NSBundle.mainBundle.bundlePath,
                                            documentsPath, appModule);
}

const char *CaseinRuntimeOverlayStateName(CaseinRuntimeOverlayState state) {
  switch (state) {
  case CaseinRuntimeOverlayStateSignedBundle:
    return "signed_bundle";
  case CaseinRuntimeOverlayStateVerifiedOverlay:
    return "verified_overlay";
  case CaseinRuntimeOverlayStateSignedBundleAfterQuarantine:
    return "signed_bundle_after_quarantine";
  case CaseinRuntimeOverlayStateBlocked:
    return "blocked";
  }

  return "blocked";
}
