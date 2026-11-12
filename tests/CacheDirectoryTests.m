// SPDX-License-Identifier: GPL-3.0-only
#import <Foundation/Foundation.h>
#import "GXCacheDirectory.h"
#include <sys/stat.h>
#include <errno.h>
#include <unistd.h>

static NSString *const BackupName = @".GestaltX-Caches.backup";
static NSString *const StagingName = @".GestaltX-Caches.link";
static NSString *const TransactionName = @".GestaltX-Caches.transaction.plist";
static NSString *const LockName = @".GestaltX-Caches.lock";
static NSString *const RestorePrefix = @".GestaltX-Caches.restore.";

static void require(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

static NSData *sentinel(void) {
    return [@"keep the user's cache" dataUsingEncoding:NSUTF8StringEncoding];
}

static NSURL *makeRoot(void) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *root = [NSURL fileURLWithPath:
                   [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    require([files createDirectoryAtURL:root withIntermediateDirectories:YES
                              attributes:nil error:nil], @"Create test root");
    return root;
}

static NSURL *childURL(NSURL *root, NSString *name) {
    return [root URLByAppendingPathComponent:name];
}

static BOOL pathExists(NSURL *url) {
    struct stat info;
    return lstat(url.fileSystemRepresentation, &info) == 0;
}

static BOOL pathIsDirectory(NSURL *url) {
    struct stat info;
    return lstat(url.fileSystemRepresentation, &info) == 0 && S_ISDIR(info.st_mode);
}

static BOOL pathIsLinkTo(NSURL *url, NSString *target) {
    struct stat info;
    if (lstat(url.fileSystemRepresentation, &info) != 0 || !S_ISLNK(info.st_mode)) return NO;
    NSString *destination = [NSFileManager.defaultManager destinationOfSymbolicLinkAtPath:url.path
                                                                                    error:nil];
    return [destination isEqualToString:target];
}

static void writeSentinel(NSURL *url) {
    require([sentinel() writeToURL:url options:NSDataWritingAtomic error:nil], @"Write sentinel");
}

static void requireNoTransactionArtifacts(NSURL *root) {
    require(!pathExists(childURL(root, BackupName)), @"Fixed backup is removed after recovery");
    require(!pathExists(childURL(root, StagingName)), @"Staging link is removed after recovery");
    require(!pathExists(childURL(root, TransactionName)), @"Transaction is removed after recovery");
    NSArray<NSString *> *items = [NSFileManager.defaultManager contentsOfDirectoryAtPath:root.path
                                                                                   error:nil];
    require(![items indexesOfObjectsPassingTest:^BOOL(NSString *item, NSUInteger index, BOOL *stop) {
        return [item hasPrefix:RestorePrefix];
    }].count, @"Random restore directories are removed after recovery");
}

static int childMode(NSArray<NSString *> *arguments) {
    NSString *mode = arguments[1];
    NSURL *root = [NSURL fileURLWithPath:arguments[2]];
    NSString *target = childURL(root, @"target").path;
    NSURL *caches = childURL(root, @"Caches");
    NSError *error = nil;
    if ([mode isEqualToString:@"--crash-operation"]) {
        int64_t result = -4;
        BOOL restored = GXWithTemporaryCacheLink(caches, target, ^int64_t { return 77; },
                                                 &result, &error);
        fprintf(stderr, "Crash stage was not reached: restored=%d result=%lld error=%s\n",
                restored, (long long)result, error.localizedDescription.UTF8String ?: "none");
        return 90;
    }
    if ([mode isEqualToString:@"--crash-recovery"]) {
        BOOL restored = GXRecoverTemporaryCacheLink(caches, target, &error);
        fprintf(stderr, "Recovery crash stage was not reached: restored=%d error=%s\n",
                restored, error.localizedDescription.UTF8String ?: "none");
        return 91;
    }
    if ([mode isEqualToString:@"--try-operation"]) {
        int64_t result = -4;
        BOOL restored = GXWithTemporaryCacheLink(caches, target, ^int64_t { return 78; },
                                                 &result, &error);
        if (!restored && (error.code == EWOULDBLOCK || error.code == EAGAIN)) return 0;
        fprintf(stderr, "Lock contender was not rejected: restored=%d result=%lld error=%s\n",
                restored, (long long)result, error.localizedDescription.UTF8String ?: "none");
        return 93;
    }
    return 92;
}

static int runChild(NSURL *root, NSString *mode, NSString *stage) {
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = NSProcessInfo.processInfo.arguments[0];
    task.arguments = @[mode, root.path];
    NSMutableDictionary<NSString *, NSString *> *environment =
        [NSProcessInfo.processInfo.environment mutableCopy];
    if (stage) environment[@"GESTALTX_CACHE_TEST_CRASH_STAGE"] = stage;
    else [environment removeObjectForKey:@"GESTALTX_CACHE_TEST_CRASH_STAGE"];
    task.environment = environment;
    [task launch];
    [task waitUntilExit];
    require(task.terminationReason == NSTaskTerminationReasonExit, @"Crash child exits normally via _exit");
    return task.terminationStatus;
}

static void testNormalAndSetupFailures(void) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *root = makeRoot();
    NSURL *caches = childURL(root, @"Caches");
    NSURL *target = childURL(root, @"target");
    require([files createDirectoryAtURL:target withIntermediateDirectories:NO attributes:nil error:nil],
            @"Create target");
    NSURL *targetSentinel = childURL(target, @"outside");
    writeSentinel(targetSentinel);

    for (NSNumber *resultValue in @[@42, @-5, @-6]) {
        require([files createDirectoryAtURL:childURL(caches, @"nested")
                 withIntermediateDirectories:YES attributes:nil error:nil], @"Create original cache");
        NSURL *saved = [caches URLByAppendingPathComponent:@"nested/value"];
        writeSentinel(saved);
        struct stat before, after;
        require(lstat(caches.fileSystemRepresentation, &before) == 0, @"Stat original cache");
        int64_t result = -4;
        NSError *error = nil;
        BOOL restored = GXWithTemporaryCacheLink(caches, target.path, ^int64_t {
            NSString *destination = [files destinationOfSymbolicLinkAtPath:caches.path error:nil];
            require([destination isEqualToString:target.path], @"Operation sees the temporary link");
            return resultValue.longLongValue;
        }, &result, &error);
        require(restored && error == nil && result == resultValue.longLongValue,
                @"Preserve every operation result and restore successfully");
        require([[NSData dataWithContentsOfURL:saved] isEqual:sentinel()], @"Restore nested cache bytes");
        require(lstat(caches.fileSystemRepresentation, &after) == 0 &&
                before.st_dev == after.st_dev && before.st_ino == after.st_ino,
                @"Restore the original cache inode");
        requireNoTransactionArtifacts(root);
        require([files removeItemAtURL:caches error:nil], @"Reset original cache");
    }

    int64_t result = -4;
    NSError *error = nil;
    require(GXWithTemporaryCacheLink(caches, target.path, ^int64_t { return 1; }, &result, &error),
            @"Handle an absent Caches directory");
    require(pathIsDirectory(caches), @"Recreate an empty directory when no original existed");
    requireNoTransactionArtifacts(root);
    require([files removeItemAtURL:caches error:nil], @"Remove recreated cache directory");

    NSString *missing = childURL(root, @"missing").path;
    require([files createSymbolicLinkAtPath:caches.path withDestinationPath:missing error:nil],
            @"Create dangling original link");
    require(GXWithTemporaryCacheLink(caches, target.path, ^int64_t { return 2; }, &result, &error),
            @"Handle a dangling original link");
    require([[files destinationOfSymbolicLinkAtPath:caches.path error:nil] isEqualToString:missing],
            @"Restore the dangling link itself");
    require([files removeItemAtURL:caches error:nil], @"Reset dangling link");

    require([files createDirectoryAtURL:caches withIntermediateDirectories:NO attributes:nil error:nil],
            @"Create cache for failed setup");
    NSURL *saved = childURL(caches, @"value");
    writeSentinel(saved);
    __block BOOL invoked = NO;
    NSString *oversizedTarget = [@"x" stringByPaddingToLength:16384 withString:@"x" startingAtIndex:0];
    error = nil;
    require(!GXWithTemporaryCacheLink(caches, oversizedTarget, ^int64_t {
        invoked = YES;
        return 3;
    }, &result, &error), @"Reject an oversized link destination");
    require(!invoked && [[NSData dataWithContentsOfURL:saved] isEqual:sentinel()],
            @"Setup failure never invokes the operation or moves original data");
    require([[NSData dataWithContentsOfURL:targetSentinel] isEqual:sentinel()],
            @"Never alter the link target contents");
    requireNoTransactionArtifacts(root);
    [files removeItemAtURL:root error:nil];
}

static void testNestedOperationLock(void) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *root = makeRoot();
    NSURL *caches = childURL(root, @"Caches");
    NSURL *target = childURL(root, @"target");
    require([files createDirectoryAtURL:caches withIntermediateDirectories:NO attributes:nil error:nil],
            @"Create cache for lock test");
    require([files createDirectoryAtURL:target withIntermediateDirectories:NO attributes:nil error:nil],
            @"Create lock-test target");
    int64_t result = -4;
    NSError *error = nil;
    require(GXWithTemporaryCacheLink(caches, target.path, ^int64_t {
        int64_t nestedResult = -4;
        NSError *nestedError = nil;
        BOOL nested = GXWithTemporaryCacheLink(caches, target.path, ^int64_t { return 8; },
                                               &nestedResult, &nestedError);
        require(!nested && (nestedError.code == EWOULDBLOCK || nestedError.code == EAGAIN),
                @"Reject a concurrent transaction while the lock is held");
        require(runChild(root, @"--try-operation", nil) == 0,
                @"Reject a separate process while both flock descriptors are held");
        return 9;
    }, &result, &error), @"Outer transaction survives a rejected concurrent transaction");
    require(result == 9 && pathIsDirectory(caches), @"Outer transaction restores the cache");
    requireNoTransactionArtifacts(root);
    [files removeItemAtURL:root error:nil];
}

