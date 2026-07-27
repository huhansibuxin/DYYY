#import "DYYYBackupManager.h"

#import <CommonCrypto/CommonDigest.h>
#include <compression.h>
#include <string.h>

static NSString *const DYYYBackupErrorDomain = @"com.dyyy.backup";
static NSString *const DYYYBackupFormatIdentifier = @"com.dyyy.settings-backup";
static NSInteger const DYYYBackupFormatVersion = 3;
static NSUInteger const DYYYBackupHeaderLength = 52;
static NSUInteger const DYYYBackupMaximumEntryCount = 20000;
static NSUInteger const DYYYBackupMaximumArchiveSize = 512ULL * 1024ULL * 1024ULL;
static NSUInteger const DYYYBackupMaximumExpandedSize = 512ULL * 1024ULL * 1024ULL;
static NSUInteger const DYYYBackupMaximumResourceSize = 128ULL * 1024ULL * 1024ULL;
static const unsigned char DYYYBackupMagic[8] = { 'D', 'Y', 'Y', 'Y', 'B', 'K', 'P', '3' };

#pragma mark - Error helpers

static NSError *DYYYBackupError(NSInteger code, NSString *description) {
    return [NSError errorWithDomain:DYYYBackupErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey : description ?: @"未知错误"}];
}

static BOOL DYYYSetBackupError(NSError **error, NSInteger code, NSString *description) {
    if (error) {
        *error = DYYYBackupError(code, description);
    }
    return NO;
}

#pragma mark - Scope registry

static NSArray<NSString *> *DYYYBackupIconFileNames(void) {
    return @[ @"like_before.png", @"like_after.png", @"comment.png", @"unfavorite.png", @"favorite.png", @"share.png", @"tab_plus.png", @"qingping.gif" ];
}

static NSSet<NSString *> *DYYYBackupTransientPreferenceKeys(void) {
    static NSSet<NSString *> *keys = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      keys = [NSSet setWithArray:@[
          @"DYYYTimerShutdownTime",
          @"DYYYUserAgreementAccepted",
          @"DYYYHDRModeMigratedV1",
          @"DYYYIconsBase64",
          @"DYYYBackupSettings",
          @"DYYYRestoreSettings"
      ]];
    });
    return keys;
}

static BOOL DYYYBackupIsTransientPreferenceKey(NSString *key) {
    return [DYYYBackupTransientPreferenceKeys() containsObject:key];
}

static BOOL DYYYBackupIsAllowedPreferenceKey(NSString *key) {
    if (![key isKindOfClass:NSString.class] || key.length == 0 || key.length > 256) {
        return NO;
    }
    return [key hasPrefix:@"DYYY"] && !DYYYBackupIsTransientPreferenceKey(key);
}

static BOOL DYYYBackupValidatePropertyListValue(id value, NSUInteger depth) {
    if (!value || value == NSNull.null || depth > 32) {
        return NO;
    }
    if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class] || [value isKindOfClass:NSData.class] || [value isKindOfClass:NSDate.class]) {
        return YES;
    }
    if ([value isKindOfClass:NSArray.class]) {
        for (id child in value) {
            if (!DYYYBackupValidatePropertyListValue(child, depth + 1)) {
                return NO;
            }
        }
        return YES;
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        for (id key in value) {
            if (![key isKindOfClass:NSString.class] || [(NSString *)key length] == 0 || !DYYYBackupValidatePropertyListValue(value[key], depth + 1)) {
                return NO;
            }
        }
        return YES;
    }
    return NO;
}

#pragma mark - Paths and files

