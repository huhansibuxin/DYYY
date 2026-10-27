#import "DYYYBackupPickerDelegate.h"
// 【v75】日志受控：本文件所有 NSLog 统一走 DYYYDiagOn()（定义在 DYYY.xm），
// 设置页关掉「诊断日志」后连系统日志也零输出（此前这里的 NSLog 是绕过总开关的裸调用）。
extern BOOL DYYYDiagOn(void);
#ifndef DYYYLog
#define DYYYLog(fmt, ...) do { if (DYYYDiagOn()) NSLog(fmt, ##__VA_ARGS__); } while (0)
#endif

@implementation DYYYBackupPickerDelegate
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count > 0 && self.completionBlock) {
        self.completionBlock(urls.firstObject);
    }
    [self cleanupTempFile];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    [self cleanupTempFile];
}

- (void)cleanupTempFile {
    if (self.tempFilePath && [[NSFileManager defaultManager] fileExistsAtPath:self.tempFilePath]) {
        NSError *error = nil;
        [[NSFileManager defaultManager] removeItemAtPath:self.tempFilePath error:&error];
        if (error) {
            DYYYLog(@"[DYYY] \u6e05\u7406\u4e34\u65f6\u6587\u4ef6\u5931\u8d25: %@", error.localizedDescription);
        }
    }
}
@end