static void testLockPathReplacement(void) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *root = makeRoot();
    NSURL *caches = childURL(root, @"Caches");
    NSURL *target = childURL(root, @"target");
    require([files createDirectoryAtURL:caches withIntermediateDirectories:NO attributes:nil error:nil],
            @"Create original cache for lock replacement");
    require([files createDirectoryAtURL:target withIntermediateDirectories:NO attributes:nil error:nil],
            @"Create target for lock replacement");
    writeSentinel(childURL(caches, @"value"));
    NSURL *lockURL = childURL(root, LockName);
    NSData *replacement = [@"replacement lock" dataUsingEncoding:NSUTF8StringEncoding];
    int64_t result = -4;
    NSError *error = nil;
    BOOL restored = GXWithTemporaryCacheLink(caches, target.path, ^int64_t {
        require([files removeItemAtURL:lockURL error:nil], @"Remove the published lock path");
        require([replacement writeToURL:lockURL options:NSDataWritingAtomic error:nil],
                @"Publish a replacement lock inode");
        require(runChild(root, @"--try-operation", nil) == 0,
                @"Parent-directory flock still rejects a process using the replacement lock path");
        return 11;
    }, &result, &error);
    require(!restored && error.code == EBUSY && result == 11,
            @"Report the replaced lock identity after restoring the cache");
    require([[NSData dataWithContentsOfURL:childURL(caches, @"value")] isEqual:sentinel()],
            @"Restore original cache data despite lock-path replacement");
    require([[NSData dataWithContentsOfURL:lockURL] isEqual:replacement],
            @"Preserve the replacement lock file for inspection");
    requireNoTransactionArtifacts(root);
    [files removeItemAtURL:root error:nil];
}