static NSString *DYYYBackupDocumentsPath(void) {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

static NSString *DYYYBackupDYYYDirectory(void) {
    return [DYYYBackupDocumentsPath() stringByAppendingPathComponent:@"DYYY"];
}

static BOOL DYYYBackupFileIsRegularAndNotSymlink(NSURL *url) {
    NSNumber *regular = nil;
    NSNumber *symbolicLink = nil;
    [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
    [url getResourceValue:&symbolicLink forKey:NSURLIsSymbolicLinkKey error:nil];
    return regular.boolValue && !symbolicLink.boolValue;
}

static NSData *DYYYBackupReadResource(NSString *path, NSError **error) {
    NSURL *url = [NSURL fileURLWithPath:path];
    if (!DYYYBackupFileIsRegularAndNotSymlink(url)) {
        return nil;
    }
    NSNumber *fileSize = nil;
    if (![url getResourceValue:&fileSize forKey:NSURLFileSizeKey error:error] || !fileSize) {
        return nil;
    }
    if (fileSize.unsignedLongLongValue > DYYYBackupMaximumResourceSize) {
        DYYYSetBackupError(error, 10, [NSString stringWithFormat:@"资源文件过大：%@", path.lastPathComponent]);
        return nil;
    }
    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:error];
    if (!data || data.length != fileSize.unsignedLongLongValue) {
        if (error && !*error) {
            *error = DYYYBackupError(11, [NSString stringWithFormat:@"资源文件在备份期间发生变化：%@", path.lastPathComponent]);
        }
        return nil;
    }
    return data;
}

static BOOL DYYYBackupCopyReplacing(NSString *sourcePath, NSString *destinationPath, NSError **error) {
    NSFileManager *fileManager = NSFileManager.defaultManager;
    if (![fileManager fileExistsAtPath:sourcePath]) {
        return YES;
    }
    if (![fileManager createDirectoryAtPath:destinationPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:error]) {
        return NO;
    }
    [fileManager removeItemAtPath:destinationPath error:nil];
    return [fileManager copyItemAtPath:sourcePath toPath:destinationPath error:error];
}

#pragma mark - LZFSE envelope

static NSData *DYYYBackupLZFSECompress(NSData *source, NSError **error) {
    compression_stream stream = { 0 };
    if (compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_LZFSE) == COMPRESSION_STATUS_ERROR) {
        DYYYSetBackupError(error, 20, @"无法初始化 LZFSE 压缩器");
        return nil;
    }

    stream.src_ptr = source.bytes;
    stream.src_size = source.length;
    NSMutableData *output = [NSMutableData data];
    uint8_t buffer[64 * 1024];
    compression_status status = COMPRESSION_STATUS_OK;
    do {
        stream.dst_ptr = buffer;
        stream.dst_size = sizeof(buffer);
        status = compression_stream_process(&stream, COMPRESSION_STREAM_FINALIZE);
        NSUInteger produced = sizeof(buffer) - stream.dst_size;
        if (produced > 0) {
            [output appendBytes:buffer length:produced];
        }
        if (output.length > DYYYBackupMaximumArchiveSize) {
            compression_stream_destroy(&stream);
            DYYYSetBackupError(error, 21, @"备份压缩后体积超过限制");
            return nil;
        }
    } while (status == COMPRESSION_STATUS_OK);
    compression_stream_destroy(&stream);

    if (status != COMPRESSION_STATUS_END) {
        DYYYSetBackupError(error, 22, @"LZFSE 压缩失败");
        return nil;
    }
    return output;
}

static NSData *DYYYBackupLZFSEDecompress(NSData *compressedData, NSUInteger expandedSize, NSError **error) {
    if (expandedSize == 0 || expandedSize > DYYYBackupMaximumExpandedSize || compressedData.length == 0 || compressedData.length > DYYYBackupMaximumArchiveSize) {
        DYYYSetBackupError(error, 23, @"备份包大小超过安全限制");
        return nil;
    }
    NSMutableData *output = [NSMutableData dataWithLength:expandedSize];
    size_t decodedSize = compression_decode_buffer(output.mutableBytes, expandedSize, compressedData.bytes, compressedData.length, NULL, COMPRESSION_LZFSE);
    if (decodedSize != expandedSize) {
        DYYYSetBackupError(error, 24, @"备份包 LZFSE 解压失败");
        return nil;
    }
    return output;
}

static NSData *DYYYBackupCreateEnvelope(NSDictionary *payload, NSError **error) {
    NSData *plistData = [NSPropertyListSerialization dataWithPropertyList:payload format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!plistData) {
        return nil;
    }
    if (plistData.length == 0 || plistData.length > DYYYBackupMaximumExpandedSize) {
        DYYYSetBackupError(error, 25, @"备份数据大小超过限制");
        return nil;
    }
    NSData *compressedData = DYYYBackupLZFSECompress(plistData, error);
    if (!compressedData) {
        return nil;
    }

    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = { 0 };
    CC_SHA256(plistData.bytes, (CC_LONG)plistData.length, digest);
    uint32_t version = CFSwapInt32HostToBig((uint32_t)DYYYBackupFormatVersion);
    uint64_t expandedSize = CFSwapInt64HostToBig((uint64_t)plistData.length);
    NSMutableData *envelope = [NSMutableData dataWithCapacity:DYYYBackupHeaderLength + compressedData.length];
    [envelope appendBytes:DYYYBackupMagic length:sizeof(DYYYBackupMagic)];
    [envelope appendBytes:&version length:sizeof(version)];
    [envelope appendBytes:&expandedSize length:sizeof(expandedSize)];
    [envelope appendBytes:digest length:sizeof(digest)];
    [envelope appendData:compressedData];
    return envelope;
}

