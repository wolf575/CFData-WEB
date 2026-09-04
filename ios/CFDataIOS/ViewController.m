#import "ViewController.h"

#import <crt_externs.h>
#import <dispatch/dispatch.h>
#import <errno.h>
#import <fcntl.h>
#import <signal.h>
#import <spawn.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <unistd.h>

static NSString *const kBackendBinaryName = @"cfdata";
static NSString *const kBridgeMessageName = @"cfdata";
static const int kBackendPort = 13335;

@interface ViewController ()

@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) UIView *loadingOverlay;
@property (nonatomic, strong) UILabel *loadingTitle;
@property (nonatomic, strong) UILabel *loadingMessage;
@property (nonatomic, strong) UIActivityIndicatorView *loadingSpinner;
@property (nonatomic, strong) UIButton *loadingRetryButton;
@property (nonatomic, strong) NSString *dataDirectory;
@property (nonatomic, strong) NSString *backendPath;
@property (nonatomic, strong) NSURL *pendingExportURL;
@property (nonatomic) pid_t backendPID;
@property (nonatomic) BOOL importPickerActive;
@property (nonatomic) BOOL bridgeInjected;
@property (nonatomic, strong) NSMutableArray<NSString *> *runtimeLogLines;
@property (nonatomic, strong) dispatch_queue_t logQueue;
@property (nonatomic, strong) dispatch_source_t logTimer;
@property (nonatomic, strong) NSString *documentsDirectory;
@property (nonatomic, strong) NSString *logsDirectory;
@property (nonatomic, strong) NSString *liveLogPath;
@property (nonatomic, strong) NSString *backendLogPath;
@property (nonatomic, strong) NSString *backendDebugLogPath;
@property (nonatomic, strong) NSDateFormatter *logDateFormatter;

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.backendPID = -1;
    self.runtimeLogLines = [NSMutableArray array];
    self.logQueue = dispatch_queue_create("com.cfdata.web.log", DISPATCH_QUEUE_SERIAL);
    self.logDateFormatter = [[NSDateFormatter alloc] init];
    self.logDateFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    self.logDateFormatter.timeZone = [NSTimeZone localTimeZone];
    self.logDateFormatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ";

    [self configureDataDirectory];
    [self configureLoggingDirectories];
    [self logEvent:@"info" source:@"app" detail:@"viewDidLoad"];
    [self configureWebView];
    [self configureLoadingOverlay];
    [self startLogPump];
    [self startBackend];
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    if (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
        return UIStatusBarStyleLightContent;
    }
    return UIStatusBarStyleDarkContent;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    [self setNeedsStatusBarAppearanceUpdate];
}

- (void)configureDataDirectory {
    NSArray<NSString *> *paths =
        NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *root = paths.firstObject ?: NSTemporaryDirectory();
    NSString *directory = [root stringByAppendingPathComponent:@"cfdata"];

    NSError *error = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions : @0755}
                                                    error:&error];
    self.dataDirectory = directory;
}

- (void)configureLoggingDirectories {
    NSArray<NSString *> *paths =
        NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    self.documentsDirectory = paths.firstObject ?: NSTemporaryDirectory();
    self.logsDirectory =
        [self.documentsDirectory stringByAppendingPathComponent:@"cfdata-logs"];
    self.liveLogPath =
        [self.logsDirectory stringByAppendingPathComponent:@"cfdata-live.log"];
    self.backendLogPath =
        [self.dataDirectory stringByAppendingPathComponent:@"cfdata.log"];
    self.backendDebugLogPath =
        [self.dataDirectory stringByAppendingPathComponent:@"cfdata-debug.log"];

    NSError *error = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:self.logsDirectory
                              withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions : @0755}
                                                    error:&error];
    if (error != nil) {
        NSLog(@"Unable to create CFData log directory: %@", error);
    }

    UIDevice *device = [UIDevice currentDevice];
    [self logEvent:@"info"
             source:@"app"
             detail:[NSString stringWithFormat:
                                  @"device=%@ system=%@ %@ model=%@ documents=%@",
                                  device.name, device.systemName, device.systemVersion,
                                  device.model, self.documentsDirectory]];
}

- (void)logEvent:(NSString *)level source:(NSString *)source detail:(NSString *)detail {
    if (level.length == 0) {
        level = @"info";
    }
    if (source.length == 0) {
        source = @"unknown";
    }
    if (detail.length == 0) {
        detail = @"";
    }
    detail = [detail stringByReplacingOccurrencesOfString:@"\n" withString:@" | "];
    NSString *timestamp = [self.logDateFormatter stringFromDate:[NSDate date]];
    NSString *line = [NSString stringWithFormat:@"[%@] level=%@ source=%@ detail=%@",
                                                timestamp, level, source, detail];

    dispatch_async(self.logQueue, ^{
        @synchronized(self.runtimeLogLines) {
            [self.runtimeLogLines addObject:line];
            if (self.runtimeLogLines.count > 800) {
                [self.runtimeLogLines removeObjectsInRange:NSMakeRange(
                    0, self.runtimeLogLines.count - 800)];
            }
        }
        [self writeLiveLogSnapshotLocked];
    });
}