static void testPathAndTransactionSymlinkRejection(void) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *root = makeRoot();
    NSURL *caches = childURL(root, @"Caches");
    NSURL *target = childURL(root, @"target");
    require([files createDirectoryAtURL:target withIntermediateDirectories:NO attributes:nil error:nil],
            @"Create symlink-rejection target");
    NSURL *lockVictim = childURL(root, @"lock-victim");
    writeSentinel(lockVictim);
    require([files createSymbolicLinkAtPath:childURL(root, LockName).path
                        withDestinationPath:lockVictim.path error:nil], @"Create lock-path symlink");
    NSError *error = nil;
    require(!GXRecoverTemporaryCacheLink(caches, target.path, &error) && error != nil,
            @"Reject a symlink in place of the cross-process lock file");
    require([[NSData dataWithContentsOfURL:lockVictim] isEqual:sentinel()],
            @"Never follow or alter the lock symlink target");
    [files removeItemAtURL:childURL(root, LockName) error:nil];

    NSURL *transactionVictim = childURL(root, @"transaction-victim");
    writeSentinel(transactionVictim);
    require([files createSymbolicLinkAtPath:childURL(root, TransactionName).path
                        withDestinationPath:transactionVictim.path error:nil], @"Create transaction-path symlink");
    error = nil;
    require(!GXRecoverTemporaryCacheLink(caches, target.path, &error) && error.code == EINVAL,
            @"Reject a symlink in place of a transaction file");
    require([[NSData dataWithContentsOfURL:transactionVictim] isEqual:sentinel()],
            @"Never follow or alter the transaction symlink target");
    [files removeItemAtURL:root error:nil];

    root = makeRoot();
    NSURL *realParent = childURL(root, @"real-parent");
    NSURL *aliasParent = childURL(root, @"alias-parent");
    target = childURL(root, @"target");
    require([files createDirectoryAtURL:realParent withIntermediateDirectories:NO attributes:nil error:nil],
            @"Create real cache parent");
    require([files createDirectoryAtURL:target withIntermediateDirectories:NO attributes:nil error:nil],
            @"Create parent-symlink target");
    require([files createSymbolicLinkAtPath:aliasParent.path withDestinationPath:realParent.path error:nil],
            @"Create cache-parent symlink");
    caches = childURL(aliasParent, @"Caches");
    error = nil;
    require(!GXRecoverTemporaryCacheLink(caches, target.path, &error) && error != nil,
            @"Reject a symlinked cache parent before acquiring locks");
    require(!pathExists(childURL(realParent, LockName)),
            @"Reject the parent before creating a lock through it");
    [files removeItemAtURL:root error:nil];
}