static NSDictionary *DYYYBackupReadEnvelope(NSURL *sourceURL, NSError **error) {
    if (!sourceURL.isFileURL || sourceURL.path.length == 0) {
        DYYYSetBackupError(error, 30, @"备份文件路径无效");
        return nil;
    }
    NSNumber *fileSize = nil;
    if (![sourceURL getResourceValue:&fileSize forKey:NSURLFileSizeKey error:error] || !fileSize) {
        return nil;
    }
    if (fileSize.unsignedLongLongValue < DYYYBackupHeaderLength || fileSize.unsignedLongLongValue > DYYYBackupMaximumArchiveSize + DYYYBackupHeaderLength) {
        DYYYSetBackupError(error, 31, @"备份文件大小异常");
        return nil;
    }
    NSData *envelope = [NSData dataWithContentsOfURL:sourceURL options:NSDataReadingMappedIfSafe error:error];
    if (!envelope) {
        return nil;
    }
    if (envelope.length < DYYYBackupHeaderLength || memcmp(envelope.bytes, DYYYBackupMagic, sizeof(DYYYBackupMagic)) != 0) {
        DYYYSetBackupError(error, 32, @"备份文件格式无效");
        return nil;
    }

    uint32_t encodedVersion = 0;
    uint64_t encodedExpandedSize = 0;
    memcpy(&encodedVersion, (const uint8_t *)envelope.bytes + 8, sizeof(encodedVersion));
    memcpy(&encodedExpandedSize, (const uint8_t *)envelope.bytes + 12, sizeof(encodedExpandedSize));
    uint32_t version = CFSwapInt32BigToHost(encodedVersion);
    uint64_t expandedSize = CFSwapInt64BigToHost(encodedExpandedSize);
    if (version != DYYYBackupFormatVersion || expandedSize == 0 || expandedSize > DYYYBackupMaximumExpandedSize) {
        DYYYSetBackupError(error, 33, @"备份版本不支持");
        return nil;
    }

    NSData *compressedData = [envelope subdataWithRange:NSMakeRange(DYYYBackupHeaderLength, envelope.length - DYYYBackupHeaderLength)];
    NSData *plistData = DYYYBackupLZFSEDecompress(compressedData, (NSUInteger)expandedSize, error);
    if (!plistData) {
        return nil;
    }
    unsigned char actualDigest[CC_SHA256_DIGEST_LENGTH] = { 0 };
    CC_SHA256(plistData.bytes, (CC_LONG)plistData.length, actualDigest);
    const unsigned char *expectedDigest = (const unsigned char *)envelope.bytes + 20;
    if (memcmp(actualDigest, expectedDigest, CC_SHA256_DIGEST_LENGTH) != 0) {
        DYYYSetBackupError(error, 34, @"备份完整性校验失败，文件可能已损坏或被修改");
        return nil;
    }

    NSPropertyListFormat format = NSPropertyListOpenStepFormat;
    id payload = [NSPropertyListSerialization propertyListWithData:plistData options:NSPropertyListImmutable format:&format error:error];
    if (![payload isKindOfClass:NSDictionary.class] || format != NSPropertyListBinaryFormat_v1_0) {
        DYYYSetBackupError(error, 35, @"备份二进制 plist 格式无效");
        return nil;
    }
    return payload;
}

#pragma mark - Payload collection

