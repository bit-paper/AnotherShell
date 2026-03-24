#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef BOOL (^ASNMSSHTransferProgressBlock)(unsigned long long completedBytes, unsigned long long totalBytes);

@interface ASNMSSHSFTPBridge : NSObject

- (instancetype)initWithHost:(NSString *)host
                        port:(NSInteger)port
                    username:(NSString *)username
                    password:(NSString *)password;

- (BOOL)connect:(NSString * _Nullable * _Nullable)failureReason;
- (void)disconnect;

- (NSArray<NSDictionary *> * _Nullable)contentsOfDirectoryAtPath:(NSString *)path
                                                   failureReason:(NSString * _Nullable * _Nullable)failureReason;
- (NSDictionary * _Nullable)fileInfoAtPath:(NSString *)path
                             failureReason:(NSString * _Nullable * _Nullable)failureReason;
- (BOOL)createDirectoryAtPath:(NSString *)path
                failureReason:(NSString * _Nullable * _Nullable)failureReason;
- (NSData * _Nullable)readFileAtPath:(NSString *)path
                       failureReason:(NSString * _Nullable * _Nullable)failureReason;
- (BOOL)writeFileData:(NSData *)data
               toPath:(NSString *)path
        failureReason:(NSString * _Nullable * _Nullable)failureReason;
- (BOOL)uploadFileAtLocalPath:(NSString *)localPath
                       toPath:(NSString *)remotePath
                     progress:(ASNMSSHTransferProgressBlock _Nullable)progress
                failureReason:(NSString * _Nullable * _Nullable)failureReason;
- (BOOL)downloadFileAtPath:(NSString *)remotePath
               toLocalPath:(NSString *)localPath
                  progress:(ASNMSSHTransferProgressBlock _Nullable)progress
             failureReason:(NSString * _Nullable * _Nullable)failureReason;
- (BOOL)moveItemAtPath:(NSString *)sourcePath
                toPath:(NSString *)destinationPath
         failureReason:(NSString * _Nullable * _Nullable)failureReason;
- (BOOL)removeItemAtPath:(NSString *)path
               recursive:(BOOL)recursive
            failureReason:(NSString * _Nullable * _Nullable)failureReason;

@end

NS_ASSUME_NONNULL_END
