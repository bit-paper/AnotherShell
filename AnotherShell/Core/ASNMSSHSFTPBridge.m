#import "ASNMSSHSFTPBridge.h"

#import "NMSSH.h"

@interface ASNMSSHSFTPBridge () <NMSSHSessionDelegate>

@property (nonatomic, copy) NSString *host;
@property (nonatomic, assign) NSInteger port;
@property (nonatomic, copy) NSString *username;
@property (nonatomic, copy) NSString *password;
@property (nonatomic, strong, nullable) NMSSHSession *session;
@property (nonatomic, assign) BOOL usesSCPFallback;

@end

@implementation ASNMSSHSFTPBridge

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

- (BOOL)connect:(NSString * _Nullable * _Nullable)failureReason {
    if (self.session.isConnected && self.session.isAuthorized && self.session.sftp.isConnected) {
        return YES;
    }

    NMSSHSession *session = [[NMSSHSession alloc] initWithHost:self.host port:self.port andUsername:self.username];
    session.delegate = self;
    session.timeout = @15;

    if (![session connect]) {
        if (failureReason) {
            *failureReason = session.lastError.localizedDescription ?: @"Failed to connect";
        }
        return NO;
    }

    BOOL authorized = [session authenticateByPassword:self.password];
    if (!authorized) {
        authorized = [session authenticateByKeyboardInteractive];
    }
    if (!authorized) {
        if (failureReason) {
            *failureReason = session.lastError.localizedDescription ?: @"Authentication failed";
        }
        [session disconnect];
        return NO;
    }

    session.channel.requestPty = NO;
    self.usesSCPFallback = NO;

    if (![session.sftp connect]) {
        // Industry-standard behavior: fall back to SCP workflow when SFTP subsystem is unavailable.
        self.usesSCPFallback = YES;
    }

    self.session = session;
    return YES;
}

- (void)disconnect {
    NMSSHSession *session = self.session;
    self.session = nil;
    if (session.sftp.isConnected) {
        [session.sftp disconnect];
    }
    if (session.isConnected) {
        [session disconnect];
    }
}

- (NSArray<NSDictionary *> * _Nullable)contentsOfDirectoryAtPath:(NSString *)path
                                                   failureReason:(NSString * _Nullable * _Nullable)failureReason {
    if (self.usesSCPFallback) {
        return [self contentsOfDirectoryViaShellAtPath:path failureReason:failureReason];
    }

    NSArray<NMSFTPFile *> *items = [self.session.sftp contentsOfDirectoryAtPath:path];
    if (!items) {
        if (failureReason) {
            *failureReason = self.session.lastError.localizedDescription ?: @"Failed to list directory";
        }
        return nil;
    }

    NSMutableArray<NSDictionary *> *mapped = [[NSMutableArray alloc] initWithCapacity:items.count];
    for (NMSFTPFile *file in items) {
        [mapped addObject:[self dictionaryForFile:file]];
    }
    return mapped;
}

- (NSDictionary * _Nullable)fileInfoAtPath:(NSString *)path
                             failureReason:(NSString * _Nullable * _Nullable)failureReason {
    if (self.usesSCPFallback) {
        return [self fileInfoViaShellAtPath:path failureReason:failureReason];
    }

    NMSFTPFile *file = [self.session.sftp infoForFileAtPath:path];
    if (!file) {
        if (failureReason) {
            *failureReason = self.session.lastError.localizedDescription ?: @"Failed to read file info";
        }
        return nil;
    }
    return [self dictionaryForFile:file];
}

- (BOOL)createDirectoryAtPath:(NSString *)path
                failureReason:(NSString * _Nullable * _Nullable)failureReason {
    if (self.usesSCPFallback) {
        NSString *command = [NSString stringWithFormat:@"mkdir -p %@", [self shellSingleQuote:path]];
        return [self executeShellCommand:command failureReason:failureReason] != nil;
    }

    if ([self.session.sftp directoryExistsAtPath:path]) {
        return YES;
    }
    BOOL ok = [self.session.sftp createDirectoryAtPath:path];
    if (!ok && failureReason) {
        *failureReason = self.session.lastError.localizedDescription ?: @"Failed to create directory";
    }
    return ok;
}