static BOOL DYYYBackupCollectPreferences(BOOL includeSensitiveCredentials, NSDictionary **preferences, NSDictionary **secrets, NSError **error) {
    (void)includeSensitiveCredentials;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSDictionary *allValues = defaults.dictionaryRepresentation;
    NSMutableDictionary *normalValues = [NSMutableDictionary dictionary];
    for (NSString *key in [allValues.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        if (!DYYYBackupIsAllowedPreferenceKey(key)) {
            continue;
        }
        id value = [defaults objectForKey:key];
        if (!DYYYBackupValidatePropertyListValue(value, 0)) {
            return DYYYSetBackupError(error, 40, [NSString stringWithFormat:@"设置值无法安全备份：%@", key]);
        }
        normalValues[key] = value;
    }
    if (preferences) {
        *preferences = normalValues;
    }
    if (secrets) {
        *secrets = @{};
    }
    return YES;
}

static BOOL DYYYBackupAddResourceData(NSMutableDictionary *destination, NSString *key, NSData *data, NSUInteger *entryCount, unsigned long long *totalBytes, NSError **error) {
    if (!data) {
        return NO;
    }
    if (*entryCount >= DYYYBackupMaximumEntryCount || *totalBytes + data.length > DYYYBackupMaximumExpandedSize) {
        return DYYYSetBackupError(error, 41, @"备份资源数量或大小超过安全限制");
    }
    destination[key] = data;
    (*entryCount)++;
    *totalBytes += data.length;
    return YES;
}

static NSDictionary *DYYYBackupCollectAssets(NSUInteger *resourceCount, unsigned long long *resourceBytes, NSError **error) {
    NSMutableDictionary *icons = [NSMutableDictionary dictionary];
    NSUInteger count = 0;
    unsigned long long bytes = 0;

    NSString *dyyyDirectory = DYYYBackupDYYYDirectory();
    for (NSString *fileName in DYYYBackupIconFileNames()) {
        NSString *path = [dyyyDirectory stringByAppendingPathComponent:fileName];
        if (!DYYYBackupFileIsRegularAndNotSymlink([NSURL fileURLWithPath:path])) {
            continue;
        }
        NSData *data = DYYYBackupReadResource(path, error);
        if (!data || !DYYYBackupAddResourceData(icons, fileName, data, &count, &bytes, error)) {
            return nil;
        }
    }

    NSData *abtestData = nil;
    NSString *abtestPath = [dyyyDirectory stringByAppendingPathComponent:@"abtest_data_fixed.json"];
    if (DYYYBackupFileIsRegularAndNotSymlink([NSURL fileURLWithPath:abtestPath])) {
        abtestData = DYYYBackupReadResource(abtestPath, error);
        if (!abtestData || count >= DYYYBackupMaximumEntryCount || bytes + abtestData.length > DYYYBackupMaximumExpandedSize) {
            if (error && !*error) {
                *error = DYYYBackupError(42, @"ABTest 配置大小超过限制");
            }
            return nil;
        }
        count++;
        bytes += abtestData.length;
    }

    NSMutableDictionary *assets = [@{ @"icons" : icons } mutableCopy];
    if (abtestData) {
        assets[@"abtest"] = abtestData;
    }
    if (resourceCount) {
        *resourceCount = count;
    }
    if (resourceBytes) {
        *resourceBytes = bytes;
    }
    return assets;
}

#pragma mark - Payload validation and staging

static BOOL DYYYBackupWriteStagedData(NSData *data, NSString *path, NSError **error) {
    NSFileManager *fileManager = NSFileManager.defaultManager;
    if (![fileManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:error]) {
        return NO;
    }
    return [data writeToFile:path options:NSDataWritingAtomic error:error];
}

static BOOL DYYYBackupValidateAndStageAssets(NSDictionary *assets, NSString *stagingPath, NSUInteger *resourceCount, unsigned long long *resourceBytes, NSError **error) {
    if (![assets isKindOfClass:NSDictionary.class]) {
        return DYYYSetBackupError(error, 50, @"备份资源结构无效");
    }
    NSSet *allowedKeys = [NSSet setWithArray:@[ @"icons", @"abtest" ]];
    for (id key in assets) {
        if (![key isKindOfClass:NSString.class] || ![allowedKeys containsObject:key]) {
            return DYYYSetBackupError(error, 51, @"备份包含未授权的资源范围");
        }
    }
    NSDictionary *icons = assets[@"icons"];
    NSData *abtest = assets[@"abtest"];
    if (![icons isKindOfClass:NSDictionary.class] || (abtest && ![abtest isKindOfClass:NSData.class])) {
        return DYYYSetBackupError(error, 52, @"备份资源类型无效");
    }

    NSUInteger count = 0;
    unsigned long long bytes = 0;
    for (id fileName in icons) {
        NSData *data = icons[fileName];
        if (![fileName isKindOfClass:NSString.class] || ![DYYYBackupIconFileNames() containsObject:fileName] || ![data isKindOfClass:NSData.class] || data.length > DYYYBackupMaximumResourceSize) {
            return DYYYSetBackupError(error, 53, @"自定义图标资源无效");
        }
        count++;
        bytes += data.length;
        if (stagingPath && !DYYYBackupWriteStagedData(data, [stagingPath stringByAppendingPathComponent:[@"resources/icons" stringByAppendingPathComponent:fileName]], error)) {
            return NO;
        }
    }
    if (abtest) {
        if (abtest.length > DYYYBackupMaximumResourceSize) {
            return DYYYSetBackupError(error, 54, @"ABTest 资源过大");
        }
        count++;
        bytes += abtest.length;
        if (stagingPath && !DYYYBackupWriteStagedData(abtest, [stagingPath stringByAppendingPathComponent:@"resources/abtest/abtest_data_fixed.json"], error)) {
            return NO;
        }
    }
    if (count > DYYYBackupMaximumEntryCount || bytes > DYYYBackupMaximumExpandedSize) {
        return DYYYSetBackupError(error, 56, @"备份资源数量或大小超过安全限制");
    }
    if (resourceCount) {
        *resourceCount = count;
    }
    if (resourceBytes) {
        *resourceBytes = bytes;
    }
    return YES;
}

static BOOL DYYYBackupValidatePayload(NSDictionary *payload, NSString *stagingPath, NSDictionary **settings, BOOL *managesSensitiveCredentials, NSDictionary **summary, NSError **error) {
    NSNumber *payloadVersion = payload[@"version"];
    if (![payload[@"format"] isEqualToString:DYYYBackupFormatIdentifier] || ![payloadVersion isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)payloadVersion) == CFBooleanGetTypeID() || payloadVersion.integerValue != DYYYBackupFormatVersion ||
        ![payload[@"metadata"] isKindOfClass:NSDictionary.class] || ![payload[@"preferences"] isKindOfClass:NSDictionary.class] || ![payload[@"secrets"] isKindOfClass:NSDictionary.class] ||
        ![payload[@"assets"] isKindOfClass:NSDictionary.class]) {
        return DYYYSetBackupError(error, 60, @"备份 V3 数据结构无效");
    }
    NSSet *requiredRootKeys = [NSSet setWithArray:@[ @"format", @"version", @"metadata", @"preferences", @"secrets", @"assets" ]];
    if (![requiredRootKeys isEqualToSet:[NSSet setWithArray:payload.allKeys]]) {
        return DYYYSetBackupError(error, 61, @"备份包含未授权的顶层字段");
    }

    NSDictionary *metadata = payload[@"metadata"];
    NSDictionary *preferences = payload[@"preferences"];
    NSDictionary *encryptedSecrets = payload[@"secrets"];
    NSSet *requiredMetadataKeys = [NSSet setWithArray:@[
        @"createdAt", @"sourceAppVersion", @"managedAssetScopes", @"credentialScopeIncluded", @"containsSensitiveCredentials", @"secretsProtection", @"preferenceCount", @"resourceCount", @"resourceBytes", @"compression", @"integrity"
    ]];
    if (![requiredMetadataKeys isEqualToSet:[NSSet setWithArray:metadata.allKeys]] || preferences.count > DYYYBackupMaximumEntryCount) {
        return DYYYSetBackupError(error, 62, @"备份元数据字段或设置数量无效");
    }
    NSArray *managedScopes = metadata[@"managedAssetScopes"];
    NSNumber *credentialScopeIncluded = metadata[@"credentialScopeIncluded"];
    NSNumber *containsSensitiveCredentials = metadata[@"containsSensitiveCredentials"];
    if (![metadata[@"createdAt"] isKindOfClass:NSDate.class] || ![metadata[@"sourceAppVersion"] isKindOfClass:NSString.class] ||
        ![managedScopes isKindOfClass:NSArray.class] || ![managedScopes isEqualToArray:@[ @"icons", @"abtest" ]] ||
        ![credentialScopeIncluded isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)credentialScopeIncluded) != CFBooleanGetTypeID() ||
        ![containsSensitiveCredentials isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)containsSensitiveCredentials) != CFBooleanGetTypeID() ||
        ![metadata[@"secretsProtection"] isEqualToString:@"none"] || credentialScopeIncluded.boolValue || containsSensitiveCredentials.boolValue || encryptedSecrets.count > 0 ||
        ![metadata[@"preferenceCount"] isKindOfClass:NSNumber.class] || ![metadata[@"resourceCount"] isKindOfClass:NSNumber.class] ||
        ![metadata[@"resourceBytes"] isKindOfClass:NSNumber.class] || ![metadata[@"compression"] isEqualToString:@"lzfse"] || ![metadata[@"integrity"] isEqualToString:@"sha256"]) {
        return DYYYSetBackupError(error, 63, @"备份元数据无效");
    }

    NSMutableDictionary *decodedSettings = [NSMutableDictionary dictionary];
    for (id key in preferences) {
        id value = preferences[key];
        if (!DYYYBackupIsAllowedPreferenceKey(key) || !DYYYBackupValidatePropertyListValue(value, 0)) {
            return DYYYSetBackupError(error, 64, [NSString stringWithFormat:@"备份包含无效的普通设置：%@", key]);
        }
        decodedSettings[key] = value;
    }
    if ([metadata[@"preferenceCount"] unsignedIntegerValue] != decodedSettings.count) {
        return DYYYSetBackupError(error, 66, @"备份设置计数不一致");
    }

    NSUInteger resourceCount = 0;
    unsigned long long resourceBytes = 0;
    if (!DYYYBackupValidateAndStageAssets(payload[@"assets"], stagingPath, &resourceCount, &resourceBytes, error)) {
        return NO;
    }
    if ([metadata[@"resourceCount"] unsignedIntegerValue] != resourceCount || [metadata[@"resourceBytes"] unsignedLongLongValue] != resourceBytes) {
        return DYYYSetBackupError(error, 67, @"备份资源计数不一致");
    }

    if (settings) {
        *settings = decodedSettings;
    }
    if (managesSensitiveCredentials) {
        *managesSensitiveCredentials = NO;
    }
    if (summary) {
        *summary = @{
            @"format" : @"DYYY V3",
            @"createdAt" : metadata[@"createdAt"],
            @"sourceAppVersion" : metadata[@"sourceAppVersion"],
            @"settingCount" : @(decodedSettings.count),
            @"resourceCount" : @(resourceCount),
            @"resourceBytes" : @(resourceBytes),
            @"containsSensitiveCredentials" : @NO,
            @"managesSensitiveCredentials" : @NO
        };
    }
    return YES;
}