- (NSString *)buildLogSnapshotLocked {
    NSMutableString *snapshot = [NSMutableString string];
    [snapshot appendString:@"=== CFData iOS runtime log ===\n"];
    @synchronized(self.runtimeLogLines) {
        [snapshot appendString:[self.runtimeLogLines componentsJoinedByString:@"\n"]];
    }
    [snapshot appendString:@"\n\n=== backend stdout ===\n"];
    [snapshot appendString:[self readTextTailAtPath:self.backendLogPath maxBytes:512 * 1024]];
    [snapshot appendString:@"\n\n=== backend debug log ===\n"];
    [snapshot appendString:
        [self readTextTailAtPath:self.backendDebugLogPath maxBytes:512 * 1024]];
    [snapshot appendString:@"\n"];
    return snapshot;
}

- (NSString *)readTextTailAtPath:(NSString *)path maxBytes:(NSUInteger)maxBytes {
    if (path.length == 0 || maxBytes == 0) {
        return @"";
    }
    NSError *error = nil;
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:
                              [NSURL fileURLWithPath:path]
                                                               error:&error];
    if (handle == nil) {
        return @"";
    }

    NSDictionary *attributes =
        [[NSFileManager defaultManager] attributesOfItemAtPath:path error:&error];
    if (attributes == nil) {
        [handle closeFile];
        return @"";
    }
    unsigned long long fileSize =
        ((NSNumber *)attributes[NSFileSize]).unsignedLongLongValue;
    unsigned long long offset = fileSize > maxBytes ? fileSize - maxBytes : 0;
    [handle seekToFileOffset:offset];
    NSData *data = [handle readDataToEndOfFile];
    [handle closeFile];
    if (data.length == 0) {
        return @"";
    }

    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text == nil) {
        text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    }
    return text ?: @"";
}

- (void)writeLiveLogSnapshotLocked {
    NSString *snapshot = [self buildLogSnapshotLocked];
    NSData *data = [snapshot dataUsingEncoding:NSUTF8StringEncoding];
    [data writeToFile:self.liveLogPath atomically:YES];
}

- (void)startLogPump {
    if (self.logTimer != nil) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    self.logTimer =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                               dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(self.logTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                              2 * NSEC_PER_SEC, 250 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(self.logTimer, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (self == nil) {
            return;
        }
        dispatch_async(self.logQueue, ^{
            [self writeLiveLogSnapshotLocked];
        });
    });
    dispatch_resume(self.logTimer);
}

- (void)stopLogPump {
    if (self.logTimer != nil) {
        dispatch_source_cancel(self.logTimer);
        self.logTimer = nil;
    }
}

- (void)flushLogsToDocuments {
    if (self.logQueue == nil || self.logsDirectory.length == 0) {
        return;
    }
    dispatch_sync(self.logQueue, ^{
        [self writeLiveLogSnapshotLocked];
        NSString *timestamp =
            [self.logDateFormatter stringFromDate:[NSDate date]];
        NSString *safeTimestamp =
            [timestamp stringByReplacingOccurrencesOfString:@":" withString:@"-"];
        safeTimestamp = [safeTimestamp stringByReplacingOccurrencesOfString:@"." withString:@"-"];
        NSString *path = [self.logsDirectory stringByAppendingPathComponent:
            [NSString stringWithFormat:@"cfdata-%@.log", safeTimestamp]];
        NSString *snapshot = [self buildLogSnapshotLocked];
        [[snapshot dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:YES];
    });
}

- (void)configureWebView {
    WKUserContentController *contentController = [[WKUserContentController alloc] init];
    [contentController addScriptMessageHandler:self name:kBridgeMessageName];

    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    configuration.userContentController = contentController;
    configuration.websiteDataStore = [WKWebsiteDataStore defaultDataStore];
    configuration.allowsInlineMediaPlayback = YES;

    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
    self.webView.navigationDelegate = self;
    self.webView.UIDelegate = self;
    self.webView.allowsBackForwardNavigationGestures = YES;
    self.webView.scrollView.contentInsetAdjustmentBehavior =
        UIScrollViewContentInsetAdjustmentNever;
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.webView];

    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.webView.topAnchor constraintEqualToAnchor:safeArea.topAnchor],
        [self.webView.bottomAnchor constraintEqualToAnchor:safeArea.bottomAnchor],
    ]];
}