- (NSData * _Nullable)readFileAtPath:(NSString *)path
                       failureReason:(NSString * _Nullable * _Nullable)failureReason {
    if (self.usesSCPFallback) {
        NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
        NSError *downloadError = nil;
        BOOL ok = [self.session.channel downloadFile:path to:tmpPath progress:nil];
        if (!ok) {
            if (failureReason) {
                *failureReason = self.session.lastError.localizedDescription ?: @"Failed to download file";
            }
            return nil;
        }

        NSData *data = [NSData dataWithContentsOfFile:tmpPath options:0 error:&downloadError];
        [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];
        if (!data && failureReason) {
            *failureReason = downloadError.localizedDescription ?: @"Failed to read downloaded file";
        }
        return data;
    }

    NSData *data = [self.session.sftp contentsAtPath:path];
    if (!data && failureReason) {
        *failureReason = self.session.lastError.localizedDescription ?: @"Failed to read file";
    }
    return data;
}

- (BOOL)writeFileData:(NSData *)data
               toPath:(NSString *)path
        failureReason:(NSString * _Nullable * _Nullable)failureReason {
    if (self.usesSCPFallback) {
        NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
        BOOL localWriteOK = [data writeToFile:tmpPath atomically:YES];
        if (!localWriteOK) {
            if (failureReason) {
                *failureReason = @"Failed to write temporary upload file";
            }
            return NO;
        }

        BOOL ok = [self.session.channel uploadFile:tmpPath to:path progress:nil];
        [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];
        if (!ok && failureReason) {
            *failureReason = self.session.lastError.localizedDescription ?: @"Failed to upload file";
        }
        return ok;
    }

    BOOL ok = [self.session.sftp writeContents:data toFileAtPath:path];
    if (!ok && failureReason) {
        *failureReason = self.session.lastError.localizedDescription ?: @"Failed to write file";
    }
    return ok;
}

- (BOOL)uploadFileAtLocalPath:(NSString *)localPath
                       toPath:(NSString *)remotePath
                     progress:(ASNMSSHTransferProgressBlock _Nullable)progress
                failureReason:(NSString * _Nullable * _Nullable)failureReason {
    NSDictionary<NSFileAttributeKey, id> *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:localPath error:nil];
    unsigned long long totalBytes = [attributes[NSFileSize] unsignedLongLongValue];
    __block BOOL wasCancelled = NO;

    if (self.usesSCPFallback) {
        BOOL ok = [self.session.channel uploadFile:localPath to:remotePath progress:^BOOL(NSUInteger sent) {
            if (!progress) {
                return YES;
            }
            BOOL keepGoing = progress((unsigned long long)sent, totalBytes);
            if (!keepGoing) {
                wasCancelled = YES;
            }
            return keepGoing;
        }];

        if (!ok && failureReason) {
            *failureReason = wasCancelled ? @"Transfer cancelled" : (self.session.lastError.localizedDescription ?: @"Failed to upload file");
        }
        return ok;
    }

    BOOL ok = [self.session.sftp writeFileAtPath:localPath toFileAtPath:remotePath progress:^BOOL(NSUInteger sent) {
        if (!progress) {
            return YES;
        }
        BOOL keepGoing = progress((unsigned long long)sent, totalBytes);
        if (!keepGoing) {
            wasCancelled = YES;
        }
        return keepGoing;
    }];

    if (!ok && failureReason) {
        *failureReason = wasCancelled ? @"Transfer cancelled" : (self.session.lastError.localizedDescription ?: @"Failed to upload file");
    }
    return ok;
}

