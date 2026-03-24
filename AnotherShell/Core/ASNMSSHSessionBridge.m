#import "ASNMSSHSessionBridge.h"

#import "NMSSH.h"

@interface ASNMSSHSessionBridge () <NMSSHSessionDelegate, NMSSHChannelDelegate>

@property (nonatomic, copy) NSString *host;
@property (nonatomic, assign) NSInteger port;
@property (nonatomic, copy) NSString *username;
@property (nonatomic, copy) NSString *password;
@property (nonatomic, strong, nullable) NMSSHSession *session;
@property (nonatomic, assign) BOOL didStartShell;

@end

@implementation ASNMSSHSessionBridge

- (instancetype)initWithHost:(NSString *)host
                        port:(NSInteger)port
                    username:(NSString *)username
                    password:(NSString *)password {
    self = [super init];
    if (self) {
        _host = [host copy];
        _port = port;
        _username = [username copy];
        _password = [password copy];
    }
    return self;
}

- (void)connectWithCompletion:(ASNMSSHConnectCompletion)completion {
    self.didStartShell = NO;

    NMSSHSession *session = [[NMSSHSession alloc] initWithHost:self.host port:self.port andUsername:self.username];
    session.delegate = self;
    session.timeout = @15;

    if (![session connect]) {
        completion(NO, NO, session.lastError.localizedDescription ?: @"Failed to connect");
        return;
    }

    BOOL usedKeyboardInteractive = NO;
    BOOL authorized = [session authenticateByPassword:self.password];
    if (!authorized) {
        usedKeyboardInteractive = YES;
        authorized = [session authenticateByKeyboardInteractive];
    }

    if (!authorized) {
        NSString *reason = session.lastError.localizedDescription ?: @"Authentication failed";
        [session disconnect];
        completion(NO, usedKeyboardInteractive, reason);
        return;
    }

    session.channel.delegate = self;
    session.channel.requestPty = YES;
    session.channel.ptyTerminalType = NMSSHChannelPtyTerminalXterm;

    NSError *shellError = nil;
    if (![session.channel startShell:&shellError]) {
        NSString *reason = shellError.localizedDescription ?: session.lastError.localizedDescription ?: @"Failed to open shell";
        [session disconnect];
        completion(NO, usedKeyboardInteractive, reason);
        return;
    }

    self.didStartShell = YES;
    self.session = session;
    completion(YES, usedKeyboardInteractive, nil);
}

- (void)disconnect {
    NMSSHSession *session = self.session;
    self.session = nil;

    if (session.channel.type == NMSSHChannelTypeShell) {
        [session.channel closeShell];
    }
    if (session.isConnected) {
        [session disconnect];
    }
}

- (void)writeData:(NSData *)data {
    if (!self.session || !self.didStartShell) {
        return;
    }

    NSError *error = nil;
    [self.session.channel writeData:data error:&error];
}

- (void)resizeWithColumns:(NSUInteger)columns rows:(NSUInteger)rows {
    if (!self.session || !self.didStartShell) {
        return;
    }

    [self.session.channel requestSizeWidth:columns height:rows];
}

- (NSString *)session:(NMSSHSession *)session keyboardInteractiveRequest:(NSString *)request {
    return self.password ?: @"";
}

- (BOOL)session:(NMSSHSession *)session shouldConnectToHostWithFingerprint:(NSString *)fingerprint {
    return YES;
}

- (void)session:(NMSSHSession *)session didDisconnectWithError:(NSError *)error {
    if (self.onDisconnect) {
        self.onDisconnect(error.localizedDescription);
    }
}

- (void)channel:(NMSSHChannel *)channel didReadRawData:(NSData *)data {
    if (self.onData) {
        self.onData(data);
    }
}

- (void)channel:(NMSSHChannel *)channel didReadRawError:(NSData *)error {
    if (self.onErrorData) {
        self.onErrorData(error);
    }
}

- (void)channelShellDidClose:(NMSSHChannel *)channel {
    if (self.onDisconnect) {
        self.onDisconnect(nil);
    }
}