- (void)configureLoadingOverlay {
    self.loadingOverlay = [[UIView alloc] initWithFrame:CGRectZero];
    self.loadingOverlay.backgroundColor = [UIColor systemBackgroundColor];
    self.loadingOverlay.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.loadingOverlay];

    self.loadingTitle = [[UILabel alloc] init];
    self.loadingTitle.text = @"CFData";
    self.loadingTitle.font = [UIFont boldSystemFontOfSize:24];
    self.loadingTitle.textColor = [UIColor labelColor];
    self.loadingTitle.textAlignment = NSTextAlignmentCenter;

    self.loadingMessage = [[UILabel alloc] init];
    self.loadingMessage.text = @"正在启动本地服务...";
    self.loadingMessage.font = [UIFont systemFontOfSize:14];
    self.loadingMessage.textColor = [UIColor secondaryLabelColor];
    self.loadingMessage.textAlignment = NSTextAlignmentCenter;
    self.loadingMessage.numberOfLines = 0;

    self.loadingSpinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    [self.loadingSpinner startAnimating];

    self.loadingRetryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.loadingRetryButton setTitle:@"重试" forState:UIControlStateNormal];
    [self.loadingRetryButton addTarget:self
                                action:@selector(retryStartup:)
                      forControlEvents:UIControlEventTouchUpInside];
    self.loadingRetryButton.hidden = YES;

    UIStackView *stackView =
        [[UIStackView alloc] initWithArrangedSubviews:@[
            self.loadingTitle, self.loadingMessage, self.loadingSpinner,
            self.loadingRetryButton
        ]];
    stackView.axis = UILayoutConstraintAxisVertical;
    stackView.alignment = UIStackViewAlignmentCenter;
    stackView.spacing = 12;
    stackView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.loadingOverlay addSubview:stackView];

    [NSLayoutConstraint activateConstraints:@[
        [self.loadingOverlay.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.loadingOverlay.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.loadingOverlay.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.loadingOverlay.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [stackView.centerXAnchor constraintEqualToAnchor:self.loadingOverlay.centerXAnchor],
        [stackView.centerYAnchor constraintEqualToAnchor:self.loadingOverlay.centerYAnchor],
        [stackView.leadingAnchor
            constraintGreaterThanOrEqualToAnchor:self.loadingOverlay.leadingAnchor
                                        constant:32],
        [stackView.trailingAnchor
            constraintLessThanOrEqualToAnchor:self.loadingOverlay.trailingAnchor
                                     constant:-32],
    ]];
}

- (void)startBackend {
    [self logEvent:@"info" source:@"app" detail:@"startBackend requested"];
    [self stopBackend];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.loadingRetryButton.hidden = YES;
        self.loadingTitle.text = @"CFData";
        self.loadingTitle.textColor = [UIColor labelColor];
        self.loadingSpinner.hidden = NO;
        [self.loadingSpinner startAnimating];
    });

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self logEvent:@"info" source:@"startup" detail:@"backend startup worker started"];
        [self updateLoadingMessage:@"正在准备本地服务..."];

        NSError *error = nil;
        NSString *backendPath = [self prepareBackendBinary:&error];
        if (backendPath == nil) {
            [self logEvent:@"error" source:@"startup"
                    detail:[NSString stringWithFormat:@"prepareBackendBinary failed: %@",
                                                      error.localizedDescription ?: @"unknown error"]];
            [self showStartupError:@"启动失败" message:error.localizedDescription];
            return;
        }

        if (chdir(self.dataDirectory.fileSystemRepresentation) != 0) {
            [self logEvent:@"error" source:@"startup"
                    detail:[NSString stringWithFormat:@"chdir failed errno=%d (%s)", errno,
                                                      strerror(errno)]];
            [self showStartupError:@"启动失败"
                           message:[NSString stringWithFormat:@"无法设置工作目录: %s",
                                                                 strerror(errno)]];
            return;
        }
        [self logEvent:@"info" source:@"startup"
                detail:[NSString stringWithFormat:@"backend working directory is %@",
                                                  self.dataDirectory]];

        pid_t backendPID = [self spawnBackend:backendPath error:&error];
        if (backendPID < 0) {
            [self logEvent:@"error" source:@"startup"
                    detail:[NSString stringWithFormat:@"spawnBackend failed: %@",
                                                      error.localizedDescription ?: @"unknown error"]];
            [self showStartupError:@"启动失败" message:error.localizedDescription];
            return;
        }

        @synchronized(self) {
            self.backendPID = backendPID;
        }

        [self updateLoadingMessage:@"正在连接本地服务..."];
        [self logEvent:@"info" source:@"startup"
                detail:[NSString stringWithFormat:@"waiting for backend pid=%d port=%d",
                                                  backendPID, kBackendPort]];
        if (![self waitForBackend]) {
            NSString *message = @"本地服务启动超时";
            NSString *logTail = [self backendLogTail];
            if (logTail.length > 0) {
                message = [message stringByAppendingFormat:@"\n\n%@", logTail];
            }
            [self logEvent:@"error" source:@"startup"
                    detail:[NSString stringWithFormat:@"backend health wait failed: %@", message]];
            [self showStartupError:@"启动失败" message:message];
            return;
        }

        [self logEvent:@"info" source:@"startup"
                detail:@"backend health check passed; collecting backend diagnostics"];
        [self collectBackendDiagnostics];

        dispatch_async(dispatch_get_main_queue(), ^{
            [self logEvent:@"info" source:@"webview"
                    detail:[NSString stringWithFormat:@"loading http://127.0.0.1:%d", kBackendPort]];
            [self updateLoadingMessage:@"正在加载界面..."];
            NSURL *url =
                [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%d",
                                                                  kBackendPort]];
            [self.webView loadRequest:[NSURLRequest requestWithURL:url]];
        });
    });
}