- (BOOL)downloadFileAtPath:(NSString *)remotePath
               toLocalPath:(NSString *)localPath
                  progress:(ASNMSSHTransferProgressBlock _Nullable)progress
             failureReason:(NSString * _Nullable * _Nullable)failureReason {
    __block BOOL wasCancelled = NO;

    if (self.usesSCPFallback) {
        BOOL ok = [self.session.channel downloadFile:remotePath to:localPath progress:^BOOL(NSUInteger got, NSUInteger totalBytes) {
            if (!progress) {
                return YES;
            }
            BOOL keepGoing = progress((unsigned long long)got, (unsigned long long)totalBytes);
            if (!keepGoing) {
                wasCancelled = YES;
            }
            return keepGoing;
        }];

        if (!ok && failureReason) {
            *failureReason = wasCancelled ? @"Transfer cancelled" : (self.session.lastError.localizedDescription ?: @"Failed to download file");
        }
        return ok;
    }

    NSOutputStream *outputStream = [NSOutputStream outputStreamToFileAtPath:localPath append:NO];
    BOOL ok = [self.session.sftp contentsAtPath:remotePath toStream:outputStream progress:^BOOL(NSUInteger got, NSUInteger totalBytes) {
        if (!progress) {
            return YES;
        }
        BOOL keepGoing = progress((unsigned long long)got, (unsigned long long)totalBytes);
        if (!keepGoing) {
            wasCancelled = YES;
        }
        return keepGoing;
    }];

    if (!ok && failureReason) {
        *failureReason = wasCancelled ? @"Transfer cancelled" : (self.session.lastError.localizedDescription ?: @"Failed to download file");
    }
    return ok;
}

- (BOOL)moveItemAtPath:(NSString *)sourcePath
                toPath:(NSString *)destinationPath
         failureReason:(NSString * _Nullable * _Nullable)failureReason {
    if (self.usesSCPFallback) {
        NSString *command = [NSString stringWithFormat:@"mv %@ %@", [self shellSingleQuote:sourcePath], [self shellSingleQuote:destinationPath]];
        return [self executeShellCommand:command failureReason:failureReason] != nil;
    }

    BOOL ok = [self.session.sftp moveItemAtPath:sourcePath toPath:destinationPath];
    if (!ok && failureReason) {
        *failureReason = self.session.lastError.localizedDescription ?: @"Failed to move item";
    }
    return ok;
}

- (BOOL)removeItemAtPath:(NSString *)path
               recursive:(BOOL)recursive
            failureReason:(NSString * _Nullable * _Nullable)failureReason {
    if (self.usesSCPFallback) {
        NSString *command = recursive
            ? [NSString stringWithFormat:@"rm -rf %@", [self shellSingleQuote:path]]
            : [NSString stringWithFormat:@"rm -f %@ 2>/dev/null || rmdir %@", [self shellSingleQuote:path], [self shellSingleQuote:path]];
        return [self executeShellCommand:command failureReason:failureReason] != nil;
    }

    NMSFTPFile *file = [self.session.sftp infoForFileAtPath:path];
    if (!file) {
        return YES;
    }

    if (file.isDirectory) {
        if (recursive) {
            NSArray<NMSFTPFile *> *children = [self.session.sftp contentsOfDirectoryAtPath:path];
            if (!children) {
                if (failureReason) {
                    *failureReason = self.session.lastError.localizedDescription ?: @"Failed to list directory for cleanup";
                }
                return NO;
            }
            for (NMSFTPFile *child in children) {
                NSString *name = child.filename ?: @"";
                if ([name isEqualToString:@"."] || [name isEqualToString:@".."]) {
                    continue;
                }
                NSString *childPath = [path stringByAppendingPathComponent:name];
                if (![self removeItemAtPath:childPath recursive:YES failureReason:failureReason]) {
                    return NO;
                }
            }
        }

        BOOL ok = [self.session.sftp removeDirectoryAtPath:path];
        if (!ok && failureReason) {
            *failureReason = self.session.lastError.localizedDescription ?: @"Failed to remove directory";
        }
        return ok;
    }

    BOOL ok = [self.session.sftp removeFileAtPath:path];
    if (!ok && failureReason) {
        *failureReason = self.session.lastError.localizedDescription ?: @"Failed to remove file";
    }
    return ok;
}

- (NSString *)session:(NMSSHSession *)session keyboardInteractiveRequest:(NSString *)request {
    return self.password ?: @"";
}

