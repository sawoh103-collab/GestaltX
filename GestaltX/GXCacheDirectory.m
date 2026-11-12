// SPDX-License-Identifier: GPL-3.0-only
#import "GXCacheDirectory.h"
#include <dirent.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static NSString *const GXBackupName = @".GestaltX-Caches.backup";
static NSString *const GXLinkName = @".GestaltX-Caches.link";
static NSString *const GXTransactionName = @".GestaltX-Caches.transaction.plist";
static NSString *const GXLockName = @".GestaltX-Caches.lock";
static NSString *const GXRestorePrefix = @".GestaltX-Caches.restore.";
static NSString *const GXRestoreMarkerPrefix = @".GestaltX-restore-marker.";
static NSString *const GXRestoreMarkerTempPrefix = @".GestaltX-restore-marker.tmp.";
static NSString *const GXTransactionTempPrefix = @".GestaltX-Caches.transaction.";
static NSString *const GXTransactionTempSuffix = @".tmp";
static NSString *const GXIsolationPrefix = @".GestaltX-Caches.isolated.";
static const off_t GXMaximumTransactionSize = 64 * 1024;

typedef struct {
    int directoryDescriptor;
    int fileDescriptor;
    unsigned long long directoryDevice;
    unsigned long long directoryInode;
    unsigned long long fileDevice;
    unsigned long long fileInode;
} GXCacheLock;

static NSError *GXCacheError(int code, NSURL *url) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:code
                           userInfo:@{NSFilePathErrorKey: url.path}];
}

static BOOL GXFail(NSError **error, int code, NSURL *url) {
    if (error) *error = GXCacheError(code, url);
    return NO;
}

static NSURL *GXNeighbor(NSURL *caches, NSString *name) {
    return [caches.URLByDeletingLastPathComponent URLByAppendingPathComponent:name];
}

static BOOL GXValidChildName(NSString *name) {
    return [name isKindOfClass:NSString.class] && name.length > 0 &&
           ![name isEqualToString:@"."] && ![name isEqualToString:@".."] &&
           [name.lastPathComponent isEqualToString:name];
}

static BOOL GXStatAt(int directoryDescriptor, NSString *name, NSURL *url,
                     struct stat *info, BOOL *exists, NSError **error) {
    if (!GXValidChildName(name)) return GXFail(error, EINVAL, url);
    if (fstatat(directoryDescriptor, name.fileSystemRepresentation, info,
                AT_SYMLINK_NOFOLLOW) == 0) {
        *exists = YES;
        return YES;
    }
    if (errno == ENOENT) {
        *exists = NO;
        memset(info, 0, sizeof(*info));
        return YES;
    }
    return GXFail(error, errno, url);
}

static BOOL GXSameItem(const struct stat *item, unsigned long long device,
                       unsigned long long inode) {
    return (unsigned long long)item->st_dev == device &&
           (unsigned long long)item->st_ino == inode;
}

static BOOL GXSameStat(const struct stat *left, const struct stat *right) {
    return left->st_dev == right->st_dev && left->st_ino == right->st_ino;
}

static BOOL GXLinkMatchesAt(int directoryDescriptor, NSString *name, NSURL *url,
                            NSString *target, unsigned long long device,
                            unsigned long long inode, BOOL requireIdentity,
                            NSError **error) {
    struct stat before, after;
    BOOL exists = NO;
    if (!GXStatAt(directoryDescriptor, name, url, &before, &exists, error) ||
        !exists || !S_ISLNK(before.st_mode) || before.st_nlink != 1) return NO;
    char destination[PATH_MAX + 1];
    ssize_t length = readlinkat(directoryDescriptor, name.fileSystemRepresentation,
                                destination, PATH_MAX);
    if (length < 0) return GXFail(error, errno, url);
    if (length == PATH_MAX) return GXFail(error, ENAMETOOLONG, url);
    destination[length] = '\0';
    if (fstatat(directoryDescriptor, name.fileSystemRepresentation, &after,
                AT_SYMLINK_NOFOLLOW) != 0) return GXFail(error, errno, url);
    if (!S_ISLNK(after.st_mode) || after.st_nlink != 1 || !GXSameStat(&before, &after)) {
        return GXFail(error, EBUSY, url);
    }
    const char *expected = target.fileSystemRepresentation;
    return strlen(expected) == (size_t)length &&
           memcmp(destination, expected, (size_t)length) == 0 &&
           (!requireIdentity || GXSameItem(&after, device, inode));
}

static BOOL GXSyncDirectoryDescriptor(int descriptor, NSURL *directory, NSError **error) {
    return fsync(descriptor) == 0 ? YES : GXFail(error, errno, directory);
}