- (NSString *)prepareBackendBinary:(NSError **)error {
    NSURL *bundledURL =
        [[NSBundle mainBundle] URLForResource:kBackendBinaryName withExtension:nil];
    if (bundledURL == nil) {
        [self logEvent:@"error" source:@"startup" detail:@"bundled cfdata binary not found"];
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"CFDataIOS"
                                         code:1
                                     userInfo:@{
                                         NSLocalizedDescriptionKey :
                                             @"应用包中未找到内置后端"
                                     }];
        }
        return nil;
    }

    NSString *targetPath =
        [self.dataDirectory stringByAppendingPathComponent:kBackendBinaryName];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    [fileManager removeItemAtPath:targetPath error:nil];
    if (![fileManager copyItemAtPath:bundledURL.path toPath:targetPath error:error]) {
        [self logEvent:@"error" source:@"startup"
                detail:[NSString stringWithFormat:@"copy backend failed: %@",
                                                  *error == nil ? @"unknown error"
                                                               : (*error).localizedDescription]];
        return nil;
    }
    if (![fileManager setAttributes:@{NSFilePosixPermissions : @0755}
                       ofItemAtPath:targetPath
                               error:error]) {
        [self logEvent:@"error" source:@"startup"
                detail:[NSString stringWithFormat:@"chmod backend failed: %@",
                                                  *error == nil ? @"unknown error"
                                                               : (*error).localizedDescription]];
        return nil;
    }

    self.backendPath = targetPath;
    [self logEvent:@"info" source:@"startup"
            detail:[NSString stringWithFormat:@"backend copied from %@ to %@",
                                              bundledURL.path, targetPath]];
    return targetPath;
}

- (pid_t)spawnBackend:(NSString *)backendPath error:(NSError **)error {
    setenv("CFDATA_IOS", "1", 1);
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);

    NSString *logPath =
        [self.dataDirectory stringByAppendingPathComponent:@"cfdata.log"];
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO,
                                     logPath.fileSystemRepresentation,
                                     O_WRONLY | O_CREAT | O_TRUNC, 0644);
    posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO);

    char *argv[] = {
        (char *)backendPath.fileSystemRepresentation,
        "-host",
        "127.0.0.1",
        "-port",
        (char *)[@(kBackendPort).stringValue UTF8String],
        "-debug=all",
        "-skipgeo",
        NULL,
    };

    pid_t backendPID = -1;
    int status = posix_spawn(&backendPID, backendPath.fileSystemRepresentation, &actions,
                             NULL, argv, *_NSGetEnviron());
    posix_spawn_file_actions_destroy(&actions);

    if (status != 0) {
        [self logEvent:@"error" source:@"startup"
                detail:[NSString stringWithFormat:@"posix_spawn returned %d (%s)", status,
                                                      strerror(status)]];
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:status
                                     userInfo:@{
                                         NSLocalizedDescriptionKey :
                                             [NSString stringWithFormat:@"启动后端失败: %s",
                                                                        strerror(status)]
                                     }];
        }
        return -1;
    }
    [self logEvent:@"info" source:@"startup"
            detail:[NSString stringWithFormat:@"spawned backend pid=%d path=%@ flags=-debug=all,-skipgeo",
                                              backendPID, backendPath]];
    return backendPID;
}