+ (void)probeSystemStatusWithHost:(NSString *)host
                             port:(NSInteger)port
                         username:(NSString *)username
                         password:(NSString *)password
                       completion:(ASNMSSHSystemStatusCompletion)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NMSSHSession *session = [[NMSSHSession alloc] initWithHost:host port:port andUsername:username];
        session.timeout = @10;
        if (![session connect]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    completion(nil, session.lastError.localizedDescription ?: @"Connect failed");
                }
            });
            return;
        }

        BOOL authorized = [session authenticateByPassword:password];
        if (!authorized) {
            authorized = [session authenticateByKeyboardInteractive];
        }
        if (!authorized) {
            NSString *reason = session.lastError.localizedDescription ?: @"Authentication failed";
            [session disconnect];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    completion(nil, reason);
                }
            });
            return;
        }

        NSMutableDictionary<NSString *, NSString *> *status = [NSMutableDictionary dictionary];
        NSString* (^executeTrimmed)(NSString *, NSNumber *) = ^NSString *(NSString *command, NSNumber *timeout) {
            NSError *commandError = nil;
            NSString *output = [session.channel execute:command error:&commandError timeout:timeout];
            if (output.length == 0) {
                return @"";
            }
            return [output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        };
        BOOL (^looksCommandMissing)(NSString *) = ^BOOL(NSString *value) {
            if (value.length == 0) { return YES; }
            NSString *lower = value.lowercaseString;
            return [lower containsString:@"not found"] ||
                   [lower containsString:@"not recognized"] ||
                   [lower containsString:@"command not found"] ||
                   [lower containsString:@"is unknown"] ||
                   [lower containsString:@"no such file"] ||
                   [lower containsString:@"cannot find"];
        };

        NSString *psEdition = executeTrimmed(@"powershell -NoProfile -Command \"$PSVersionTable.PSEdition\"", @4);
        NSString *psVersion = executeTrimmed(@"powershell -NoProfile -Command \"$PSVersionTable.PSVersion.ToString()\"", @4);
        NSString *cmdVer = executeTrimmed(@"cmd.exe /c ver", @4);
        if (cmdVer.length == 0 || looksCommandMissing(cmdVer)) {
            cmdVer = executeTrimmed(@"ver", @4);
        }
        NSString *wmicCaption = executeTrimmed(@"wmic os get Caption /value", @5);

        BOOL hasPowerShell = psEdition.length > 0 && !looksCommandMissing(psEdition);
        BOOL cmdLooksWindows = cmdVer.length > 0 && [cmdVer.lowercaseString containsString:@"windows"];
        BOOL wmicLooksWindows = wmicCaption.length > 0 && [wmicCaption.lowercaseString containsString:@"windows"];
        BOOL isWindows = hasPowerShell || cmdLooksWindows || wmicLooksWindows;

        if (isWindows) {
            if (cmdLooksWindows) {
                status[@"os"] = cmdVer;
            } else if (psVersion.length > 0 && !looksCommandMissing(psVersion)) {
                status[@"os"] = [NSString stringWithFormat:@"Windows (PowerShell %@)", psVersion];
            } else {
                status[@"os"] = @"Windows";
            }

            NSString *model = executeTrimmed(@"powershell -NoProfile -Command \"(Get-CimInstance Win32_ComputerSystem).Model\"", @6);
            if (model.length == 0 || looksCommandMissing(model)) {
                model = executeTrimmed(@"wmic computersystem get model /value", @6);
                NSRange range = [model rangeOfString:@"Model="];
                if (range.location != NSNotFound) {
                    model = [[model substringFromIndex:range.location + range.length] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                }
            }
            status[@"model"] = model.length > 0 ? [model stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : @"N/A";

            NSString *memory = executeTrimmed(@"powershell -NoProfile -Command \"$o=Get-CimInstance Win32_OperatingSystem; $t=[math]::Round($o.TotalVisibleMemorySize/1024); $u=[math]::Round(($o.TotalVisibleMemorySize-$o.FreePhysicalMemory)/1024); Write-Output ($u.ToString()+'/'+$t.ToString()+' MB')\"", @8);
            if (memory.length == 0 || looksCommandMissing(memory)) {
                memory = executeTrimmed(@"wmic OS get FreePhysicalMemory,TotalVisibleMemorySize /value", @8);
                if ([memory containsString:@"TotalVisibleMemorySize="] && [memory containsString:@"FreePhysicalMemory="]) {
                    NSArray<NSString *> *lines = [memory componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
                    double total = 0;
                    double freeValue = 0;
                    for (NSString *line in lines) {
                        if ([line hasPrefix:@"TotalVisibleMemorySize="]) {
                            total = [[line substringFromIndex:@"TotalVisibleMemorySize=".length] doubleValue];
                        } else if ([line hasPrefix:@"FreePhysicalMemory="]) {
                            freeValue = [[line substringFromIndex:@"FreePhysicalMemory=".length] doubleValue];
                        }
                    }
                    if (total > 0) {
                        double usedMB = (total - freeValue) / 1024.0;
                        double totalMB = total / 1024.0;
                        memory = [NSString stringWithFormat:@"%.0f/%.0f MB", usedMB, totalMB];
                    }
                }
            }
            status[@"memory"] = memory.length > 0 ? [memory stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : @"N/A";

            NSString *disk = executeTrimmed(@"powershell -NoProfile -Command \"$d=Get-CimInstance Win32_LogicalDisk -Filter \\\"DeviceID='C:'\\\"; if($d){$u=[math]::Round(($d.Size-$d.FreeSpace)/1GB,1);$t=[math]::Round($d.Size/1GB,1);$p=[math]::Round((($d.Size-$d.FreeSpace)/$d.Size)*100,0); Write-Output ($u.ToString()+'/'+$t.ToString()+' GB ('+$p.ToString()+'%)')}\"", @8);
            if (disk.length == 0 || looksCommandMissing(disk)) {
                disk = executeTrimmed(@"wmic logicaldisk where \"DeviceID='C:'\" get FreeSpace,Size /value", @8);
            }
            status[@"disk"] = disk.length > 0 ? [disk stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : @"N/A";
        } else {
            NSString *os = executeTrimmed(@"uname -srm 2>/dev/null || uname -a", @5);
            status[@"os"] = os.length > 0 ? os : @"Unix";

            NSString *model = executeTrimmed(@"(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || cat /proc/device-tree/model 2>/dev/null || uname -m) | head -n 1", @5);
            status[@"model"] = model.length > 0 ? model : @"N/A";

            // Prefer /proc/meminfo for deterministic unit conversion (kB -> MB) across BusyBox/free variants.
            NSString *memory = executeTrimmed(@"awk '/MemTotal:/ {t=$2} /MemAvailable:/ {a=$2} END {if(t>0){u=t-a; printf \"%.0f/%.0f MB\", u/1024, t/1024}}' /proc/meminfo 2>/dev/null", @5);
            if (memory.length == 0 || looksCommandMissing(memory)) {
                memory = executeTrimmed(@"free -m 2>/dev/null | awk '/^Mem:/ {printf \"%s/%s MB\", $3, $2}'", @5);
            }
            if (memory.length == 0 || looksCommandMissing(memory)) {
                memory = executeTrimmed(@"awk '/MemTotal/ {printf \"?/%d MB\", $2/1024}' /proc/meminfo 2>/dev/null", @5);
            }
            status[@"memory"] = memory.length > 0 ? memory : @"N/A";

            NSString *disk = executeTrimmed(@"df -hP / 2>/dev/null | tail -1 | awk '{printf \"%s/%s (%s)\", $3, $2, $5}'", @5);
            status[@"disk"] = disk.length > 0 ? disk : @"N/A";
        }

        [session disconnect];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(status, nil);
            }
        });
    });
}

@end