static NSArray<NSString *> *GXDirectoryItems(int directoryDescriptor, NSURL *directory,
                                              NSError **error) {
    // dup() would share the directory stream offset, so a second enumeration
    // could start at EOF and mistake a nonempty directory for an empty one.
    int copy = openat(directoryDescriptor, ".",
                      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (copy < 0) {
        GXFail(error, errno, directory);
        return nil;
    }
    DIR *stream = fdopendir(copy);
    if (!stream) {
        int code = errno;
        close(copy);
        GXFail(error, code, directory);
        return nil;
    }
    NSMutableArray<NSString *> *items = [NSMutableArray array];
    struct dirent *entry = NULL;
    int code = 0;
    while (YES) {
        errno = 0;
        entry = readdir(stream);
        if (!entry) {
            code = errno;
            break;
        }
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
        NSString *name = [NSFileManager.defaultManager
                          stringWithFileSystemRepresentation:entry->d_name
                          length:strlen(entry->d_name)];
        if (!name) {
            (void)closedir(stream);
            GXFail(error, EILSEQ, directory);
            return nil;
        }
        [items addObject:name];
    }
    if (closedir(stream) != 0 && code == 0) code = errno;
    if (code != 0) {
        GXFail(error, code, directory);
        return nil;
    }
    return items;
}

static BOOL GXOpenDirectoryAt(int parentDescriptor, NSString *name, NSURL *url,
                              int *descriptor, struct stat *identity, NSError **error) {
    *descriptor = -1;
    int opened = openat(parentDescriptor, name.fileSystemRepresentation,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (opened < 0) return GXFail(error, errno, url);
    struct stat openedInfo, publishedInfo;
    int code = 0;
    if (fstat(opened, &openedInfo) != 0) code = errno;
    else if (!S_ISDIR(openedInfo.st_mode)) code = ENOTDIR;
    else if (fstatat(parentDescriptor, name.fileSystemRepresentation, &publishedInfo,
                     AT_SYMLINK_NOFOLLOW) != 0) code = errno;
    else if (!S_ISDIR(publishedInfo.st_mode) || !GXSameStat(&openedInfo, &publishedInfo)) {
        code = EBUSY;
    }
    if (code != 0) {
        close(opened);
        return GXFail(error, code, url);
    }
    *descriptor = opened;
    if (identity) *identity = openedInfo;
    return YES;
}

static BOOL GXWriteAll(int descriptor, NSData *data, int *code) {
    const uint8_t *bytes = data.bytes;
    NSUInteger remaining = data.length;
    while (remaining > 0) {
        ssize_t count = write(descriptor, bytes, remaining);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            *code = count == 0 ? EIO : errno;
            return NO;
        }
        bytes += count;
        remaining -= (NSUInteger)count;
    }
    return YES;
}

static void GXReleaseLock(GXCacheLock *lock) {
    if (lock->fileDescriptor >= 0) {
        (void)flock(lock->fileDescriptor, LOCK_UN);
        close(lock->fileDescriptor);
    }
    if (lock->directoryDescriptor >= 0) {
        (void)flock(lock->directoryDescriptor, LOCK_UN);
        close(lock->directoryDescriptor);
    }
    lock->fileDescriptor = -1;
    lock->directoryDescriptor = -1;
}

static BOOL GXAcquireLock(NSURL *caches, GXCacheLock *lock, NSError **error) {
    memset(lock, 0, sizeof(*lock));
    lock->directoryDescriptor = -1;
    lock->fileDescriptor = -1;
    NSURL *directoryURL = caches.URLByDeletingLastPathComponent;
    NSURL *lockURL = GXNeighbor(caches, GXLockName);
    struct stat directoryPath, directoryOpened, opened, published;
    int code = 0;
    if (lstat(directoryURL.fileSystemRepresentation, &directoryPath) != 0) code = errno;
    else if (!S_ISDIR(directoryPath.st_mode)) code = ENOTDIR;
    if (code == 0) {
        lock->directoryDescriptor = open(directoryURL.fileSystemRepresentation,
                                         O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (lock->directoryDescriptor < 0) code = errno;
    }
    if (code == 0 && fstat(lock->directoryDescriptor, &directoryOpened) != 0) code = errno;
    else if (code == 0 && (!S_ISDIR(directoryOpened.st_mode) ||
                           !GXSameStat(&directoryPath, &directoryOpened))) code = EBUSY;
    else if (code == 0 && flock(lock->directoryDescriptor, LOCK_EX | LOCK_NB) != 0) code = errno;
    else if (code == 0 && lstat(directoryURL.fileSystemRepresentation, &directoryPath) != 0) code = errno;
    else if (code == 0 && !GXSameStat(&directoryPath, &directoryOpened)) code = EBUSY;
    if (code == 0) {
        lock->fileDescriptor = openat(lock->directoryDescriptor,
                                      GXLockName.fileSystemRepresentation,
                                      O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (lock->fileDescriptor < 0) code = errno;
    }
    if (code == 0 && fstat(lock->fileDescriptor, &opened) != 0) code = errno;
    else if (code == 0 && !S_ISREG(opened.st_mode)) code = EINVAL;
    else if (code == 0 && opened.st_nlink != 1) code = EMLINK;
    else if (code == 0 && fchmod(lock->fileDescriptor, 0600) != 0) code = errno;
    else if (code == 0 && flock(lock->fileDescriptor, LOCK_EX | LOCK_NB) != 0) code = errno;
    else if (code == 0 && fstatat(lock->directoryDescriptor,
                                  GXLockName.fileSystemRepresentation, &published,
                                  AT_SYMLINK_NOFOLLOW) != 0) code = errno;
    else if (code == 0 && (!S_ISREG(published.st_mode) || published.st_nlink != 1)) code = EBUSY;
    else if (code == 0 && !GXSameItem(&published, (unsigned long long)opened.st_dev,
                                      (unsigned long long)opened.st_ino)) code = EBUSY;
    if (code != 0) {
        GXReleaseLock(lock);
        GXFail(error, code, lockURL);
        return NO;
    }
    lock->directoryDevice = (unsigned long long)directoryOpened.st_dev;
    lock->directoryInode = (unsigned long long)directoryOpened.st_ino;
    lock->fileDevice = (unsigned long long)opened.st_dev;
    lock->fileInode = (unsigned long long)opened.st_ino;
    return YES;
}

static BOOL GXValidateLock(NSURL *caches, const GXCacheLock *lock, NSError **error) {
    NSURL *directoryURL = caches.URLByDeletingLastPathComponent;
    NSURL *lockURL = GXNeighbor(caches, GXLockName);
    struct stat directoryOpened, directoryPublished, fileOpened, filePublished;
    if (fstat(lock->directoryDescriptor, &directoryOpened) != 0) {
        return GXFail(error, errno, directoryURL);
    }
    if (lstat(directoryURL.fileSystemRepresentation, &directoryPublished) != 0) {
        return GXFail(error, errno, directoryURL);
    }
    if (!S_ISDIR(directoryOpened.st_mode) || !S_ISDIR(directoryPublished.st_mode) ||
        !GXSameItem(&directoryOpened, lock->directoryDevice, lock->directoryInode) ||
        !GXSameStat(&directoryOpened, &directoryPublished)) {
        return GXFail(error, EBUSY, directoryURL);
    }
    if (fstat(lock->fileDescriptor, &fileOpened) != 0) return GXFail(error, errno, lockURL);
    if (fstatat(lock->directoryDescriptor, GXLockName.fileSystemRepresentation,
                &filePublished, AT_SYMLINK_NOFOLLOW) != 0) {
        return GXFail(error, errno, lockURL);
    }
    if (!S_ISREG(fileOpened.st_mode) || !S_ISREG(filePublished.st_mode) ||
        fileOpened.st_nlink != 1 || filePublished.st_nlink != 1 ||
        !GXSameItem(&fileOpened, lock->fileDevice, lock->fileInode) ||
        !GXSameStat(&fileOpened, &filePublished)) {
        return GXFail(error, EBUSY, lockURL);
    }
    return YES;
}

static BOOL GXRegularFileMatchesAt(int directoryDescriptor, NSString *name, NSURL *url,
                                   const struct stat *expected, NSError **error) {
    struct stat current;
    BOOL exists = NO;
    if (!GXStatAt(directoryDescriptor, name, url, &current, &exists, error)) return NO;
    if (!exists || !S_ISREG(current.st_mode) || current.st_nlink != 1 ||
        !GXSameStat(&current, expected)) return GXFail(error, EBUSY, url);
    return YES;
}

static NSString *GXIsolationName(void) {
    return [GXIsolationPrefix stringByAppendingString:NSUUID.UUID.UUIDString];
}

static BOOL GXRestoreIsolation(int directoryDescriptor, NSString *isolatedName,
                               NSString *originalName, NSURL *originalURL,
                               NSURL *directoryURL, NSError **error) {
    if (renameatx_np(directoryDescriptor, isolatedName.fileSystemRepresentation,
                     directoryDescriptor, originalName.fileSystemRepresentation,
                     RENAME_EXCL) == 0) {
        (void)GXSyncDirectoryDescriptor(directoryDescriptor, directoryURL, nil);
    }
    return GXFail(error, EBUSY, originalURL);
}

static BOOL GXRemoveExpectedRegularAt(int directoryDescriptor, NSString *name, NSURL *url,
                                      const struct stat *expected, NSURL *directoryURL,
                                      NSError **error) {
    NSString *isolatedName = GXIsolationName();
    if (renameatx_np(directoryDescriptor, name.fileSystemRepresentation,
                     directoryDescriptor, isolatedName.fileSystemRepresentation,
                     RENAME_EXCL) != 0) return GXFail(error, errno, url);
    NSURL *isolatedURL = [directoryURL URLByAppendingPathComponent:isolatedName];
    NSError *matchError = nil;
    if (!GXRegularFileMatchesAt(directoryDescriptor, isolatedName, isolatedURL,
                                expected, &matchError)) {
        return GXRestoreIsolation(directoryDescriptor, isolatedName, name, url,
                                  directoryURL, error);
    }
    if (unlinkat(directoryDescriptor, isolatedName.fileSystemRepresentation, 0) != 0) {
        int code = errno;
        (void)GXRestoreIsolation(directoryDescriptor, isolatedName, name, url,
                                 directoryURL, nil);
        return GXFail(error, code, url);
    }
    return GXSyncDirectoryDescriptor(directoryDescriptor, directoryURL, error);
}

static BOOL GXRemoveExpectedLinkAt(int directoryDescriptor, NSString *name, NSURL *url,
                                   NSString *target, unsigned long long device,
                                   unsigned long long inode, BOOL requireIdentity,
                                   NSURL *directoryURL, NSError **error) {
    NSString *isolatedName = GXIsolationName();
    if (renameatx_np(directoryDescriptor, name.fileSystemRepresentation,
                     directoryDescriptor, isolatedName.fileSystemRepresentation,
                     RENAME_EXCL) != 0) return GXFail(error, errno, url);
    NSURL *isolatedURL = [directoryURL URLByAppendingPathComponent:isolatedName];
    NSError *matchError = nil;
    if (!GXLinkMatchesAt(directoryDescriptor, isolatedName, isolatedURL, target,
                         device, inode, requireIdentity, &matchError)) {
        return GXRestoreIsolation(directoryDescriptor, isolatedName, name, url,
                                  directoryURL, error);
    }
    if (unlinkat(directoryDescriptor, isolatedName.fileSystemRepresentation, 0) != 0) {
        int code = errno;
        (void)GXRestoreIsolation(directoryDescriptor, isolatedName, name, url,
                                 directoryURL, nil);
        return GXFail(error, code, url);
    }
    return GXSyncDirectoryDescriptor(directoryDescriptor, directoryURL, error);
}

static BOOL GXRenameExpectedAt(int directoryDescriptor, NSString *sourceName,
                               NSURL *sourceURL, NSString *destinationName,
                               NSURL *destinationURL, const struct stat *expected,
                               NSURL *directoryURL, NSError **error) {
    NSString *isolatedName = GXIsolationName();
    if (renameatx_np(directoryDescriptor, sourceName.fileSystemRepresentation,
                     directoryDescriptor, isolatedName.fileSystemRepresentation,
                     RENAME_EXCL) != 0) return GXFail(error, errno, destinationURL);
    NSURL *isolatedURL = [directoryURL URLByAppendingPathComponent:isolatedName];
    struct stat isolated;
    BOOL exists = NO;
    if (!GXStatAt(directoryDescriptor, isolatedName, isolatedURL,
                  &isolated, &exists, error) || !exists || !GXSameStat(&isolated, expected)) {
        return GXRestoreIsolation(directoryDescriptor, isolatedName, sourceName,
                                  sourceURL, directoryURL, error);
    }
    if (renameatx_np(directoryDescriptor, isolatedName.fileSystemRepresentation,
                     directoryDescriptor, destinationName.fileSystemRepresentation,
                     RENAME_EXCL) != 0) {
        int code = errno;
        (void)GXRestoreIsolation(directoryDescriptor, isolatedName, sourceName,
                                 sourceURL, directoryURL, nil);
        return GXFail(error, code, destinationURL);
    }
    struct stat published;
    exists = NO;
    if (!GXStatAt(directoryDescriptor, destinationName, destinationURL,
                  &published, &exists, error) || !exists || !GXSameStat(&published, expected)) {
        return GXFail(error, EBUSY, destinationURL);
    }
    return GXSyncDirectoryDescriptor(directoryDescriptor, directoryURL, error);
}

static BOOL GXValidUUID(NSString *value);

static BOOL GXValidTransactionTempName(NSString *name) {
    if (![name hasPrefix:GXTransactionTempPrefix] ||
        ![name hasSuffix:GXTransactionTempSuffix]) return NO;
    NSUInteger start = GXTransactionTempPrefix.length;
    NSUInteger length = name.length - start - GXTransactionTempSuffix.length;
    if (length == 0) return NO;
    NSString *token = [name substringWithRange:NSMakeRange(start, length)];
    return GXValidUUID(token);
}

static BOOL GXCleanupTransactionTemps(int directoryDescriptor, NSURL *directoryURL,
                                      NSError **error) {
    NSArray<NSString *> *items = GXDirectoryItems(directoryDescriptor, directoryURL, error);
    if (!items) return NO;
    for (NSString *name in items) {
        if (![name hasPrefix:GXTransactionTempPrefix] ||
            ![name hasSuffix:GXTransactionTempSuffix]) continue;
        NSURL *url = [directoryURL URLByAppendingPathComponent:name];
        if (!GXValidTransactionTempName(name)) return GXFail(error, EBUSY, url);
        struct stat info;
        BOOL exists = NO;
        if (!GXStatAt(directoryDescriptor, name, url, &info, &exists, error)) return NO;
        if (!exists) continue;
        if (!S_ISREG(info.st_mode) || info.st_nlink != 1 || info.st_uid != geteuid() ||
            (info.st_mode & 0777) != 0600 || info.st_size < 0 ||
            info.st_size > GXMaximumTransactionSize) return GXFail(error, EBUSY, url);
        if (!GXRemoveExpectedRegularAt(directoryDescriptor, name, url, &info,
                                       directoryURL, error)) return NO;
    }
    return YES;
}

static BOOL GXRejectIsolationArtifacts(int directoryDescriptor, NSURL *directoryURL,
                                       NSError **error) {
    NSArray<NSString *> *items = GXDirectoryItems(directoryDescriptor, directoryURL, error);
    if (!items) return NO;
    for (NSString *name in items) {
        if ([name hasPrefix:GXIsolationPrefix]) {
            return GXFail(error, EBUSY, [directoryURL URLByAppendingPathComponent:name]);
        }
    }
    return YES;
}

static BOOL GXWriteTransactionAt(int directoryDescriptor, NSURL *directoryURL,
                                 NSURL *url, NSDictionary *record,
                                 struct stat *identity, NSError **error) {
    memset(identity, 0, sizeof(*identity));
    NSError *writeError = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:record
                                                               format:NSPropertyListBinaryFormat_v1_0
                                                              options:0 error:&writeError];
    if (!data) {
        if (error) *error = writeError;
        return NO;
    }

    NSString *temporaryName = [NSString stringWithFormat:@"%@%@%@",
                               GXTransactionTempPrefix, NSUUID.UUID.UUIDString,
                               GXTransactionTempSuffix];
    NSURL *temporary = [directoryURL URLByAppendingPathComponent:temporaryName];
    int descriptor = openat(directoryDescriptor, temporaryName.fileSystemRepresentation,
                            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (descriptor < 0) return GXFail(error, errno, temporary);

    struct stat created;
    memset(&created, 0, sizeof(created));
    BOOL identified = fstat(descriptor, &created) == 0;
    int code = identified ? 0 : errno;
    if (code == 0 && fchmod(descriptor, 0600) != 0) code = errno;
    if (code == 0) (void)GXWriteAll(descriptor, data, &code);
    if (code == 0 && fsync(descriptor) != 0) code = errno;
    if (close(descriptor) != 0 && code == 0) code = errno;

    if (code != 0) {
        if (identified) (void)GXRemoveExpectedRegularAt(directoryDescriptor, temporaryName,
                                                        temporary, &created, directoryURL, nil);
        return GXFail(error, code, temporary);
    }
    if (renameatx_np(directoryDescriptor, temporaryName.fileSystemRepresentation,
                     directoryDescriptor, GXTransactionName.fileSystemRepresentation,
                     RENAME_EXCL) != 0) {
        code = errno;
        (void)GXRemoveExpectedRegularAt(directoryDescriptor, temporaryName, temporary,
                                        &created, directoryURL, nil);
        return GXFail(error, code, url);
    }
    struct stat published;
    if (fstatat(directoryDescriptor, GXTransactionName.fileSystemRepresentation,
                &published, AT_SYMLINK_NOFOLLOW) != 0) {
        return GXFail(error, errno, url);
    }
    if (!S_ISREG(published.st_mode) || published.st_nlink != 1 ||
        !GXSameStat(&created, &published)) return GXFail(error, EBUSY, url);
    *identity = published;
    return GXSyncDirectoryDescriptor(directoryDescriptor, directoryURL, error);
}

static NSDictionary *GXReadTransactionAt(int directoryDescriptor, NSURL *url,
                                         struct stat *identity, NSError **error) {
    int descriptor = openat(directoryDescriptor, GXTransactionName.fileSystemRepresentation,
                            O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (descriptor < 0) {
        GXFail(error, errno, url);
        return nil;
    }
    struct stat opened, published, completed;
    int code = 0;
    if (fstat(descriptor, &opened) != 0) code = errno;
    else if (!S_ISREG(opened.st_mode)) code = EINVAL;
    else if (opened.st_nlink != 1) code = EMLINK;
    else if (opened.st_size <= 0 || opened.st_size > GXMaximumTransactionSize) code = EFBIG;
    else if (fstatat(directoryDescriptor, GXTransactionName.fileSystemRepresentation,
                     &published, AT_SYMLINK_NOFOLLOW) != 0) code = errno;
    else if (!S_ISREG(published.st_mode) || published.st_nlink != 1 ||
             !GXSameStat(&opened, &published)) code = EBUSY;

    NSMutableData *data = nil;
    if (code == 0) {
        data = [NSMutableData dataWithLength:(NSUInteger)opened.st_size];
        uint8_t *bytes = data.mutableBytes;
        size_t remaining = (size_t)opened.st_size;
        while (remaining > 0) {
            ssize_t count = read(descriptor, bytes, remaining);
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) {
                code = count == 0 ? EIO : errno;
                break;
            }
            bytes += count;
            remaining -= (size_t)count;
        }
    }
    if (code == 0 && fstat(descriptor, &completed) != 0) code = errno;
    else if (code == 0 && (!GXSameStat(&opened, &completed) ||
                           opened.st_size != completed.st_size ||
                           opened.st_mtimespec.tv_sec != completed.st_mtimespec.tv_sec ||
                           opened.st_mtimespec.tv_nsec != completed.st_mtimespec.tv_nsec)) code = EBUSY;
    if (code == 0 && fstatat(directoryDescriptor, GXTransactionName.fileSystemRepresentation,
                             &published, AT_SYMLINK_NOFOLLOW) != 0) code = errno;
    else if (code == 0 && !GXSameStat(&opened, &published)) code = EBUSY;
    if (close(descriptor) != 0 && code == 0) code = errno;
    if (code != 0) {
        GXFail(error, code, url);
        return nil;
    }

    NSError *readError = nil;
    id value = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable
                                                          format:nil error:&readError];
    if (![value isKindOfClass:NSDictionary.class]) {
        if (error) *error = readError ?: GXCacheError(EINVAL, url);
        return nil;
    }
    *identity = opened;
    return value;
}

static BOOL GXValidUUID(NSString *value) {
    if (![value isKindOfClass:NSString.class]) return NO;
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:value];
    return uuid && [uuid.UUIDString caseInsensitiveCompare:value] == NSOrderedSame;
}

static BOOL GXValidRestoreName(NSString *name) {
    if (![name isKindOfClass:NSString.class] || ![name hasPrefix:GXRestorePrefix]) return NO;
    NSString *uuid = [name substringFromIndex:GXRestorePrefix.length];
    return GXValidUUID(uuid) && [name.lastPathComponent isEqualToString:name];
}

static void GXTestCrash(NSString *stage);

static NSString *GXRestoreMarkerName(NSString *token) {
    return [GXRestoreMarkerPrefix stringByAppendingString:token];
}

static BOOL GXRegularDataMatchesAt(int directoryDescriptor, NSString *name, NSURL *url,
                                   NSData *expected, struct stat *identity,
                                   NSError **error) {
    int descriptor = openat(directoryDescriptor, name.fileSystemRepresentation,
                            O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (descriptor < 0) return GXFail(error, errno, url);
    struct stat opened, published, completed;
    int code = 0;
    if (fstat(descriptor, &opened) != 0) code = errno;
    else if (!S_ISREG(opened.st_mode) || opened.st_nlink != 1) code = EBUSY;
    else if (opened.st_size != (off_t)expected.length) code = EINVAL;
    else if (fstatat(directoryDescriptor, name.fileSystemRepresentation, &published,
                     AT_SYMLINK_NOFOLLOW) != 0) code = errno;
    else if (!S_ISREG(published.st_mode) || published.st_nlink != 1 ||
             !GXSameStat(&opened, &published)) code = EBUSY;
    NSMutableData *actual = nil;
    if (code == 0) {
        actual = [NSMutableData dataWithLength:expected.length];
        uint8_t *bytes = actual.mutableBytes;
        size_t remaining = actual.length;
        while (remaining > 0) {
            ssize_t count = read(descriptor, bytes, remaining);
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) {
                code = count == 0 ? EIO : errno;
                break;
            }
            bytes += count;
            remaining -= (size_t)count;
        }
    }
    if (code == 0 && fstat(descriptor, &completed) != 0) code = errno;
    else if (code == 0 && (!GXSameStat(&opened, &completed) ||
                           opened.st_size != completed.st_size ||
                           opened.st_mtimespec.tv_sec != completed.st_mtimespec.tv_sec ||
                           opened.st_mtimespec.tv_nsec != completed.st_mtimespec.tv_nsec)) code = EBUSY;
    if (code == 0 && fstatat(directoryDescriptor, name.fileSystemRepresentation,
                             &published, AT_SYMLINK_NOFOLLOW) != 0) code = errno;
    else if (code == 0 && !GXSameStat(&opened, &published)) code = EBUSY;
    if (close(descriptor) != 0 && code == 0) code = errno;
    if (code != 0) return GXFail(error, code, url);
    if (![actual isEqual:expected]) return GXFail(error, EINVAL, url);
    if (identity) *identity = opened;
    return YES;
}

static BOOL GXValidRestoreMarkerTempName(NSString *name) {
    if (![name hasPrefix:GXRestoreMarkerTempPrefix]) return NO;
    NSString *suffix = [name substringFromIndex:GXRestoreMarkerTempPrefix.length];
    NSArray<NSString *> *parts = [suffix componentsSeparatedByString:@"."];
    return parts.count == 2 && GXValidUUID(parts[0]) && GXValidUUID(parts[1]);
}

static BOOL GXCleanupRestoreMarkerTemps(int directoryDescriptor, NSURL *directory,
                                        NSError **error) {
    NSArray<NSString *> *items = GXDirectoryItems(directoryDescriptor, directory, error);
    if (!items) return NO;
    for (NSString *name in items) {
        if (![name hasPrefix:GXRestoreMarkerTempPrefix]) continue;
        NSURL *url = [directory URLByAppendingPathComponent:name];
        if (!GXValidRestoreMarkerTempName(name)) return GXFail(error, EBUSY, url);
        struct stat info;
        BOOL exists = NO;
        if (!GXStatAt(directoryDescriptor, name, url, &info, &exists, error)) return NO;
        if (!exists) continue;
        if (!S_ISREG(info.st_mode) || info.st_nlink != 1 || info.st_uid != geteuid() ||
            (info.st_mode & 0777) != 0600 || info.st_size < 0 || info.st_size > 36) {
            return GXFail(error, EBUSY, url);
        }
        if (!GXRemoveExpectedRegularAt(directoryDescriptor, name, url, &info,
                                       directory, error)) return NO;
    }
    return YES;
}

static BOOL GXPublishRestoreMarker(int directoryDescriptor, NSURL *directory,
                                   NSString *token, NSError **error) {
    NSString *markerName = GXRestoreMarkerName(token);
    NSURL *markerURL = [directory URLByAppendingPathComponent:markerName];
    NSString *temporaryName = [NSString stringWithFormat:@"%@%@.%@",
                               GXRestoreMarkerTempPrefix, token, NSUUID.UUID.UUIDString];
    NSURL *temporaryURL = [directory URLByAppendingPathComponent:temporaryName];
    int descriptor = openat(directoryDescriptor, temporaryName.fileSystemRepresentation,
                            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (descriptor < 0) return GXFail(error, errno, temporaryURL);
    struct stat created;
    memset(&created, 0, sizeof(created));
    BOOL identified = fstat(descriptor, &created) == 0;
    int code = identified ? 0 : errno;
    if (code == 0 && fchmod(descriptor, 0600) != 0) code = errno;
    NSData *data = [token dataUsingEncoding:NSUTF8StringEncoding];
    if (code == 0) (void)GXWriteAll(descriptor, data, &code);
    if (code == 0 && fsync(descriptor) != 0) code = errno;
    if (close(descriptor) != 0 && code == 0) code = errno;
    if (code != 0) {
        if (identified) (void)GXRemoveExpectedRegularAt(directoryDescriptor, temporaryName,
                                                        temporaryURL, &created, directory, nil);
        return GXFail(error, code, temporaryURL);
    }
    GXTestCrash(@"after-marker-temp");
    if (renameatx_np(directoryDescriptor, temporaryName.fileSystemRepresentation,
                     directoryDescriptor, markerName.fileSystemRepresentation,
                     RENAME_EXCL) != 0) {
        code = errno;
        (void)GXRemoveExpectedRegularAt(directoryDescriptor, temporaryName, temporaryURL,
                                        &created, directory, nil);
        return GXFail(error, code, markerURL);
    }
    struct stat published;
    if (!GXRegularDataMatchesAt(directoryDescriptor, markerName, markerURL,
                                data, &published, error) || !GXSameStat(&created, &published)) {
        return GXFail(error, EBUSY, markerURL);
    }
    return GXSyncDirectoryDescriptor(directoryDescriptor, directory, error);
}

static BOOL GXOpenVerifiedRestoreDirectory(int parentDescriptor, NSString *name,
                                           NSURL *directory, NSString *token,
                                           int *directoryDescriptor,
                                           struct stat *directoryIdentity,
                                           struct stat *markerIdentity,
                                           NSError **error) {
    if (!GXOpenDirectoryAt(parentDescriptor, name, directory, directoryDescriptor,
                           directoryIdentity, error)) return NO;
    NSArray<NSString *> *items = GXDirectoryItems(*directoryDescriptor, directory, error);
    NSString *markerName = GXRestoreMarkerName(token);
    if (!items || items.count != 1 || ![items.firstObject isEqualToString:markerName]) {
        close(*directoryDescriptor);
        *directoryDescriptor = -1;
        if (items) GXFail(error, EBUSY, directory);
        return NO;
    }
    NSURL *markerURL = [directory URLByAppendingPathComponent:markerName];
    NSData *expected = [token dataUsingEncoding:NSUTF8StringEncoding];
    if (!GXRegularDataMatchesAt(*directoryDescriptor, markerName, markerURL,
                                expected, markerIdentity, error)) {
        close(*directoryDescriptor);
        *directoryDescriptor = -1;
        return NO;
    }
    return YES;
}

static BOOL GXRestoreDirectoryMatchesAt(int parentDescriptor, NSString *name,
                                        NSURL *directory, NSString *token,
                                        NSError **error) {
    int descriptor = -1;
    struct stat directoryIdentity, markerIdentity;
    BOOL matches = GXOpenVerifiedRestoreDirectory(parentDescriptor, name, directory, token,
                                                   &descriptor, &directoryIdentity,
                                                   &markerIdentity, error);
    if (descriptor >= 0) close(descriptor);
    return matches;
}

static BOOL GXEnsureRestoreDirectoryAt(int parentDescriptor, NSString *name,
                                       NSURL *directory, NSString *token,
                                       NSURL *parentURL, NSError **error) {
    struct stat info;
    BOOL exists = NO;
    if (!GXStatAt(parentDescriptor, name, directory, &info, &exists, error)) return NO;
    if (!exists) {
        if (mkdirat(parentDescriptor, name.fileSystemRepresentation, 0700) != 0) {
            return GXFail(error, errno, directory);
        }
        if (!GXSyncDirectoryDescriptor(parentDescriptor, parentURL, error)) return NO;
    } else if (!S_ISDIR(info.st_mode)) {
        return GXFail(error, EBUSY, directory);
    }
    int descriptor = -1;
    struct stat opened;
    if (!GXOpenDirectoryAt(parentDescriptor, name, directory, &descriptor, &opened, error)) return NO;
    BOOL success = NO;
    @try {
        if (opened.st_uid != geteuid() || (opened.st_mode & 0777) != 0700) {
            GXFail(error, EBUSY, directory);
            return NO;
        }
        if (!GXCleanupRestoreMarkerTemps(descriptor, directory, error)) return NO;
        NSArray<NSString *> *items = GXDirectoryItems(descriptor, directory, error);
        if (!items) return NO;
        NSString *markerName = GXRestoreMarkerName(token);
        if (items.count == 0) {
            if (!GXPublishRestoreMarker(descriptor, directory, token, error)) return NO;
        } else if (items.count != 1 || ![items.firstObject isEqualToString:markerName]) {
            return GXFail(error, EBUSY, directory);
        }
        NSURL *markerURL = [directory URLByAppendingPathComponent:markerName];
        NSData *expected = [token dataUsingEncoding:NSUTF8StringEncoding];
        struct stat markerIdentity;
        if (!GXRegularDataMatchesAt(descriptor, markerName, markerURL,
                                    expected, &markerIdentity, error)) return NO;
        struct stat published;
        if (fstatat(parentDescriptor, name.fileSystemRepresentation, &published,
                    AT_SYMLINK_NOFOLLOW) != 0 || !GXSameStat(&opened, &published)) {
            return GXFail(error, EBUSY, directory);
        }
        success = YES;
    } @finally {
        close(descriptor);
    }
    return success;
}

static BOOL GXRemoveRestoreMarkerAt(int parentDescriptor, NSString *name,
                                    NSURL *directory, NSString *token,
                                    NSError **error) {
    int descriptor = -1;
    struct stat directoryIdentity, markerIdentity;
    if (!GXOpenVerifiedRestoreDirectory(parentDescriptor, name, directory, token,
                                         &descriptor, &directoryIdentity,
                                         &markerIdentity, error)) return NO;
    NSString *markerName = GXRestoreMarkerName(token);
    NSURL *markerURL = [directory URLByAppendingPathComponent:markerName];
    BOOL removed = GXRemoveExpectedRegularAt(descriptor, markerName, markerURL,
                                             &markerIdentity, directory, error);
    struct stat published;
    if (removed && (fstatat(parentDescriptor, name.fileSystemRepresentation, &published,
                            AT_SYMLINK_NOFOLLOW) != 0 ||
                    !GXSameStat(&directoryIdentity, &published))) {
        removed = GXFail(error, EBUSY, directory);
    }
    close(descriptor);
    return removed;
}

static BOOL GXCleanupOrphanRestoreMarkerAt(int parentDescriptor, NSString *cacheName,
                                           NSURL *caches, NSError **error) {
    struct stat before;
    BOOL exists = NO;
    if (!GXStatAt(parentDescriptor, cacheName, caches, &before, &exists, error)) return NO;
    if (!exists || !S_ISDIR(before.st_mode)) return YES;
    int descriptor = -1;
    struct stat opened;
    if (!GXOpenDirectoryAt(parentDescriptor, cacheName, caches, &descriptor, &opened, error)) return NO;
    NSArray<NSString *> *items = GXDirectoryItems(descriptor, caches, error);
    close(descriptor);
    if (!items) return NO;
    if (items.count != 1 || ![items.firstObject hasPrefix:GXRestoreMarkerPrefix]) return YES;
    NSString *token = [items.firstObject substringFromIndex:GXRestoreMarkerPrefix.length];
    if (!GXValidUUID(token)) return YES;
    return GXRemoveRestoreMarkerAt(parentDescriptor, cacheName, caches, token, error);
}

static NSArray<NSString *> *GXLegacyBackups(int directoryDescriptor, NSURL *directory,
                                            NSError **error) {
    NSArray<NSString *> *items = GXDirectoryItems(directoryDescriptor, directory, error);
    if (!items) return nil;
    NSMutableArray<NSString *> *backups = [NSMutableArray array];
    NSString *prefix = @".GestaltX-Caches-";
    NSString *suffix = @".backup";
    for (NSString *name in items) {
        if (![name hasPrefix:prefix] || ![name hasSuffix:suffix]) continue;
        NSUInteger start = prefix.length;
        NSUInteger length = name.length - start - suffix.length;
        if (length == 0) continue;
        NSString *token = [name substringWithRange:NSMakeRange(start, length)];
        if (GXValidUUID(token)) [backups addObject:name];
    }
    return backups;
}

#if GESTALTX_TESTING
static void GXTestCrash(NSString *stage) {
    const char *requested = getenv("GESTALTX_CACHE_TEST_CRASH_STAGE");
    if (requested && [stage isEqualToString:[NSString stringWithUTF8String:requested]]) _exit(97);
}
#else
static void GXTestCrash(NSString *stage) { (void)stage; }
#endif

static BOOL GXRecoverTransaction(int directoryDescriptor, NSURL *directoryURL,
                                 NSURL *caches, NSString *cacheName, NSString *target,
                                 NSDictionary *record, const struct stat *transactionIdentity,
                                 NSError **error) {
    NSURL *backup = GXNeighbor(caches, GXBackupName);
    NSURL *staging = GXNeighbor(caches, GXLinkName);
    NSURL *transaction = GXNeighbor(caches, GXTransactionName);
    NSNumber *version = record[@"version"], *hadOriginal = record[@"hadOriginal"];
    NSString *cachePath = record[@"cachePath"], *savedTarget = record[@"target"];
    NSNumber *originalDevice = record[@"originalDevice"], *originalInode = record[@"originalInode"];
    NSNumber *linkDevice = record[@"linkDevice"], *linkInode = record[@"linkInode"];
    NSString *restoreName = record[@"restoreName"], *recoveryToken = record[@"recoveryToken"];
    if (![version isKindOfClass:NSNumber.class] ||
        (version.integerValue != 1 && version.integerValue != 2) ||
        ![hadOriginal isKindOfClass:NSNumber.class] ||
        ![cachePath isKindOfClass:NSString.class] || ![cachePath isEqualToString:caches.path] ||
        ![savedTarget isKindOfClass:NSString.class] || ![savedTarget isEqualToString:target] ||
        ![linkDevice isKindOfClass:NSNumber.class] || ![linkInode isKindOfClass:NSNumber.class] ||
        (hadOriginal.boolValue &&
         (![originalDevice isKindOfClass:NSNumber.class] || ![originalInode isKindOfClass:NSNumber.class])) ||
        (!hadOriginal.boolValue &&
         (version.integerValue != 2 || !GXValidRestoreName(restoreName) ||
          !GXValidUUID(recoveryToken)))) {
        return GXFail(error, EINVAL, transaction);
    }

    unsigned long long originalDev = originalDevice.unsignedLongLongValue;
    unsigned long long originalIno = originalInode.unsignedLongLongValue;
    unsigned long long linkDev = linkDevice.unsignedLongLongValue;
    unsigned long long linkIno = linkInode.unsignedLongLongValue;
    NSURL *restore = hadOriginal.boolValue ? nil : GXNeighbor(caches, restoreName);
    struct stat currentInfo, backupInfo, stagingInfo, restoreInfo;
    BOOL currentExists = NO, backupExists = NO, stagingExists = NO, restoreExists = NO;
    if (!GXStatAt(directoryDescriptor, cacheName, caches, &currentInfo, &currentExists, error) ||
        !GXStatAt(directoryDescriptor, GXBackupName, backup, &backupInfo, &backupExists, error) ||
        !GXStatAt(directoryDescriptor, GXLinkName, staging, &stagingInfo, &stagingExists, error) ||
        (restore && !GXStatAt(directoryDescriptor, restoreName, restore,
                              &restoreInfo, &restoreExists, error))) return NO;

    BOOL currentIsOriginal = hadOriginal.boolValue && currentExists &&
                             GXSameItem(&currentInfo, originalDev, originalIno);
    if (currentIsOriginal) {
        if (backupExists) return GXFail(error, EBUSY, backup);
        if (stagingExists &&
            !GXRemoveExpectedLinkAt(directoryDescriptor, GXLinkName, staging, target,
                                    linkDev, linkIno, YES, directoryURL, error)) return NO;
        return GXRemoveExpectedRegularAt(directoryDescriptor, GXTransactionName,
                                         transaction, transactionIdentity,
                                         directoryURL, error);
    }

    if (!hadOriginal.boolValue && currentExists && !backupExists && !stagingExists &&
        !restoreExists && GXRestoreDirectoryMatchesAt(directoryDescriptor, cacheName,
                                                       caches, recoveryToken, nil)) {
        if (!GXRemoveExpectedRegularAt(directoryDescriptor, GXTransactionName,
                                       transaction, transactionIdentity,
                                       directoryURL, error)) return NO;
        GXTestCrash(@"after-transaction-remove");
        return GXRemoveRestoreMarkerAt(directoryDescriptor, cacheName,
                                       caches, recoveryToken, error);
    }

    if (currentExists &&
        !GXLinkMatchesAt(directoryDescriptor, cacheName, caches, target,
                         linkDev, linkIno, YES, nil)) {
        return GXFail(error, EBUSY, caches);
    }
    if (stagingExists &&
        !GXLinkMatchesAt(directoryDescriptor, GXLinkName, staging, target,
                         linkDev, linkIno, YES, nil)) {
        return GXFail(error, EBUSY, staging);
    }
    if (hadOriginal.boolValue) {
        if (!backupExists || !GXSameItem(&backupInfo, originalDev, originalIno)) {
            return GXFail(error, EBUSY, backup);
        }
    } else if (backupExists) {
        return GXFail(error, EBUSY, backup);
    } else {
        if (!GXEnsureRestoreDirectoryAt(directoryDescriptor, restoreName, restore,
                                        recoveryToken, directoryURL, error)) return NO;
        if (!GXStatAt(directoryDescriptor, restoreName, restore,
                      &restoreInfo, &restoreExists, error) || !restoreExists) {
            return GXFail(error, EBUSY, restore);
        }
    }

    if (currentExists &&
        !GXRemoveExpectedLinkAt(directoryDescriptor, cacheName, caches, target,
                                linkDev, linkIno, YES, directoryURL, error)) return NO;
    if (stagingExists &&
        !GXRemoveExpectedLinkAt(directoryDescriptor, GXLinkName, staging, target,
                                linkDev, linkIno, YES, directoryURL, error)) return NO;
    if (hadOriginal.boolValue) {
        if (!GXRenameExpectedAt(directoryDescriptor, GXBackupName, backup,
                                cacheName, caches, &backupInfo,
                                directoryURL, error)) return NO;
        struct stat restored;
        BOOL restoredExists = NO;
        if (!GXStatAt(directoryDescriptor, cacheName, caches,
                      &restored, &restoredExists, error) || !restoredExists ||
            !GXSameItem(&restored, originalDev, originalIno)) return GXFail(error, EIO, caches);
    } else {
        if (!GXRenameExpectedAt(directoryDescriptor, restoreName, restore,
                                cacheName, caches, &restoreInfo,
                                directoryURL, error)) return NO;
        GXTestCrash(@"after-recreate");
        if (!GXRemoveExpectedRegularAt(directoryDescriptor, GXTransactionName,
                                       transaction, transactionIdentity,
                                       directoryURL, error)) return NO;
        GXTestCrash(@"after-transaction-remove");
        return GXRemoveRestoreMarkerAt(directoryDescriptor, cacheName,
                                       caches, recoveryToken, error);
    }
    return GXRemoveExpectedRegularAt(directoryDescriptor, GXTransactionName,
                                     transaction, transactionIdentity,
                                     directoryURL, error);
}

static BOOL GXRecoverTemporaryCacheLinkUnlocked(NSURL *caches, NSString *target,
                                                const GXCacheLock *lock,
                                                NSError **error) {
    int directoryDescriptor = lock->directoryDescriptor;
    NSURL *directoryURL = caches.URLByDeletingLastPathComponent;
    NSString *cacheName = caches.lastPathComponent;
    if (!GXValidChildName(cacheName)) return GXFail(error, EINVAL, caches);
    NSURL *backup = GXNeighbor(caches, GXBackupName);
    NSURL *staging = GXNeighbor(caches, GXLinkName);
    NSURL *transaction = GXNeighbor(caches, GXTransactionName);
    if (!GXRejectIsolationArtifacts(directoryDescriptor, directoryURL, error) ||
        !GXCleanupTransactionTemps(directoryDescriptor, directoryURL, error)) return NO;
    struct stat info; BOOL transactionExists = NO;
    if (!GXStatAt(directoryDescriptor, GXTransactionName, transaction,
                  &info, &transactionExists, error)) return NO;
    if (transactionExists) {
        if (!S_ISREG(info.st_mode) || info.st_nlink != 1) return GXFail(error, EINVAL, transaction);
        struct stat transactionIdentity;
        NSDictionary *record = GXReadTransactionAt(directoryDescriptor, transaction,
                                                   &transactionIdentity, error);
        return record && GXRecoverTransaction(directoryDescriptor, directoryURL,
                                               caches, cacheName, target, record,
                                               &transactionIdentity, error);
    }

    BOOL backupExists = NO, stagingExists = NO;
    struct stat backupInfo, stagingInfo;
    if (!GXStatAt(directoryDescriptor, GXBackupName, backup,
                  &backupInfo, &backupExists, error) ||
        !GXStatAt(directoryDescriptor, GXLinkName, staging,
                  &stagingInfo, &stagingExists, error)) return NO;
    if (backupExists) return GXFail(error, EBUSY, backup);
    if (stagingExists) return GXFail(error, EBUSY, staging);
    if (!GXCleanupOrphanRestoreMarkerAt(directoryDescriptor, cacheName, caches, error)) return NO;

    NSArray<NSString *> *legacy = GXLegacyBackups(directoryDescriptor, directoryURL, error);
    if (!legacy) return NO;
    if (legacy.count > 0) {
        return GXFail(error, EBUSY, [directoryURL URLByAppendingPathComponent:legacy.firstObject]);
    }
    struct stat currentInfo; BOOL currentExists = NO;
    if (!GXStatAt(directoryDescriptor, cacheName, caches,
                  &currentInfo, &currentExists, error)) return NO;
    if (currentExists && GXLinkMatchesAt(directoryDescriptor, cacheName, caches,
                                         target, 0, 0, NO, nil)) {
        // A pre-transaction v1.0.5 link has no durable inode proof. Preserve it
        // and require manual recovery rather than deleting an unowned link.
        return GXFail(error, EBUSY, caches);
    }
    return YES;
}

BOOL GXRecoverTemporaryCacheLink(NSURL *caches, NSString *target, NSError **error) {
    if (error) *error = nil;
    if (!caches.isFileURL || target.length == 0) return GXFail(error, EINVAL, caches);
    GXCacheLock lock;
    if (!GXAcquireLock(caches, &lock, error)) return NO;
    BOOL recovered = NO;
    BOOL lockValid = NO;
    NSError *lockError = nil;
    @try {
        recovered = GXRecoverTemporaryCacheLinkUnlocked(caches, target, &lock, error);
    } @finally {
        lockValid = GXValidateLock(caches, &lock, &lockError);
        GXReleaseLock(&lock);
    }
    if (!lockValid && error) *error = lockError;
    return recovered && lockValid;
}

static BOOL GXWithTemporaryCacheLinkLocked(NSURL *caches, NSString *target,
                                           int64_t (^operation)(void), int64_t *result,
                                           const GXCacheLock *lock,
                                           NSError **error) {
    if (error) *error = nil;
    if (!caches.isFileURL || target.length == 0 || !operation || !result) {
        return GXFail(error, EINVAL, caches);
    }

    int directoryDescriptor = lock->directoryDescriptor;
    NSURL *directoryURL = caches.URLByDeletingLastPathComponent;
    NSString *cacheName = caches.lastPathComponent;
    if (!GXValidChildName(cacheName)) return GXFail(error, EINVAL, caches);

    NSError *recoveryError = nil;
    if (!GXRecoverTemporaryCacheLinkUnlocked(caches, target, lock, &recoveryError)) {
        if (error) *error = recoveryError;
        return NO;
    }

    NSURL *backup = GXNeighbor(caches, GXBackupName);
    NSURL *staging = GXNeighbor(caches, GXLinkName);
    NSURL *transaction = GXNeighbor(caches, GXTransactionName);
    NSString *restoreName = [GXRestorePrefix stringByAppendingString:NSUUID.UUID.UUIDString];
    NSString *recoveryToken = NSUUID.UUID.UUIDString;
    NSURL *restore = GXNeighbor(caches, restoreName);
    struct stat original;
    BOOL existed = NO;
    if (!GXStatAt(directoryDescriptor, cacheName, caches,
                  &original, &existed, error)) return NO;

    if (symlinkat(target.fileSystemRepresentation, directoryDescriptor,
                  GXLinkName.fileSystemRepresentation) != 0) {
        return GXFail(error, errno, staging);
    }
    struct stat installedLink;
    memset(&installedLink, 0, sizeof(installedLink));
    int stagingCode = 0;
    if (fstatat(directoryDescriptor, GXLinkName.fileSystemRepresentation,
                &installedLink, AT_SYMLINK_NOFOLLOW) != 0) stagingCode = errno;
    else if (!S_ISLNK(installedLink.st_mode) || installedLink.st_nlink != 1) stagingCode = EBUSY;
    if (stagingCode != 0) {
        if (installedLink.st_ino != 0) {
            (void)GXRemoveExpectedLinkAt(directoryDescriptor, GXLinkName, staging, target,
                                         (unsigned long long)installedLink.st_dev,
                                         (unsigned long long)installedLink.st_ino,
                                         YES, directoryURL, nil);
        }
        return GXFail(error, stagingCode, staging);
    }

    NSMutableDictionary *record = [@{
        @"version": @2,
        @"cachePath": caches.path,
        @"target": target,
        @"hadOriginal": @(existed),
        @"linkDevice": @((unsigned long long)installedLink.st_dev),
        @"linkInode": @((unsigned long long)installedLink.st_ino),
    } mutableCopy];
    if (existed) {
        record[@"originalDevice"] = @((unsigned long long)original.st_dev);
        record[@"originalInode"] = @((unsigned long long)original.st_ino);
    } else {
        record[@"restoreName"] = restoreName;
        record[@"recoveryToken"] = recoveryToken;
    }

    NSError *transactionError = nil;
    struct stat transactionIdentity;
    if (!GXWriteTransactionAt(directoryDescriptor, directoryURL, transaction,
                              record, &transactionIdentity, &transactionError)) {
        NSError *cleanupError = nil;
        if (transactionIdentity.st_ino != 0 &&
            GXRegularFileMatchesAt(directoryDescriptor, GXTransactionName,
                                   transaction, &transactionIdentity, &cleanupError)) {
            (void)GXRecoverTemporaryCacheLinkUnlocked(caches, target, lock, &cleanupError);
        } else {
            cleanupError = nil;
            (void)GXRemoveExpectedLinkAt(directoryDescriptor, GXLinkName, staging, target,
                                         (unsigned long long)installedLink.st_dev,
                                         (unsigned long long)installedLink.st_ino,
                                         YES, directoryURL, &cleanupError);
        }
        if (error) *error = cleanupError ?: transactionError;
        return NO;
    }

    GXTestCrash(@"after-transaction");
    NSError *setupError = nil;
    NSError *restoreError = nil;
    BOOL invoked = NO;
    @try {
        struct stat current;
        BOOL currentExists = NO;
        if (!GXStatAt(directoryDescriptor, cacheName, caches,
                      &current, &currentExists, &setupError)) {
            // The recovery in finally preserves all evidence when identity is
            // uncertain.
        } else if (existed &&
                   (!currentExists || !GXSameItem(&current,
                                                  (unsigned long long)original.st_dev,
                                                  (unsigned long long)original.st_ino))) {
            setupError = GXCacheError(EBUSY, caches);
        } else if (!existed && currentExists) {
            setupError = GXCacheError(EBUSY, caches);
        } else if (existed &&
                   !GXRenameExpectedAt(directoryDescriptor, cacheName, caches,
                                       GXBackupName, backup, &original,
                                       directoryURL, &setupError)) {
            // Recovery restores the moved original.
        } else if (!existed &&
                   !GXEnsureRestoreDirectoryAt(directoryDescriptor, restoreName, restore,
                                               recoveryToken, directoryURL, &setupError)) {
            // Recovery retains the transaction if the restore directory is uncertain.
        } else {
            if (existed) GXTestCrash(@"after-move");
            else GXTestCrash(@"after-restore");
            if (!GXLinkMatchesAt(directoryDescriptor, GXLinkName, staging, target,
                                 (unsigned long long)installedLink.st_dev,
                                 (unsigned long long)installedLink.st_ino,
                                 YES, nil)) {
                setupError = GXCacheError(EBUSY, staging);
            } else if (!GXRenameExpectedAt(directoryDescriptor, GXLinkName, staging,
                                           cacheName, caches, &installedLink,
                                           directoryURL, &setupError)) {
                // Recovery removes the installed link and restores Caches.
            } else if (!GXValidateLock(caches, lock, &setupError)) {
                // Do not invoke the operation through a replaced parent path.
            } else {
                GXTestCrash(@"after-link");
                *result = operation();
                invoked = YES;
            }
        }
    } @finally {
        if (!GXRegularFileMatchesAt(directoryDescriptor, GXTransactionName,
                                    transaction, &transactionIdentity, &restoreError)) {
            // A same-path replacement is not our transaction. Leave every
            // recovery artifact untouched for a later audited repair.
        } else if (!GXRecoverTemporaryCacheLinkUnlocked(caches, target, lock, &restoreError)) {
            // Preserve the fixed backup and transaction for the next launch.
        }
    }

    if (error) *error = restoreError ?: setupError;
    return invoked && setupError == nil && restoreError == nil;
}

BOOL GXWithTemporaryCacheLink(NSURL *caches, NSString *target,
                              int64_t (^operation)(void), int64_t *result,
                              NSError **error) {
    if (error) *error = nil;
    if (!caches.isFileURL || target.length == 0 || !operation || !result) {
        return GXFail(error, EINVAL, caches);
    }
    GXCacheLock lock;
    if (!GXAcquireLock(caches, &lock, error)) return NO;
    BOOL restored = NO;
    BOOL lockValid = NO;
    NSError *lockError = nil;
    @try {
        restored = GXWithTemporaryCacheLinkLocked(caches, target, operation, result,
                                                   &lock, error);
    } @finally {
        lockValid = GXValidateLock(caches, &lock, &lockError);
        GXReleaseLock(&lock);
    }
    if (!lockValid && error) *error = lockError;
    return restored && lockValid;
}