- (BOOL)waitForBackend {
    NSURLSessionConfiguration *configuration =
        [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForRequest = 0.8;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:45];
    NSUInteger attempt = 0;
    while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
        if (![self isBackendRunning]) {
            [self logEvent:@"error" source:@"startup"
                    detail:@"backend process exited before health check passed"];
            return NO;
        }
        attempt++;

        NSURL *healthURL = [NSURL URLWithString:[NSString
            stringWithFormat:@"http://127.0.0.1:%d/healthz", kBackendPort]];
        NSHTTPURLResponse *response = nil;
        NSError *requestError = nil;
        NSData *data = [self synchronousDataAtURL:healthURL
                                          session:session
                                         response:&response
                                            error:&requestError];
        BOOL ready = requestError == nil && response.statusCode == 200 && data.length > 0;
        if (!ready) {
            NSURL *fallbackURL = [NSURL URLWithString:[NSString
                stringWithFormat:@"http://127.0.0.1:%d/favicon.png", kBackendPort]];
            response = nil;
            requestError = nil;
            data = [self synchronousDataAtURL:fallbackURL
                                      session:session
                                     response:&response
                                        error:&requestError];
            ready = requestError == nil && response.statusCode == 200 && data.length > 0;
        }

        if (ready) {
            [self logEvent:@"info" source:@"startup"
                    detail:[NSString stringWithFormat:@"health check passed on attempt %lu",
                                                      (unsigned long)attempt]];
            return YES;
        }
        if (attempt == 1 || attempt % 15 == 0) {
            [self logEvent:@"warning" source:@"startup"
                    detail:[NSString stringWithFormat:
                                      @"health check attempt=%lu status=%ld error=%@",
                                      (unsigned long)attempt, (long)response.statusCode,
                                      requestError.localizedDescription ?: @"none"]];
        }
        usleep(250 * 1000);
    }
    [self logEvent:@"error" source:@"startup"
            detail:[NSString stringWithFormat:@"health check timed out after %lu attempts",
                                              (unsigned long)attempt]];
    return NO;
}

- (NSData *)synchronousDataAtURL:(NSURL *)url
                         session:(NSURLSession *)session
                        response:(NSHTTPURLResponse **)response
                           error:(NSError **)error {
    __block NSData *resultData = nil;
    __block NSHTTPURLResponse *resultResponse = nil;
    __block NSError *resultError = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [[session dataTaskWithURL:url
            completionHandler:^(NSData *data, NSURLResponse *taskResponse,
                                NSError *taskError) {
                resultData = data;
                resultResponse = (NSHTTPURLResponse *)taskResponse;
                resultError = taskError;
                dispatch_semaphore_signal(semaphore);
            }] resume];
    dispatch_semaphore_wait(semaphore,
                            dispatch_time(DISPATCH_TIME_NOW,
                                          (int64_t)(1.5 * NSEC_PER_SEC)));
    if (response != NULL) {
        *response = resultResponse;
    }
    if (error != NULL) {
        *error = resultError;
    }
    return resultData;
}

- (void)collectBackendDiagnostics {
    NSURLSessionConfiguration *configuration =
        [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForRequest = 1.5;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];

    NSURL *diagnosticsURL = [NSURL URLWithString:[NSString
        stringWithFormat:@"http://127.0.0.1:%d/__cfdata/diagnostics", kBackendPort]];
    NSHTTPURLResponse *diagnosticsResponse = nil;
    NSError *diagnosticsError = nil;
    NSData *diagnosticsData = [self synchronousDataAtURL:diagnosticsURL
                                                 session:session
                                                response:&diagnosticsResponse
                                                   error:&diagnosticsError];
    if (diagnosticsData.length > 0) {
        NSString *path = [self.logsDirectory
            stringByAppendingPathComponent:@"cfdata-backend-diagnostics.json"];
        [diagnosticsData writeToFile:path atomically:YES];
        NSString *text = [[NSString alloc] initWithData:diagnosticsData
                                               encoding:NSUTF8StringEncoding] ?: @"";
        NSUInteger maxLength = MIN(text.length, 1200);
        [self logEvent:@"info" source:@"backend_diagnostics"
                detail:[NSString stringWithFormat:@"status=%ld bytes=%lu content=%@",
                                                  (long)diagnosticsResponse.statusCode,
                                                  (unsigned long)diagnosticsData.length,
                                                  [text substringToIndex:maxLength]]];
    } else {
        [self logEvent:@"warning" source:@"backend_diagnostics"
                detail:[NSString stringWithFormat:@"fetch failed status=%ld error=%@",
                                                  (long)diagnosticsResponse.statusCode,
                                                  diagnosticsError.localizedDescription ?: @"none"]];
    }

    NSURL *logURL = [NSURL URLWithString:[NSString
        stringWithFormat:@"http://127.0.0.1:%d/__cfdata/log", kBackendPort]];
    NSHTTPURLResponse *logResponse = nil;
    NSError *logError = nil;
    NSData *logData = [self synchronousDataAtURL:logURL
                                         session:session
                                        response:&logResponse
                                           error:&logError];
    if (logData.length > 0) {
        NSString *path = [self.logsDirectory
            stringByAppendingPathComponent:@"cfdata-backend-runtime.log"];
        [logData writeToFile:path atomically:YES];
        NSString *text = [[NSString alloc] initWithData:logData
                                               encoding:NSUTF8StringEncoding] ?: @"";
        NSUInteger maxLength = MIN(text.length, 1200);
        [self logEvent:@"info" source:@"backend_runtime_log"
                detail:[NSString stringWithFormat:@"status=%ld bytes=%lu content=%@",
                                                  (long)logResponse.statusCode,
                                                  (unsigned long)logData.length,
                                                  [text substringToIndex:maxLength]]];
    } else {
        [self logEvent:@"warning" source:@"backend_runtime_log"
                detail:[NSString stringWithFormat:@"fetch failed status=%ld error=%@",
                                                  (long)logResponse.statusCode,
                                                  logError.localizedDescription ?: @"none"]];
    }
}