static void testTransactionReplacement(void) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *root = makeRoot();
    NSURL *caches = childURL(root, @"Caches");
    NSURL *target = childURL(root, @"target");
    require([files createDirectoryAtURL:caches withIntermediateDirectories:NO attributes:nil error:nil],
            @"Create original cache for transaction replacement");
    require([files createDirectoryAtURL:target withIntermediateDirectories:NO attributes:nil error:nil],
            @"Create target for transaction replacement");
    writeSentinel(childURL(caches, @"value"));
    writeSentinel(childURL(target, @"outside"));
    NSURL *transaction = childURL(root, TransactionName);
    NSData *replacement = [@"untrusted replacement transaction" dataUsingEncoding:NSUTF8StringEncoding];
    int64_t result = -4;
    NSError *error = nil;
    BOOL restored = GXWithTemporaryCacheLink(caches, target.path, ^int64_t {
        require([files removeItemAtURL:transaction error:nil], @"Remove the owned transaction");
        require([replacement writeToURL:transaction options:NSDataWritingAtomic error:nil],
                @"Publish a same-path transaction replacement");
        return 10;
    }, &result, &error);
    require(!restored && error.code == EBUSY && result == 10,
            @"Reject a transaction whose inode changed during the operation");
    require(pathIsLinkTo(caches, target.path),
            @"Leave the owned cache link in place when transaction identity is uncertain");
    require([[NSData dataWithContentsOfURL:transaction] isEqual:replacement],
            @"Preserve the replacement transaction as evidence");
    require([[NSData dataWithContentsOfURL:childURL(childURL(root, BackupName), @"value")]
             isEqual:sentinel()], @"Preserve the original cache in the fixed backup");
    require([[NSData dataWithContentsOfURL:childURL(target, @"outside")] isEqual:sentinel()],
            @"Never follow and alter the target while preserving evidence");
    [files removeItemAtURL:root error:nil];
}