#pragma mark - Restore transaction

static NSDictionary *DYYYBackupCurrentAllowedPreferences(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    for (NSString *key in defaults.dictionaryRepresentation) {
        if (DYYYBackupIsAllowedPreferenceKey(key)) {
            id value = [defaults objectForKey:key];
            if (value) {
                values[key] = value;
            }
        }
    }
    return values;
}

static void DYYYBackupRestorePreferenceSnapshot(NSDictionary *snapshot) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    for (NSString *key in defaults.dictionaryRepresentation.allKeys) {
        if (DYYYBackupIsAllowedPreferenceKey(key)) {
            [defaults removeObjectForKey:key];
        }
    }
    [snapshot enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, __unused BOOL *stop) {
      [defaults setObject:value forKey:key];
    }];
    [defaults synchronize];
}

static BOOL DYYYBackupApplyPreferences(NSDictionary *settings, DYYYBackupRestoreMode mode, BOOL managesSensitiveCredentials, NSDictionary *snapshot, NSError **error) {
    (void)managesSensitiveCredentials;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    @try {
        if (mode == DYYYBackupRestoreModeReplace) {
            for (NSString *key in defaults.dictionaryRepresentation.allKeys) {
                if (DYYYBackupIsAllowedPreferenceKey(key)) {
                    [defaults removeObjectForKey:key];
                }
            }
        }
        [settings enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, __unused BOOL *stop) {
          [defaults setObject:value forKey:key];
        }];
        [defaults synchronize];
        return YES;
    } @catch (NSException *exception) {
        DYYYBackupRestorePreferenceSnapshot(snapshot);
        return DYYYSetBackupError(error, 70, exception.reason ?: @"写入设置失败");
    }
}