- (BOOL)session:(NMSSHSession *)session shouldConnectToHostWithFingerprint:(NSString *)fingerprint {
    return YES;
}

- (NSDictionary *)dictionaryForFile:(NMSFTPFile *)file {
    NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];
    dict[@"filename"] = file.filename ?: @"";
    dict[@"isDirectory"] = @(file.isDirectory);
    dict[@"fileSize"] = file.fileSize ?: @0;
    dict[@"permissions"] = file.permissions ?: @"";
    if (file.modificationDate) {
        dict[@"modificationDate"] = file.modificationDate;
    }
    return dict;
}

- (NSArray<NSDictionary *> * _Nullable)contentsOfDirectoryViaShellAtPath:(NSString *)path
                                                            failureReason:(NSString * _Nullable * _Nullable)failureReason {
    NSString *quotedPath = [self shellSingleQuote:path];
    NSString *command = [NSString stringWithFormat:@"LC_ALL=C; cd %@ 2>/dev/null && ls -la --color=never 2>/dev/null || ls -la 2>/dev/null", quotedPath];
    NSString *rawOutput = [self executeShellCommand:command failureReason:failureReason];
    if (!rawOutput) {
        return nil;
    }

    NSArray<NSString *> *lines = [rawOutput componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSMutableArray<NSDictionary *> *entries = [[NSMutableArray alloc] init];
    for (NSString *line in lines) {
        NSDictionary *parsed = [self parseLSLine:line];
        if (parsed) {
            [entries addObject:parsed];
        }
    }
    return entries;
}

- (NSDictionary * _Nullable)fileInfoViaShellAtPath:(NSString *)path
                                      failureReason:(NSString * _Nullable * _Nullable)failureReason {
    NSString *quotedPath = [self shellSingleQuote:path];
    NSString *command = [NSString stringWithFormat:@"LC_ALL=C; ls -ld --color=never %@ 2>/dev/null || ls -ld %@ 2>/dev/null", quotedPath, quotedPath];
    NSString *rawOutput = [self executeShellCommand:command failureReason:failureReason];
    if (!rawOutput) {
        return nil;
    }

    NSArray<NSString *> *lines = [rawOutput componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSString *line in lines) {
        NSDictionary *parsed = [self parseLSLine:line];
        if (parsed) {
            return parsed;
        }
    }
    return nil;
}

- (NSString * _Nullable)executeShellCommand:(NSString *)command
                              failureReason:(NSString * _Nullable * _Nullable)failureReason {
    NSError *error = nil;
    NSString *response = [self.session.channel execute:command error:&error timeout:@15];
    if (!response) {
        if (failureReason) {
            *failureReason = error.localizedDescription ?: self.session.lastError.localizedDescription ?: @"Remote shell command failed";
        }
        return nil;
    }
    return response;
}

- (NSString *)shellSingleQuote:(NSString *)value {
    NSString *escaped = [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\"'\"'"];
    return [NSString stringWithFormat:@"'%@'", escaped];
}

- (NSDictionary * _Nullable)parseLSLine:(NSString *)line {
    NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0 || [trimmed hasPrefix:@"total "]) {
        return nil;
    }
    NSArray<NSString *> *rawParts = [trimmed componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSMutableArray<NSString *> *parts = [[NSMutableArray alloc] initWithCapacity:rawParts.count];
    for (NSString *part in rawParts) {
        if (part.length > 0) {
            [parts addObject:part];
        }
    }

    if (parts.count < 9) {
        return nil;
    }
    NSString *permissions = parts[0];
    if (permissions.length < 10) {
        return nil;
    }
    NSString *sizeString = parts[4];
    NSString *name = [[parts subarrayWithRange:NSMakeRange(8, parts.count - 8)] componentsJoinedByString:@" "];

    NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];
    dict[@"filename"] = name ?: @"";
    dict[@"isDirectory"] = @([permissions hasPrefix:@"d"]);
    dict[@"fileSize"] = @([sizeString longLongValue]);
    dict[@"permissions"] = permissions ?: @"";
    return dict;
}

@end