static void testNoOriginalEmptyReplacement(void) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *root = makeRoot();
    NSURL *caches = childURL(root, @"Caches");
    NSURL *target = childURL(root, @"target");
    require([files createDirectoryAtURL:target withIntermediateDirectories:NO attributes:nil error:nil],
            @"Create target for no-original replacement");
    require(runChild(root, @"--crash-operation", @"after-link") == 97,
            @"Leave a no-original transaction and installed link");
    require([files removeItemAtURL:caches error:nil], @"Remove the owned no-original link");
    require([files createDirectoryAtURL:caches withIntermediateDirectories:NO attributes:nil error:nil],
            @"Install an unrelated empty directory at Caches");
    NSError *error = nil;
    require(!GXRecoverTemporaryCacheLink(caches, target.path, &error) && error.code == EBUSY,
            @"Do not accept an unmarked empty directory as a crash-created replacement");
    require(pathIsDirectory(caches) && pathExists(childURL(root, TransactionName)),
            @"Preserve the unrelated directory and transaction evidence");
    [files removeItemAtURL:root error:nil];
}

static void testConcurrentReplacement(void) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *root = makeRoot();
    NSURL *caches = childURL(root, @"Caches");
    NSURL *target = childURL(root, @"target");
    require([files createDirectoryAtURL:caches withIntermediateDirectories:NO attributes:nil error:nil],
            @"Create original cache for replacement test");
    require([files createDirectoryAtURL:target withIntermediateDirectories:NO attributes:nil error:nil],
            @"Create replacement-test target");
    writeSentinel(childURL(caches, @"value"));
    writeSentinel(childURL(target, @"outside"));
    int64_t result = -4;
    NSError *error = nil;
    BOOL restored = GXWithTemporaryCacheLink(caches, target.path, ^int64_t {
        require([files removeItemAtURL:caches error:nil], @"Remove owned temporary link");
        require([@"concurrent content" writeToURL:caches atomically:YES
                                          encoding:NSUTF8StringEncoding error:nil],
                @"Install a concurrent replacement");
        return 4;
    }, &result, &error);
    require(!restored && error.code == EBUSY, @"Report a concurrent replacement as a restoration failure");
    require([[NSString stringWithContentsOfURL:caches encoding:NSUTF8StringEncoding error:nil]
             isEqualToString:@"concurrent content"], @"Preserve the concurrent replacement");
    NSURL *backup = childURL(root, BackupName);
    require([[NSData dataWithContentsOfURL:childURL(backup, @"value")] isEqual:sentinel()],
            @"Preserve original data in the fixed recovery location");
    require(pathExists(childURL(root, TransactionName)), @"Keep the transaction as recovery evidence");
    NSError *retryError = nil;
    require(!GXRecoverTemporaryCacheLink(caches, target.path, &retryError) && retryError.code == EBUSY,
            @"A later launch still refuses to delete the replacement");
    require(pathExists(backup) && pathExists(childURL(root, TransactionName)),
            @"Repeated recovery preserves both original data and evidence");
    require([[NSData dataWithContentsOfURL:childURL(target, @"outside")] isEqual:sentinel()],
            @"Never follow and delete the target directory");
    [files removeItemAtURL:root error:nil];
}

