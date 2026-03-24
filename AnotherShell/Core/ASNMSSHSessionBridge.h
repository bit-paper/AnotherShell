#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^ASNMSSHConnectCompletion)(BOOL success, BOOL usedKeyboardInteractive, NSString * _Nullable failureReason);
typedef void (^ASNMSSHDataHandler)(NSData *data);
typedef void (^ASNMSSHDisconnectHandler)(NSString * _Nullable reason);
typedef void (^ASNMSSHSystemStatusCompletion)(NSDictionary<NSString *, NSString *> * _Nullable status, NSString * _Nullable failureReason);

@interface ASNMSSHSessionBridge : NSObject

@property (nonatomic, copy, nullable) ASNMSSHDataHandler onData;
@property (nonatomic, copy, nullable) ASNMSSHDataHandler onErrorData;
@property (nonatomic, copy, nullable) ASNMSSHDisconnectHandler onDisconnect;

- (instancetype)initWithHost:(NSString *)host
                        port:(NSInteger)port
                    username:(NSString *)username
                    password:(NSString *)password;

- (void)connectWithCompletion:(ASNMSSHConnectCompletion)completion;
- (void)disconnect;
- (void)writeData:(NSData *)data;
- (void)resizeWithColumns:(NSUInteger)columns rows:(NSUInteger)rows;

+ (void)probeSystemStatusWithHost:(NSString *)host
                             port:(NSInteger)port
                         username:(NSString *)username
                         password:(NSString *)password
                       completion:(ASNMSSHSystemStatusCompletion)completion;

@end

NS_ASSUME_NONNULL_END
