// SPDX-License-Identifier: GPL-3.0-only
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Recover a cache-directory exchange interrupted by process termination. This
// also detects the random backup names used by GestaltX 1.0.5 and preserves
// pre-transaction evidence when ownership cannot be proven.
BOOL GXRecoverTemporaryCacheLink(NSURL *caches, NSString *target,
                                 NSError * _Nullable * _Nullable error);

// Temporarily replace Caches with a link, preserving the original item. The
// operation's result is separate from setup/restoration success.
BOOL GXWithTemporaryCacheLink(NSURL *caches, NSString *target,
                              int64_t (^operation)(void), int64_t *result,
                              NSError * _Nullable * _Nullable error);
NS_ASSUME_NONNULL_END