static BOOL DYYYBackupSnapshotResources(NSString *rollbackPath, NSError **error) {
    NSFileManager *fileManager = NSFileManager.defaultManager;
    [fileManager removeItemAtPath:rollbackPath error:nil];
    if (![fileManager createDirectoryAtPath:rollbackPath withIntermediateDirectories:YES attributes:nil error:error]) {
        return NO;
    }
    NSString *dyyyDirectory = DYYYBackupDYYYDirectory();
    for (NSString *fileName in DYYYBackupIconFileNames()) {
        NSString *sourcePath = [dyyyDirectory stringByAppendingPathComponent:fileName];
        if ([fileManager fileExistsAtPath:sourcePath] &&
            !DYYYBackupCopyReplacing(sourcePath, [[rollbackPath stringByAppendingPathComponent:@"icons"] stringByAppendingPathComponent:fileName], error)) {
            return NO;
        }
    }
    NSString *abtestPath = [dyyyDirectory stringByAppendingPathComponent:@"abtest_data_fixed.json"];
    if ([fileManager fileExistsAtPath:abtestPath] && !DYYYBackupCopyReplacing(abtestPath, [rollbackPath stringByAppendingPathComponent:@"abtest_data_fixed.json"], error)) {
        return NO;
    }
    return YES;
}

