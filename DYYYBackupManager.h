#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, DYYYBackupRestoreMode) {
    DYYYBackupRestoreModeMerge = 0,
    DYYYBackupRestoreModeReplace = 1,
};

@interface DYYYBackupManager : NSObject

+ (BOOL)containsSensitiveCredentials;
+ (BOOL)createBackupAtURL:(NSURL *)destinationURL
    includeSensitiveCredentials:(BOOL)includeSensitiveCredentials
                         summary:(NSDictionary *_Nullable *_Nullable)summary
                           error:(NSError **)error;
+ (nullable NSDictionary *)inspectBackupAtURL:(NSURL *)sourceURL error:(NSError **)error;
+ (BOOL)restoreBackupAtURL:(NSURL *)sourceURL mode:(DYYYBackupRestoreMode)mode summary:(NSDictionary *_Nullable *_Nullable)summary error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