static void testCrashRecovery(NSString *stage, BOOL hadOriginal) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *root = makeRoot();
    NSURL *caches = childURL(root, @"Caches");
    NSURL *target = childURL(root, @"target");
    require([files createDirectoryAtURL:target withIntermediateDirectories:NO attributes:nil error:nil],
            @"Create crash-test target");
    struct stat before;
    memset(&before, 0, sizeof(before));
    if (hadOriginal) {
        require([files createDirectoryAtURL:childURL(caches, @"nested")
                 withIntermediateDirectories:YES attributes:nil error:nil], @"Create crash-test original");
        writeSentinel([caches URLByAppendingPathComponent:@"nested/value"]);
        require(lstat(caches.fileSystemRepresentation, &before) == 0, @"Stat crash-test original");
    }
    require(runChild(root, @"--crash-operation", stage) == 97,
            [@"Reach injected crash stage " stringByAppendingString:stage]);
    NSError *error = nil;
    require(GXRecoverTemporaryCacheLink(caches, target.path, &error) && error == nil,
            [@"Recover interrupted transaction at " stringByAppendingString:stage]);
    require(pathIsDirectory(caches), @"Recovery leaves a real cache directory");
    if (hadOriginal) {
        struct stat after;
        require(lstat(caches.fileSystemRepresentation, &after) == 0 &&
                before.st_dev == after.st_dev && before.st_ino == after.st_ino,
                @"Cold-start recovery restores the original inode");
        require([[NSData dataWithContentsOfURL:[caches URLByAppendingPathComponent:@"nested/value"]]
                 isEqual:sentinel()], @"Cold-start recovery restores original bytes");
    } else {
        NSArray *items = [files contentsOfDirectoryAtPath:caches.path error:nil];
        require(items.count == 0, @"No-original recovery creates an empty cache directory");
    }
    requireNoTransactionArtifacts(root);
    [files removeItemAtURL:root error:nil];
}

static void testCrashAfterNoOriginalRecreation(void) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *root = makeRoot();
    NSURL *caches = childURL(root, @"Caches");
    NSURL *target = childURL(root, @"target");
    require([files createDirectoryAtURL:target withIntermediateDirectories:NO attributes:nil error:nil],
            @"Create no-original crash target");
    require(runChild(root, @"--crash-operation", @"after-link") == 97,
            @"Leave an installed link and no-original transaction");
    require(runChild(root, @"--crash-recovery", @"after-recreate") == 97,
            @"Crash recovery after recreating the empty cache directory");
    require(pathIsDirectory(caches) && pathExists(childURL(root, TransactionName)),
            @"Crash leaves the recreated directory and durable transaction");
    NSError *error = nil;
    require(GXRecoverTemporaryCacheLink(caches, target.path, &error) && error == nil,
            @"Next launch recognizes its own recreated empty directory");
    requireNoTransactionArtifacts(root);
    [files removeItemAtURL:root error:nil];
}