static void DYYYBackupRollbackResources(NSString *rollbackPath) {
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSString *dyyyDirectory = DYYYBackupDYYYDirectory();
    [fileManager createDirectoryAtPath:dyyyDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *fileName in DYYYBackupIconFileNames()) {
        NSString *destinationPath = [dyyyDirectory stringByAppendingPathComponent:fileName];
        [fileManager removeItemAtPath:destinationPath error:nil];
        DYYYBackupCopyReplacing([[rollbackPath stringByAppendingPathComponent:@"icons"] stringByAppendingPathComponent:fileName], destinationPath, nil);
    }
    NSString *abtestPath = [dyyyDirectory stringByAppendingPathComponent:@"abtest_data_fixed.json"];
    [fileManager removeItemAtPath:abtestPath error:nil];
    DYYYBackupCopyReplacing([rollbackPath stringByAppendingPathComponent:@"abtest_data_fixed.json"], abtestPath, nil);
}

static BOOL DYYYBackupApplyResources(NSString *stagingPath, DYYYBackupRestoreMode mode, NSError **error) {
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSString *dyyyDirectory = DYYYBackupDYYYDirectory();
    if (![fileManager createDirectoryAtPath:dyyyDirectory withIntermediateDirectories:YES attributes:nil error:error]) {
        return NO;
    }
    NSString *iconsDirectory = [stagingPath stringByAppendingPathComponent:@"resources/icons"];
    for (NSString *fileName in DYYYBackupIconFileNames()) {
        NSString *sourcePath = [iconsDirectory stringByAppendingPathComponent:fileName];
        NSString *destinationPath = [dyyyDirectory stringByAppendingPathComponent:fileName];
        if ([fileManager fileExistsAtPath:sourcePath]) {
            if (!DYYYBackupCopyReplacing(sourcePath, destinationPath, error)) {
                return NO;
            }
        } else if (mode == DYYYBackupRestoreModeReplace) {
            [fileManager removeItemAtPath:destinationPath error:nil];
        }
    }
    NSString *stagedAbtestPath = [stagingPath stringByAppendingPathComponent:@"resources/abtest/abtest_data_fixed.json"];
    NSString *destinationAbtestPath = [dyyyDirectory stringByAppendingPathComponent:@"abtest_data_fixed.json"];
    if ([fileManager fileExistsAtPath:stagedAbtestPath]) {
        if (!DYYYBackupCopyReplacing(stagedAbtestPath, destinationAbtestPath, error)) {
            return NO;
        }
    } else if (mode == DYYYBackupRestoreModeReplace) {
        [fileManager removeItemAtPath:destinationAbtestPath error:nil];
    }
    return YES;
}

#pragma mark - Public API

@implementation DYYYBackupManager

+ (BOOL)containsSensitiveCredentials {
    return NO;
}