- (BOOL)isBackendRunning {
    pid_t backendPID = -1;
    @synchronized(self) {
        backendPID = self.backendPID;
    }
    if (backendPID <= 0) {
        return NO;
    }
    if (kill(backendPID, 0) == 0) {
        return YES;
    }
    return errno == EPERM;
}

- (NSString *)backendLogTail {
    NSString *logPath =
        [self.dataDirectory stringByAppendingPathComponent:@"cfdata.log"];
    NSError *error = nil;
    NSString *content =
        [NSString stringWithContentsOfFile:logPath
                                  encoding:NSUTF8StringEncoding
                                     error:&error];
    if (content.length == 0) {
        return nil;
    }

    NSArray<NSString *> *lines =
        [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSMutableArray<NSString *> *filtered = [NSMutableArray array];
    for (NSString *line in lines) {
        if (line.length > 0) {
            [filtered addObject:line];
        }
    }
    if (filtered.count == 0) {
        return nil;
    }
    NSUInteger lineCount = MIN(filtered.count, 6);
    NSArray<NSString *> *tail = [filtered
        subarrayWithRange:NSMakeRange(filtered.count - lineCount, lineCount)];
    return [tail componentsJoinedByString:@"\n"];
}

- (void)stopBackend {
    pid_t backendPID = -1;
    @synchronized(self) {
        backendPID = self.backendPID;
        self.backendPID = -1;
    }
    if (backendPID > 0) {
        kill(backendPID, SIGTERM);
    }
}

- (void)updateLoadingMessage:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.loadingMessage.text = message;
    });
}

- (void)showStartupError:(NSString *)title message:(NSString *)message {
    [self logEvent:@"error" source:@"ui"
            detail:[NSString stringWithFormat:@"title=%@ message=%@", title,
                                              message ?: @"none"]];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.loadingOverlay.hidden = NO;
        self.loadingOverlay.alpha = 1;
        self.loadingTitle.text = title;
        self.loadingTitle.textColor = [UIColor systemRedColor];
        self.loadingMessage.text = message;
        [self.loadingSpinner stopAnimating];
        self.loadingSpinner.hidden = YES;
        self.loadingRetryButton.hidden = NO;
    });
}

- (void)retryStartup:(UIButton *)sender {
    [self startBackend];
}