static void testCrashAfterNoOriginalTransactionRemoval(void) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *root = makeRoot();
    NSURL *caches = childURL(root, @"Caches");
    NSURL *target = childURL(root, @"target");
    require([files createDirectoryAtURL:target withIntermediateDirectories:NO attributes:nil error:nil],
            @"Create no-original transaction-removal target");
    require(runChild(root, @"--crash-operation", @"after-link") == 97,
            @"Leave an installed link for transaction-removal recovery");
    require(runChild(root, @"--crash-recovery", @"after-transaction-remove") == 97,
            @"Crash after removing the durable transaction");
    require(pathIsDirectory(caches) && !pathExists(childURL(root, TransactionName)),
            @"Crash leaves only the marked replacement cache directory");
    NSError *error = nil;
    require(GXRecoverTemporaryCacheLink(caches, target.path, &error) && error == nil,
            @"Next launch removes the orphan restore marker without a transaction");
    NSArray<NSString *> *items = [files contentsOfDirectoryAtPath:caches.path error:nil];
    require(items.count == 0, @"Orphan-marker cleanup leaves an empty cache directory");
    requireNoTransactionArtifacts(root);
    [files removeItemAtURL:root error:nil];
}

static void testLegacyRecovery(void) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *root = makeRoot();
    NSURL *caches = childURL(root, @"Caches");
    NSURL *target = childURL(root, @"target");
    require([files createDirectoryAtURL:caches withIntermediateDirectories:NO attributes:nil error:nil],
            @"Create legacy original cache");
    require([files createDirectoryAtURL:target withIntermediateDirectories:NO attributes:nil error:nil],
            @"Create legacy target");
    writeSentinel(childURL(caches, @"value"));
    struct stat before, after;
    require(lstat(caches.fileSystemRepresentation, &before) == 0, @"Stat legacy original");
    NSURL *legacy = childURL(root, [NSString stringWithFormat:@".GestaltX-Caches-%@.backup",
                                    NSUUID.UUID.UUIDString]);
    require([files moveItemAtURL:caches toURL:legacy error:nil], @"Create legacy random backup");
    require([files createSymbolicLinkAtPath:caches.path withDestinationPath:target.path error:nil],
            @"Create legacy installed link");
    NSError *error = nil;
    require(GXRecoverTemporaryCacheLink(caches, target.path, &error), @"Recover a version 1.0.5 backup");
    require(lstat(caches.fileSystemRepresentation, &after) == 0 && before.st_ino == after.st_ino,
            @"Legacy recovery restores the original inode");
    require([[NSData dataWithContentsOfURL:childURL(caches, @"value")] isEqual:sentinel()],
            @"Legacy recovery restores original bytes");
    require(!pathExists(legacy), @"Legacy backup path is consumed");
    [files removeItemAtURL:root error:nil];

    root = makeRoot();
    caches = childURL(root, @"Caches");
    target = childURL(root, @"target");
    require([files createDirectoryAtURL:target withIntermediateDirectories:NO attributes:nil error:nil],
            @"Create no-original legacy target");
    require([files createSymbolicLinkAtPath:caches.path withDestinationPath:target.path error:nil],
            @"Create no-original legacy link");
    error = nil;
    require(GXRecoverTemporaryCacheLink(caches, target.path, &error),
            @"Recover a version 1.0.5 transaction with no original cache");
    require(pathIsDirectory(caches), @"Legacy no-original recovery creates a directory");
    [files removeItemAtURL:root error:nil];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
        if (arguments.count >= 3 && [arguments[1] hasPrefix:@"--"]) return childMode(arguments);

        testNormalAndSetupFailures();
        testNestedOperationLock();
        testLockPathReplacement();
        testPathAndTransactionSymlinkRejection();
        testTransactionReplacement();
        testNoOriginalEmptyReplacement();
        testConcurrentReplacement();
        testCrashRecovery(@"after-transaction", YES);
        testCrashRecovery(@"after-transaction", NO);
        testCrashRecovery(@"after-move", YES);
        testCrashRecovery(@"after-restore", NO);
        testCrashRecovery(@"after-link", YES);
        testCrashRecovery(@"after-link", NO);
        testCrashAfterNoOriginalRecreation();
        testCrashAfterNoOriginalTransactionRemoval();
        testLegacyRecovery();
        puts("PASS: transactional cache exchange, cold-start crash recovery, locking, legacy migration and replacement preservation.");
    }
    return 0;
}