+ (BOOL)createBackupAtURL:(NSURL *)destinationURL
    includeSensitiveCredentials:(BOOL)includeSensitiveCredentials
                         summary:(NSDictionary **)summary
                           error:(NSError **)error {
    if (!destinationURL.isFileURL || destinationURL.path.length == 0) {
        return DYYYSetBackupError(error, 80, @"备份输出路径无效");
    }
    NSDictionary *preferences = nil;
    NSDictionary *credentials = nil;
    if (!DYYYBackupCollectPreferences(includeSensitiveCredentials, &preferences, &credentials, error)) {
        return NO;
    }
    NSUInteger resourceCount = 0;
    unsigned long long resourceBytes = 0;
    NSDictionary *assets = DYYYBackupCollectAssets(&resourceCount, &resourceBytes, error);
    if (!assets) {
        return NO;
    }
    NSDictionary *metadata = @{
        @"createdAt" : NSDate.date,
        @"sourceAppVersion" : [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"",
        @"managedAssetScopes" : @[ @"icons", @"abtest" ],
        @"credentialScopeIncluded" : @NO,
        @"containsSensitiveCredentials" : @NO,
        @"secretsProtection" : @"none",
        @"preferenceCount" : @(preferences.count),
        @"resourceCount" : @(resourceCount),
        @"resourceBytes" : @(resourceBytes),
        @"compression" : @"lzfse",
        @"integrity" : @"sha256"
    };
    NSDictionary *payload = @{
        @"format" : DYYYBackupFormatIdentifier,
        @"version" : @(DYYYBackupFormatVersion),
        @"metadata" : metadata,
        @"preferences" : preferences,
        @"secrets" : @{},
        @"assets" : assets
    };
    NSData *envelope = DYYYBackupCreateEnvelope(payload, error);
    if (!envelope) {
        return NO;
    }
    if (![NSFileManager.defaultManager createDirectoryAtPath:destinationURL.path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:error] ||
        ![envelope writeToURL:destinationURL options:NSDataWritingAtomic error:error]) {
        return NO;
    }
    if (summary) {
        *summary = @{
            @"format" : @"DYYY V3",
            @"settingCount" : @(preferences.count),
            @"resourceCount" : @(resourceCount),
            @"resourceBytes" : @(resourceBytes),
            @"containsSensitiveCredentials" : @NO,
            @"managesSensitiveCredentials" : @NO
        };
    }
    return YES;
}

+ (NSDictionary *)inspectBackupAtURL:(NSURL *)sourceURL error:(NSError **)error {
    NSDictionary *payload = DYYYBackupReadEnvelope(sourceURL, error);
    if (!payload) {
        return nil;
    }
    NSDictionary *summary = nil;
    if (!DYYYBackupValidatePayload(payload, nil, nil, nil, &summary, error)) {
        return nil;
    }
    return summary;
}

+ (BOOL)restoreBackupAtURL:(NSURL *)sourceURL mode:(DYYYBackupRestoreMode)mode summary:(NSDictionary **)summary error:(NSError **)error {
    NSDictionary *payload = DYYYBackupReadEnvelope(sourceURL, error);
    if (!payload) {
        return NO;
    }
    NSString *temporaryRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"DYYYRestore-%@", NSUUID.UUID.UUIDString]];
    NSString *stagingPath = [temporaryRoot stringByAppendingPathComponent:@"staging"];
    NSString *rollbackPath = [temporaryRoot stringByAppendingPathComponent:@"rollback"];
    NSFileManager *fileManager = NSFileManager.defaultManager;
    if (![fileManager createDirectoryAtPath:stagingPath withIntermediateDirectories:YES attributes:nil error:error]) {
        return NO;
    }

    NSDictionary *settings = nil;
    NSDictionary *inspection = nil;
    BOOL managesSensitiveCredentials = NO;
    if (!DYYYBackupValidatePayload(payload, stagingPath, &settings, &managesSensitiveCredentials, &inspection, error)) {
        [fileManager removeItemAtPath:temporaryRoot error:nil];
        return NO;
    }

    NSDictionary *preferenceSnapshot = DYYYBackupCurrentAllowedPreferences();
    if (!DYYYBackupSnapshotResources(rollbackPath, error)) {
        [fileManager removeItemAtPath:temporaryRoot error:nil];
        return NO;
    }
    if (!DYYYBackupApplyResources(stagingPath, mode, error)) {
        DYYYBackupRollbackResources(rollbackPath);
        [fileManager removeItemAtPath:temporaryRoot error:nil];
        return NO;
    }
    if (!DYYYBackupApplyPreferences(settings, mode, managesSensitiveCredentials, preferenceSnapshot, error)) {
        DYYYBackupRollbackResources(rollbackPath);
        [fileManager removeItemAtPath:temporaryRoot error:nil];
        return NO;
    }

    [fileManager removeItemAtPath:temporaryRoot error:nil];
    if (summary) {
        NSMutableDictionary *restoreSummary = [inspection mutableCopy];
        restoreSummary[@"mode"] = mode == DYYYBackupRestoreModeReplace ? @"replace" : @"merge";
        *summary = restoreSummary;
    }
    return YES;
}

@end