- (void)hideLoadingOverlay {
    [self logEvent:@"info" source:@"ui" detail:@"native loading overlay hidden"];
    [UIView animateWithDuration:0.18 animations:^{
        self.loadingOverlay.alpha = 0;
    } completion:^(BOOL finished) {
        self.loadingOverlay.hidden = YES;
    }];
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                    decisionHandler:
                        (void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = navigationAction.request.URL;
    [self logEvent:@"info" source:@"webview"
            detail:[NSString stringWithFormat:@"decidePolicy url=%@ type=%ld",
                                              url.absoluteString,
                                              (long)navigationAction.navigationType]];
    if ([url.host isEqualToString:@"127.0.0.1"] ||
        [url.host isEqualToString:@"localhost"]) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }

    if (navigationAction.navigationType == WKNavigationTypeLinkActivated) {
        [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }

    decisionHandler(WKNavigationActionPolicyAllow);
}

- (void)webView:(WKWebView *)webView
    didStartProvisionalNavigation:(WKNavigation *)navigation {
    [self logEvent:@"info" source:@"webview"
            detail:[NSString stringWithFormat:@"didStartProvisionalNavigation url=%@",
                                              webView.URL.absoluteString ?: @"none"]];
}

- (void)webView:(WKWebView *)webView didCommitNavigation:(WKNavigation *)navigation {
    [self logEvent:@"info" source:@"webview"
            detail:[NSString stringWithFormat:@"didCommitNavigation url=%@",
                                              webView.URL.absoluteString ?: @"none"]];
}

- (void)webView:(WKWebView *)webView
    didFinishNavigation:(WKNavigation *)navigation {
    [self logEvent:@"info" source:@"webview"
            detail:[NSString stringWithFormat:@"didFinishNavigation url=%@",
                                              webView.URL.absoluteString ?: @"none"]];
    NSString *stateScript = @"JSON.stringify({readyState:document.readyState,"
                             "title:document.title,url:location.href,"
                             "hasBody:!!document.body,"
                             "bodyText:document.body?document.body.innerText.slice(0,120):''})";
    [self.webView evaluateJavaScript:stateScript
                   completionHandler:^(id result, NSError *error) {
                       [self logEvent:(error == nil ? @"info" : @"warning")
                               source:@"webview"
                               detail:[NSString stringWithFormat:@"pageState=%@ error=%@",
                                                                 result ?: @"none",
                                                                 error.localizedDescription ?: @"none"]];
                   }];
    [self injectExportBridge];
    [self hideLoadingOverlay];
}

- (void)webView:(WKWebView *)webView
    didFailProvisionalNavigation:(WKNavigation *)navigation
                       withError:(NSError *)error {
    [self logEvent:@"error" source:@"webview"
            detail:[NSString stringWithFormat:@"didFailProvisionalNavigation url=%@ code=%ld domain=%@ error=%@",
                                              webView.URL.absoluteString ?: @"none",
                                              (long)error.code, error.domain,
                                              error.localizedDescription ?: @"none"]];
    [self showStartupError:@"加载失败" message:error.localizedDescription];
}

- (void)webView:(WKWebView *)webView
    didFailNavigation:(WKNavigation *)navigation
            withError:(NSError *)error {
    [self logEvent:@"error" source:@"webview"
            detail:[NSString stringWithFormat:@"didFailNavigation url=%@ code=%ld domain=%@ error=%@",
                                              webView.URL.absoluteString ?: @"none",
                                              (long)error.code, error.domain,
                                              error.localizedDescription ?: @"none"]];
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    [self logEvent:@"error" source:@"webview" detail:@"web content process terminated"];
    [self showStartupError:@"加载失败" message:@"网页进程已退出，请点击重试"];
}

- (void)injectExportBridge {
    if (self.bridgeInjected) {
        return;
    }
    self.bridgeInjected = YES;

    NSString *script = @"(function(){"
                         "if(window.__cfdataIosExport)return;"
                         "window.__cfdataIosExport=true;"
                         "window.CFDataAndroid=window.CFDataAndroid||{};"
                         "window.CFDataAndroid.saveTextFile=function(name,content){"
                         "window.webkit.messageHandlers.cfdata.postMessage("
                         "{action:'saveTextFile',name:name,content:content});"
                         "};"
                         "window.__cfdataOriginalFileInputClick=HTMLInputElement.prototype.click;"
                         "HTMLInputElement.prototype.click=function(){"
                         "if(this.id==='nsbFileInput'){"
                         "window.webkit.messageHandlers.cfdata.postMessage("
                         "{action:'pickTextFile'});return;}"
                         "return window.__cfdataOriginalFileInputClick.call(this);};"
                         "window.__cfdataHandlePickedFile=function(name,content){"
                         "var input=document.getElementById('nsbFileInput');if(!input)return;"
                         "var file=new File([String(content)],String(name),{type:'text/plain'});"
                         "if(typeof DataTransfer!=='undefined'){"
                         "var dt=new DataTransfer();dt.items.add(file);"
                         "try{Object.defineProperty(input,'files',{value:dt.files,"
                         "configurable:true});}catch(e){}"
                         "}else{"
                         "var files=[file];files.item=function(i){return this[i];};"
                         "try{Object.defineProperty(input,'files',{value:files,"
                         "configurable:true});}catch(e){}"
                         "}"
                         "input.dispatchEvent(new Event('change',{bubbles:true}));"
                         "};"
                         "window.downloadFile=function(content,nameBase,ext){"
                         "var ts=new Date().toISOString().replace(/[-:T]/g,'')"
                         ".split('.')[0];"
                         "var name=(nameBase||'cfdata-results')+'_'+ts+'.'+(ext||'txt');"
                         "window.CFDataAndroid.saveTextFile(name,String(content||''));"
                         "};"
                         "})();";
    [self.webView evaluateJavaScript:script completionHandler:nil];
}

#pragma mark - WKScriptMessageHandler

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:kBridgeMessageName] ||
        ![message.body isKindOfClass:[NSDictionary class]]) {
        return;
    }

    NSDictionary *body = (NSDictionary *)message.body;
    NSString *action = body[@"action"];
    if ([action isEqualToString:@"saveTextFile"]) {
        [self saveTextFileNamed:body[@"name"] content:body[@"content"]];
    } else if ([action isEqualToString:@"pickTextFile"]) {
        [self presentImportPicker];
    }
}

- (void)presentImportPicker {
    NSArray<UTType *> *contentTypes = @[UTTypeText, UTTypeCommaSeparatedText];
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:contentTypes
                                                                   asCopy:YES];
    picker.allowsMultipleSelection = NO;
    picker.delegate = self;
    self.importPickerActive = YES;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)handlePickedFileAtURL:(NSURL *)fileURL {
    NSString *name = fileURL.lastPathComponent.length > 0
                         ? fileURL.lastPathComponent
                         : @"upload.txt";
    NSError *readError = nil;
    BOOL didStartAccessing = [fileURL startAccessingSecurityScopedResource];
    NSData *data = [NSData dataWithContentsOfURL:fileURL options:0 error:&readError];
    if (didStartAccessing) {
        [fileURL stopAccessingSecurityScopedResource];
    }

    NSString *content =
        [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (content == nil) {
        content = [[NSString alloc] initWithData:data
                                         encoding:NSISOLatin1StringEncoding];
    }
    if (content == nil) {
        content = @"";
    }

    NSError *jsonError = nil;
    NSData *nameJSON = [NSJSONSerialization dataWithJSONObject:name
                                                       options:0
                                                         error:&jsonError];
    NSData *contentJSON = [NSJSONSerialization dataWithJSONObject:content
                                                          options:0
                                                            error:&jsonError];
    if (nameJSON == nil || contentJSON == nil) {
        return;
    }

    NSString *script = [NSString stringWithFormat:@"window.__cfdataHandlePickedFile(%@,%@);",
                                                  [[NSString alloc] initWithData:nameJSON
                                                                         encoding:NSUTF8StringEncoding],
                                                  [[NSString alloc] initWithData:contentJSON
                                                                         encoding:NSUTF8StringEncoding]];
    [self.webView evaluateJavaScript:script completionHandler:nil];
}

- (void)saveTextFileNamed:(NSString *)fileName content:(NSString *)content {
    NSString *safeName = [self sanitizeFileName:fileName];
    NSString *path =
        [NSTemporaryDirectory() stringByAppendingPathComponent:safeName];
    NSURL *fileURL = [NSURL fileURLWithPath:path isDirectory:NO];

    const char bom[] = {(char)0xEF, (char)0xBB, (char)0xBF};
    NSMutableData *data =
        [NSMutableData dataWithBytes:bom length:sizeof(bom)];
    [data appendData:[(content ?: @"") dataUsingEncoding:NSUTF8StringEncoding]];
    if (![data writeToURL:fileURL atomically:YES]) {
        return;
    }

    self.pendingExportURL = fileURL;
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForExportingURLs:@[fileURL]
                                                              asCopy:YES];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (NSString *)sanitizeFileName:(NSString *)fileName {
    NSString *name = fileName.length > 0 ? fileName : @"cfdata-results.txt";
    NSCharacterSet *invalid =
        [NSCharacterSet characterSetWithCharactersInString:@"\\/:*?\"<>|"];
    name = [[name componentsSeparatedByCharactersInSet:invalid]
        componentsJoinedByString:@"_"];
    return name.length > 0 ? name : @"cfdata-results.txt";
}

#pragma mark - UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (self.importPickerActive) {
        self.importPickerActive = NO;
        if (urls.count > 0) {
            [self handlePickedFileAtURL:urls.firstObject];
        }
    } else {
        [self cleanupPendingExport];
    }
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    self.importPickerActive = NO;
    [self cleanupPendingExport];
}

- (void)cleanupPendingExport {
    if (self.pendingExportURL != nil) {
        [[NSFileManager defaultManager] removeItemAtURL:self.pendingExportURL error:nil];
        self.pendingExportURL = nil;
    }
}

- (void)dealloc {
    [self stopLogPump];
    [self flushLogsToDocuments];
    [self stopBackend];
    if (self.webView != nil) {
        [self.webView.configuration.userContentController
            removeScriptMessageHandlerForName:kBridgeMessageName];
    }
}

@end
