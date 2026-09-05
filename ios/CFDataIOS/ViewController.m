#import "ViewController.h"

#import <arpa/inet.h>
#import <crt_externs.h>
#import <dispatch/dispatch.h>
#import <errno.h>
#import <fcntl.h>
#import <math.h>
#import <netinet/in.h>
#import <poll.h>
#import <signal.h>
#import <spawn.h>
#import <stdlib.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <sys/wait.h>
#import <unistd.h>

static NSString *const kBackendBinaryName = @"cfdata";
static NSString *const kBridgeMessageName = @"cfdata";
static NSString *const kDiagnosticVersion = @"1.0.11";
static NSString *const kLiveLogFileName = @"cfdata-live.log";
static NSString *const kLastLogFileName = @"cfdata-last.log";
static NSString *const kSystemLogDirectory = @"/var/mobile/Documents/cfdata-logs";
static NSString *const kSystemRootLogPath = @"/var/mobile/Documents/cfdata-live.log";
static const int kBackendPort = 13335;

static BOOL CFDataCreateParentDirectory(NSString *path) {
    NSString *parent = [path stringByDeletingLastPathComponent];
    if (parent.length == 0 || [parent isEqualToString:path]) {
        return NO;
    }
    NSError *error = nil;
    BOOL created = [[NSFileManager defaultManager] createDirectoryAtPath:parent
                                             withIntermediateDirectories:YES
                                                              attributes:@{NSFilePosixPermissions : @0755}
                                                                   error:&error];
    return created;
}

static BOOL CFDataWriteAll(int fd, const void *bytes, size_t length) {
    const char *buffer = bytes;
    size_t written = 0;
    while (written < length) {
        ssize_t result = write(fd, buffer + written, length - written);
        if (result < 0) {
            if (errno == EINTR) {
                continue;
            }
            return NO;
        }
        written += (size_t)result;
    }
    return YES;
}

static void CFDataWriteStringToPath(NSString *content, NSString *path) {
    if (path.length == 0) {
        return;
    }
    CFDataCreateParentDirectory(path);
    NSData *data = [content dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length == 0) {
        data = [@"" dataUsingEncoding:NSUTF8StringEncoding];
    }
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        NSLog(@"CFData log open failed %@ errno=%d (%s)", path, errno, strerror(errno));
        return;
    }
    CFDataWriteAll(fd, data.bytes, data.length);
    fsync(fd);
    close(fd);
}

static void CFDataAppendStringToPath(NSString *content, NSString *path) {
    if (path.length == 0) {
        return;
    }
    CFDataCreateParentDirectory(path);
    NSData *data = [content dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length == 0) {
        return;
    }
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) {
        return;
    }
    CFDataWriteAll(fd, data.bytes, data.length);
    CFDataWriteAll(fd, "\n", 1);
    fsync(fd);
    close(fd);
}

@interface ViewController ()

@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) UIView *loadingOverlay;
@property (nonatomic, strong) UIView *diagnosticBar;
@property (nonatomic, strong) UILabel *diagnosticBarStatusLabel;
@property (nonatomic, strong) UIButton *diagnosticBarCopyButton;
@property (nonatomic, strong) UIButton *diagnosticBarExportButton;
@property (nonatomic, strong) UIButton *diagnosticBarRetryButton;
@property (nonatomic, strong) UILabel *loadingTitle;
@property (nonatomic, strong) UILabel *loadingMessage;
@property (nonatomic, strong) UILabel *loadingDiagnosticLabel;
@property (nonatomic, strong) UIActivityIndicatorView *loadingSpinner;
@property (nonatomic, strong) UIButton *loadingRetryButton;
@property (nonatomic, strong) UIButton *loadingCopyButton;
@property (nonatomic, strong) UIButton *loadingExportButton;
@property (nonatomic, strong) NSString *dataDirectory;
@property (nonatomic, strong) NSString *backendPath;
@property (nonatomic, strong) NSURL *pendingExportURL;
@property (nonatomic) pid_t backendPID;
@property (nonatomic) int backendExitStatus;
@property (nonatomic) BOOL backendExitObserved;
@property (nonatomic, strong) NSString *backendExitDetail;
@property (nonatomic) BOOL importPickerActive;
@property (nonatomic) BOOL bridgeInjected;
@property (nonatomic) BOOL pageLoadedSignalReceived;
@property (nonatomic) BOOL webSocketOpenedSignalReceived;
@property (nonatomic) BOOL pageContentReadySignalReceived;
@property (nonatomic) BOOL webSocketWatchdogScheduled;
@property (nonatomic) BOOL contentHealthMonitorScheduled;
@property (nonatomic, strong) dispatch_source_t contentHealthMonitorTimer;
@property (nonatomic) BOOL webSocketFallbackCheckScheduled;
@property (nonatomic) NSUInteger healthyWithoutWebSocketProbeCount;
@property (nonatomic) NSUInteger postHideReloadCount;
@property (nonatomic) BOOL loadingOverlayHidden;
@property (nonatomic) BOOL startupFailureOverlayVisible;
@property (nonatomic) NSUInteger webViewProbeCount;
@property (nonatomic) NSUInteger emptyContentProbeCount;
@property (nonatomic) BOOL startupSnapshotCaptured;
@property (nonatomic, strong) NSString *lastStartupSnapshotPath;
@property (nonatomic) NSUInteger startupGeneration;
@property (nonatomic, strong) NSMutableArray<NSString *> *runtimeLogLines;
@property (nonatomic, strong) dispatch_queue_t logQueue;
@property (nonatomic, strong) dispatch_source_t logTimer;
@property (nonatomic, strong) NSString *documentsDirectory;
@property (nonatomic, strong) NSString *logsDirectory;
@property (nonatomic, strong) NSArray<NSString *> *logDirectories;
@property (nonatomic, strong) NSString *liveLogPath;
@property (nonatomic, strong) NSString *backendLogPath;
@property (nonatomic, strong) NSString *backendDebugLogPath;
@property (nonatomic, strong) NSDateFormatter *logDateFormatter;

@end

@implementation ViewController

+ (void)writeBootstrapLog {
    NSString *home = NSHomeDirectory();
    NSString *temp = NSTemporaryDirectory();
    NSString *bundlePath = NSBundle.mainBundle.bundlePath;
    NSString *documents =
        NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)
            .firstObject ?: @"";
    NSString *message = [NSString stringWithFormat:
        @"CFData iOS %@ process bootstrap\n"
        @"time=%@\nuid=%d\nhome=%@\ntemp=%@\nbundle=%@\ndocuments=%@\n",
        kDiagnosticVersion,
        [NSDate date].description,
        getuid(),
        home ?: @"none",
        temp ?: @"none",
        bundlePath ?: @"none",
        documents];

    NSString *systemBootPath =
        [kSystemLogDirectory stringByAppendingPathComponent:@"cfdata-boot.log"];
    CFDataWriteStringToPath(message, systemBootPath);
    if (documents.length > 0) {
        CFDataWriteStringToPath(message,
            [[documents stringByAppendingPathComponent:@"cfdata-logs"]
                stringByAppendingPathComponent:@"cfdata-boot.log"]);
    }
    CFDataWriteStringToPath(message,
        @"/var/mobile/Documents/cfdata-boot.log");
    NSLog(@"%@", message);
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.backendPID = -1;
    self.backendExitStatus = 0;
    self.backendExitObserved = NO;
    self.backendExitDetail = @"none";
    self.pageLoadedSignalReceived = NO;
    self.webSocketOpenedSignalReceived = NO;
    self.pageContentReadySignalReceived = NO;
    self.webSocketWatchdogScheduled = NO;
    self.contentHealthMonitorScheduled = NO;
    self.webSocketFallbackCheckScheduled = NO;
    self.healthyWithoutWebSocketProbeCount = 0;
    self.postHideReloadCount = 0;
    self.startupFailureOverlayVisible = NO;
    self.webViewProbeCount = 0;
    self.emptyContentProbeCount = 0;
    self.startupSnapshotCaptured = NO;
    self.lastStartupSnapshotPath = nil;
    self.startupGeneration = 0;
    self.runtimeLogLines = [NSMutableArray array];
    self.logQueue = dispatch_queue_create("com.cfdata.web.log", DISPATCH_QUEUE_SERIAL);
    self.logDateFormatter = [[NSDateFormatter alloc] init];
    self.logDateFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    self.logDateFormatter.timeZone = [NSTimeZone localTimeZone];
    self.logDateFormatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ";

    [self configureDataDirectory];
    [self configureLoggingDirectories];
    [self logEvent:@"info"
             source:@"app"
             detail:[NSString stringWithFormat:@"diagnosticVersion=%@", kDiagnosticVersion]];
    [self logEvent:@"info" source:@"app" detail:@"viewDidLoad"];
    [self configureWebView];
    [self configureLoadingOverlay];
    [self configureDiagnosticBar];
    [self startLogPump];
    [self startBackend];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.view bringSubviewToFront:self.diagnosticBar];
    [self logEvent:@"info"
             source:@"native_render"
             detail:[NSString stringWithFormat:
                                  @"viewDidAppear viewFrame=%@ window=%@ webViewFrame=%@"
                                  " webViewHidden=%@ overlayFrame=%@ overlayHidden=%@"
                                  " diagnosticBarFrame=%@",
                                  NSStringFromCGRect(self.view.frame),
                                  self.view.window != nil ? @"YES" : @"NO",
                                  NSStringFromCGRect(self.webView.frame),
                                  self.webView.hidden ? @"YES" : @"NO",
                                  NSStringFromCGRect(self.loadingOverlay.frame),
                                  self.loadingOverlay.hidden ? @"YES" : @"NO",
                                  NSStringFromCGRect(self.diagnosticBar.frame)]];
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

    NSMutableArray<NSString *> *logDirectories = [NSMutableArray array];
    [logDirectories addObject:self.logsDirectory];
    [logDirectories addObject:[NSTemporaryDirectory()
                                  stringByAppendingPathComponent:@"cfdata-logs"]];
    [logDirectories addObject:[self.dataDirectory
                                  stringByAppendingPathComponent:@"cfdata-logs"]];

    NSArray<NSString *> *cachePaths =
        NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    if (cachePaths.firstObject.length > 0) {
        [logDirectories addObject:[cachePaths.firstObject
                                      stringByAppendingPathComponent:@"cfdata-logs"]];
    }

    NSString *homePath = NSHomeDirectory();
    if (homePath.length > 0) {
        [logDirectories addObject:[homePath
                                      stringByAppendingPathComponent:@"Documents/cfdata-logs"]];
    }

    // TrollStore no-sandbox apps often do not expose their data container in
    // Files. These system paths are visible from "On My iPhone" on many setups.
    [logDirectories addObject:kSystemLogDirectory];
    [logDirectories addObject:@"/var/mobile/Documents"];

    NSMutableArray<NSString *> *uniqueDirectories = [NSMutableArray array];
    for (NSString *directory in logDirectories) {
        BOOL exists = NO;
        for (NSString *existing in uniqueDirectories) {
            if ([existing isEqualToString:directory]) {
                exists = YES;
                break;
            }
        }
        if (!exists) {
            [uniqueDirectories addObject:directory];
        }
    }
    self.logDirectories = [uniqueDirectories copy];

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *directoryResults = [NSMutableArray array];
    for (NSString *directory in self.logDirectories) {
        NSError *error = nil;
        BOOL created = [fileManager createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions : @0755}
                                                    error:&error];
        [directoryResults addObject:[NSString
            stringWithFormat:@"%@=%@%@", directory, created ? @"ok" : @"failed",
                             error == nil ? @"" : [NSString stringWithFormat:@":%@", error.localizedDescription]]];
    }

    CFDataWriteStringToPath(
        [NSString stringWithFormat:@"CFData iOS %@ bootstrap\nhome=%@\ntemp=%@\nlogDirectories=%@\n",
                                   kDiagnosticVersion, NSHomeDirectory(), NSTemporaryDirectory(),
                                   [directoryResults componentsJoinedByString:@"\n"]],
        [kSystemLogDirectory stringByAppendingPathComponent:@"cfdata-boot.log"]);

    UIDevice *device = [UIDevice currentDevice];
    [self logEvent:@"info"
             source:@"app"
             detail:[NSString stringWithFormat:
                                  @"device=%@ system=%@ %@ model=%@ documents=%@ logDirs=%@",
                                  device.name, device.systemName, device.systemVersion,
                                  device.model, self.documentsDirectory,
                                  [directoryResults componentsJoinedByString:@"|"]]];
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
    NSLog(@"%@", line);

    // WKScriptMessageHandler runs on the UI thread. Keep this path allocation
    // and queueing only; the log pump persists the in-memory ring on a
    // background queue, and application close flushes a timestamped file.
    if (self.logQueue == nil) {
        @synchronized(self.runtimeLogLines) {
            [self.runtimeLogLines addObject:line];
            if (self.runtimeLogLines.count > 800) {
                [self.runtimeLogLines removeObjectsInRange:NSMakeRange(
                    0, self.runtimeLogLines.count - 800)];
            }
        }
        return;
    }
    dispatch_async(self.logQueue, ^{
        @synchronized(self.runtimeLogLines) {
            [self.runtimeLogLines addObject:line];
            if (self.runtimeLogLines.count > 800) {
                [self.runtimeLogLines removeObjectsInRange:NSMakeRange(
                    0, self.runtimeLogLines.count - 800)];
            }
        }
    });
}

- (NSArray<NSString *> *)liveLogDestinationPaths {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSString *directory in self.logDirectories ?: @[]) {
        [paths addObject:[directory stringByAppendingPathComponent:kLiveLogFileName]];
    }
    [paths addObject:[kSystemLogDirectory stringByAppendingPathComponent:kLiveLogFileName]];
    [paths addObject:kSystemRootLogPath];
    return paths;
}

- (void)appendRuntimeLineImmediately:(NSString *)line {
    for (NSString *path in [self liveLogDestinationPaths]) {
        CFDataAppendStringToPath(line, path);
    }
}

- (void)writeSnapshotToPaths:(NSString *)snapshot {
    NSArray<NSString *> *paths = [self liveLogDestinationPaths];
    for (NSString *path in paths) {
        CFDataWriteStringToPath(snapshot, path);
    }
    for (NSString *directory in self.logDirectories ?: @[]) {
        CFDataWriteStringToPath(snapshot,
            [directory stringByAppendingPathComponent:kLastLogFileName]);
    }
    CFDataWriteStringToPath(snapshot,
        [kSystemLogDirectory stringByAppendingPathComponent:kLastLogFileName]);
}

- (NSString *)buildLogSnapshotLocked {
    NSMutableString *snapshot = [NSMutableString string];
    [snapshot appendString:@"=== CFData iOS runtime log ===\n"];
    [snapshot appendFormat:@"home=%@\ntemp=%@\nlogDirectories=%@\nbackendPID=%d\nexitStatus=%d\nexitObserved=%@\nexitDetail=%@\npageLoaded=%@\nwebSocketOpened=%@\npageContentReady=%@\noverlayHidden=%@\nwebSocketFallbackCheck=%@\nhealthyWithoutWSProbes=%lu\nwhiteScreenReloads=%lu\nwebViewFrame=%@\nwebViewHidden=%@\nwebViewAlpha=%@\nwebViewOpaque=%@\nwebViewInteractions=%@\nloadingOverlayFrame=%@\nloadingOverlayHidden=%@\ndiagnosticBarFrame=%@\nwindowVisible=%@\nlastStartupSnapshotPath=%@\n\n",
     NSHomeDirectory(), NSTemporaryDirectory(),
     [self.logDirectories componentsJoinedByString:@"\n"],
     self.backendPID, self.backendExitStatus,
     self.backendExitObserved ? @"YES" : @"NO",
     self.backendExitDetail ?: @"none",
     self.pageLoadedSignalReceived ? @"YES" : @"NO",
     self.webSocketOpenedSignalReceived ? @"YES" : @"NO",
     self.pageContentReadySignalReceived ? @"YES" : @"NO",
     self.loadingOverlayHidden ? @"YES" : @"NO",
     self.webSocketFallbackCheckScheduled ? @"YES" : @"NO",
     (unsigned long)self.healthyWithoutWebSocketProbeCount,
     (unsigned long)self.postHideReloadCount,
     NSStringFromCGRect(self.webView.frame),
     self.webView.hidden ? @"YES" : @"NO",
     [NSString stringWithFormat:@"%.3f", self.webView.alpha],
     self.webView.opaque ? @"YES" : @"NO",
     self.webView.userInteractionEnabled ? @"YES" : @"NO",
     NSStringFromCGRect(self.loadingOverlay.frame),
     self.loadingOverlay.hidden ? @"YES" : @"NO",
     NSStringFromCGRect(self.diagnosticBar.frame),
     self.view.window != nil ? @"YES" : @"NO",
     self.lastStartupSnapshotPath ?: @"none"];
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
    [self writeSnapshotToPaths:snapshot];
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
        [self observeBackendExitIfNeeded];
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
    if (self.logQueue == nil) {
        return;
    }
    dispatch_sync(self.logQueue, ^{
        [self writeLiveLogSnapshotLocked];
        NSString *snapshot = [self buildLogSnapshotLocked];
        NSString *timestamp =
            [self.logDateFormatter stringFromDate:[NSDate date]];
        NSString *safeTimestamp =
            [timestamp stringByReplacingOccurrencesOfString:@":" withString:@"-"];
        safeTimestamp = [safeTimestamp stringByReplacingOccurrencesOfString:@"." withString:@"-"];
        NSString *fileName = [NSString stringWithFormat:@"cfdata-%@.log", safeTimestamp];

        NSArray<NSString *> *directories = self.logDirectories.count > 0
            ? self.logDirectories
            : @[];
        for (NSString *directory in directories) {
            NSString *path = [directory stringByAppendingPathComponent:fileName];
            CFDataWriteStringToPath(snapshot, path);
        }
        CFDataWriteStringToPath(snapshot,
            [kSystemLogDirectory stringByAppendingPathComponent:fileName]);
        CFDataWriteStringToPath(snapshot,
            [kSystemLogDirectory stringByAppendingPathComponent:kLastLogFileName]);
        CFDataWriteStringToPath(snapshot, kSystemRootLogPath);
    });
}

- (void)configureWebView {
    WKUserContentController *contentController = [[WKUserContentController alloc] init];
    [contentController addScriptMessageHandler:self name:kBridgeMessageName];

    WKUserScript *diagnosticScript =
        [[WKUserScript alloc] initWithSource:[self runtimeDiagnosticScript]
                               injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                            forMainFrameOnly:YES];
    [contentController addUserScript:diagnosticScript];

    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    configuration.userContentController = contentController;
    configuration.websiteDataStore = [WKWebsiteDataStore defaultDataStore];
    configuration.allowsInlineMediaPlayback = YES;

    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
    self.webView.navigationDelegate = self;
    self.webView.UIDelegate = self;
    self.webView.allowsBackForwardNavigationGestures = YES;
    self.webView.backgroundColor = [UIColor systemBackgroundColor];
    self.webView.opaque = YES;
    self.webView.alpha = 1;
    self.webView.hidden = NO;
    self.webView.userInteractionEnabled = YES;
    self.webView.scrollView.contentInsetAdjustmentBehavior =
        UIScrollViewContentInsetAdjustmentNever;
    self.webView.scrollView.backgroundColor = [UIColor systemBackgroundColor];
    self.webView.scrollView.opaque = YES;
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

- (NSString *)runtimeDiagnosticScript {
    return @"(function(){"
            "if(window.__cfdataIOSDiagnosticsInstalled){return;}"
            "window.__cfdataIOSDiagnosticsInstalled=true;"
            "window.__cfdataIOSWebSocketState='none';"
            "window.__cfdataIOSDiagnosticStage='script_start';"
            "function report(kind,detail){"
            "var text;try{text=String(detail||'').slice(0,1400);}"
            "catch(e){text='diagnostic_detail_error';}"
            "var handler=null;"
            "try{if(window.webkit&&window.webkit.messageHandlers&&"
            "window.webkit.messageHandlers.cfdata){"
            "handler=window.webkit.messageHandlers.cfdata;}}catch(e){}"
            "if(!handler){return;}"
            "var payload={action:'runtimeDiagnostic',kind:kind,detail:text};"
            "window.setTimeout(function(){"
            "try{handler.postMessage(payload);}catch(e){}"
            "},0);"
            "}"
            "function stage(name){"
            "try{window.__cfdataIOSDiagnosticStage=name;}catch(e){}"
            "report('stage',name);"
            "}"
            "function safeSummary(prefix,error){"
            "try{return prefix+' '+(error&&error.message?error.message:String(error));}"
            "catch(e){return prefix;}"
            "}"
            "function install(name,listener){"
            "try{window.addEventListener(name,listener);stage('registered_'+name);}"
            "catch(error){report('error','register_failed name='+name+' '"
            "+safeSummary('message=',error));}"
            "}"
            "report('lifecycle','document_start userAgent='+navigator.userAgent);"
            "stage('document_start_reported');"
            "install('error',function(event){"
            "report('error',safeSummary('window_error line='+(event.lineno||0)+"
            "' col='+(event.colno||0),event.error||event.message));"
            "});"
            "install('unhandledrejection',function(event){"
            "report('error',safeSummary('unhandledrejection',event.reason));"
            "});"
            "install('DOMContentLoaded',function(){"
            "stage('dom_content_loaded');"
            "report('lifecycle','dom_content_loaded readyState='+document.readyState);"
            "window.setTimeout(function(){"
            "var text='';"
            "try{text=document.body&&document.body.innerText?"
            "document.body.innerText.slice(0,240):'';}catch(e){}"
            "report('page_state','readyState='+document.readyState+"
            "' title='+document.title+' text='+text);"
            "},500);"
            "});"
            "install('load',function(){"
            "stage('window_load');"
            "report('lifecycle','window_load');"
            "});"
            "try{report('websocket','native constructor='+"
            "(typeof window.WebSocket));}catch(error){"
            "report('error',safeSummary('websocket_type_failed',error));}"
            "stage('websocket_native');"
            "var heartbeatTicks=0;"
            "try{window.setInterval(function(){"
            "heartbeatTicks++;"
            "report('heartbeat','tick='+heartbeatTicks+' readyState='+"
            "document.readyState+' webSocketState='+"
            "window.__cfdataIOSWebSocketState+' wsReadyState='+"
            "window.__cfdataIOSWebSocketReadyState);"
            "},1000);}catch(error){report('error',safeSummary('heartbeat_failed',error));}"
            "stage('script_end');"
            "})();";
}

- (void)configureLoadingOverlay {
    self.loadingOverlay = [[UIView alloc] initWithFrame:CGRectZero];
    self.loadingOverlay.backgroundColor = [UIColor systemBackgroundColor];
    self.loadingOverlay.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.loadingOverlay];

    self.loadingTitle = [[UILabel alloc] init];
    self.loadingTitle.text = @"CFData 诊断版";
    self.loadingTitle.font = [UIFont boldSystemFontOfSize:24];
    self.loadingTitle.textColor = [UIColor labelColor];
    self.loadingTitle.textAlignment = NSTextAlignmentCenter;

    self.loadingMessage = [[UILabel alloc] init];
    self.loadingMessage.text = @"正在启动本地服务...";
    self.loadingMessage.font = [UIFont systemFontOfSize:14];
    self.loadingMessage.textColor = [UIColor secondaryLabelColor];
    self.loadingMessage.textAlignment = NSTextAlignmentCenter;
    self.loadingMessage.numberOfLines = 0;

    self.loadingDiagnosticLabel = [[UILabel alloc] init];
    self.loadingDiagnosticLabel.text =
        [NSString stringWithFormat:@"版本 %@ | 启动阶段：初始化", kDiagnosticVersion];
    self.loadingDiagnosticLabel.font = [UIFont systemFontOfSize:11];
    self.loadingDiagnosticLabel.textColor = [UIColor tertiaryLabelColor];
    self.loadingDiagnosticLabel.textAlignment = NSTextAlignmentCenter;
    self.loadingDiagnosticLabel.numberOfLines = 0;

    self.loadingSpinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    [self.loadingSpinner startAnimating];

    self.loadingRetryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.loadingRetryButton setTitle:@"重试" forState:UIControlStateNormal];
    [self.loadingRetryButton addTarget:self
                                action:@selector(retryStartup:)
                      forControlEvents:UIControlEventTouchUpInside];
    self.loadingRetryButton.hidden = YES;

    self.loadingCopyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.loadingCopyButton setTitle:@"复制诊断日志" forState:UIControlStateNormal];
    [self.loadingCopyButton addTarget:self
                               action:@selector(copyDiagnostics:)
                     forControlEvents:UIControlEventTouchUpInside];

    self.loadingExportButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.loadingExportButton setTitle:@"导出诊断日志" forState:UIControlStateNormal];
    [self.loadingExportButton addTarget:self
                                 action:@selector(exportDiagnostics:)
                       forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stackView =
        [[UIStackView alloc] initWithArrangedSubviews:@[
            self.loadingTitle, self.loadingMessage, self.loadingSpinner,
            self.loadingDiagnosticLabel, self.loadingCopyButton,
            self.loadingRetryButton,
            self.loadingExportButton
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

- (void)configureDiagnosticBar {
    self.diagnosticBar = [[UIView alloc] initWithFrame:CGRectZero];
    self.diagnosticBar.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.diagnosticBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.diagnosticBar];

    self.diagnosticBarStatusLabel = [[UILabel alloc] init];
    self.diagnosticBarStatusLabel.text =
        [NSString stringWithFormat:@"CFData %@ | 启动诊断", kDiagnosticVersion];
    self.diagnosticBarStatusLabel.font = [UIFont systemFontOfSize:11];
    self.diagnosticBarStatusLabel.textColor = [UIColor secondaryLabelColor];
    self.diagnosticBarStatusLabel.numberOfLines = 1;
    self.diagnosticBarStatusLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.diagnosticBarStatusLabel
        setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                       forAxis:UILayoutConstraintAxisHorizontal];
    [self.diagnosticBarStatusLabel
        setContentHuggingPriority:UILayoutPriorityDefaultLow
                          forAxis:UILayoutConstraintAxisHorizontal];

    self.diagnosticBarCopyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.diagnosticBarCopyButton setTitle:@"复制日志" forState:UIControlStateNormal];
    [self.diagnosticBarCopyButton addTarget:self
                                      action:@selector(copyDiagnostics:)
                            forControlEvents:UIControlEventTouchUpInside];

    self.diagnosticBarExportButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.diagnosticBarExportButton setTitle:@"导出日志" forState:UIControlStateNormal];
    [self.diagnosticBarExportButton addTarget:self
                                       action:@selector(exportDiagnostics:)
                             forControlEvents:UIControlEventTouchUpInside];

    self.diagnosticBarRetryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.diagnosticBarRetryButton setTitle:@"重试" forState:UIControlStateNormal];
    [self.diagnosticBarRetryButton addTarget:self
                                      action:@selector(retryStartup:)
                            forControlEvents:UIControlEventTouchUpInside];

    NSArray<UIButton *> *buttons = @[
        self.diagnosticBarCopyButton,
        self.diagnosticBarExportButton,
        self.diagnosticBarRetryButton
    ];
    for (UIButton *button in buttons) {
        button.titleLabel.font = [UIFont systemFontOfSize:12];
        button.contentEdgeInsets = UIEdgeInsetsMake(6, 7, 6, 7);
        [button setContentHuggingPriority:UILayoutPriorityRequired
                                  forAxis:UILayoutConstraintAxisHorizontal];
        [button setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                forAxis:UILayoutConstraintAxisHorizontal];
    }

    UIStackView *actionStack =
        [[UIStackView alloc] initWithArrangedSubviews:buttons];
    actionStack.axis = UILayoutConstraintAxisHorizontal;
    actionStack.alignment = UIStackViewAlignmentCenter;
    actionStack.distribution = UIStackViewDistributionFill;
    actionStack.spacing = 6;
    actionStack.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *barStack =
        [[UIStackView alloc] initWithArrangedSubviews:@[
            self.diagnosticBarStatusLabel,
            actionStack
        ]];
    barStack.axis = UILayoutConstraintAxisHorizontal;
    barStack.alignment = UIStackViewAlignmentCenter;
    barStack.distribution = UIStackViewDistributionFill;
    barStack.spacing = 8;
    barStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.diagnosticBar addSubview:barStack];

    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.diagnosticBar.leadingAnchor
            constraintEqualToAnchor:self.view.leadingAnchor],
        [self.diagnosticBar.trailingAnchor
            constraintEqualToAnchor:self.view.trailingAnchor],
        [self.diagnosticBar.topAnchor constraintEqualToAnchor:safeArea.topAnchor],
        [self.diagnosticBar.heightAnchor constraintEqualToConstant:46],
        [barStack.leadingAnchor
            constraintEqualToAnchor:self.diagnosticBar.leadingAnchor
                           constant:10],
        [barStack.trailingAnchor
            constraintEqualToAnchor:self.diagnosticBar.trailingAnchor
                           constant:-10],
        [barStack.centerYAnchor
            constraintEqualToAnchor:self.diagnosticBar.centerYAnchor],
    ]];

    for (NSLayoutConstraint *constraint in self.view.constraints) {
        BOOL isWebViewTop =
            (constraint.firstItem == self.webView &&
             constraint.firstAttribute == NSLayoutAttributeTop) ||
            (constraint.secondItem == self.webView &&
             constraint.secondAttribute == NSLayoutAttributeTop);
        if (isWebViewTop) {
            constraint.active = NO;
        }
    }
    [NSLayoutConstraint activateConstraints:@[
        [self.webView.topAnchor
            constraintEqualToAnchor:self.diagnosticBar.bottomAnchor],
    ]];
}

- (void)updateDiagnosticBarStatus:(NSString *)status {
    if (status.length == 0) {
        status = @"诊断状态未知";
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.diagnosticBarStatusLabel != nil) {
            self.diagnosticBarStatusLabel.text = status;
        }
    });
}

- (void)startBackend {
    [self logEvent:@"info" source:@"app" detail:@"startBackend requested"];
    NSUInteger startupGeneration = 0;
    @synchronized(self) {
        self.startupGeneration += 1;
        startupGeneration = self.startupGeneration;
    }
    [self stopBackend];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.contentHealthMonitorTimer != nil) {
            dispatch_source_cancel(self.contentHealthMonitorTimer);
            self.contentHealthMonitorTimer = nil;
        }
        self.loadingOverlayHidden = NO;
        self.loadingOverlay.hidden = NO;
        self.loadingOverlay.alpha = 1;
        self.loadingOverlay.userInteractionEnabled = YES;
        self.webSocketWatchdogScheduled = NO;
        self.webSocketFallbackCheckScheduled = NO;
        self.healthyWithoutWebSocketProbeCount = 0;
        self.postHideReloadCount = 0;
        self.webViewProbeCount = 0;
        self.emptyContentProbeCount = 0;
        self.startupSnapshotCaptured = NO;
        self.lastStartupSnapshotPath = nil;
        self.pageLoadedSignalReceived = NO;
        self.webSocketOpenedSignalReceived = NO;
        self.pageContentReadySignalReceived = NO;
        self.backendExitObserved = NO;
        self.backendExitStatus = 0;
        self.backendExitDetail = @"none";
        self.contentHealthMonitorScheduled = NO;
        self.startupFailureOverlayVisible = NO;
        self.loadingRetryButton.hidden = YES;
        self.loadingTitle.text = @"CFData";
        self.loadingTitle.textColor = [UIColor labelColor];
        self.loadingSpinner.hidden = NO;
        [self.loadingSpinner startAnimating];
        self.webView.hidden = NO;
        self.webView.alpha = 1;
        self.webView.userInteractionEnabled = YES;
        [self.view bringSubviewToFront:self.diagnosticBar];
        [self updateDiagnosticBarStatus:
            [NSString stringWithFormat:@"CFData %@ | 正在重新启动", kDiagnosticVersion]];
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
            NSURLComponents *components = [[NSURLComponents alloc] initWithString:
                [NSString stringWithFormat:@"http://127.0.0.1:%d", kBackendPort]];
            components.queryItems =
                @[[NSURLQueryItem queryItemWithName:@"ios_boot"
                                              value:[@(startupGeneration) stringValue]]];
            NSURL *url = components.URL;
            [self.webView stopLoading];
            [self.webView loadRequest:[NSURLRequest requestWithURL:url]];
            [self scheduleStartupWatchdogForGeneration:startupGeneration];
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
    NSString *portString = @(kBackendPort).stringValue;

    const char *backendPathCString = backendPath.fileSystemRepresentation;
    const char *logPathCString = logPath.fileSystemRepresentation;
    const char *portCString = portString.UTF8String;

    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO,
                                     logPathCString,
                                     O_WRONLY | O_CREAT | O_TRUNC, 0644);
    posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO);

    char *argv[] = {
        (char *)backendPathCString,
        "-host",
        "127.0.0.1",
        "-port",
        (char *)portCString,
        "-debug=all",
        "-skipgeo",
        NULL,
    };

    pid_t backendPID = -1;
    int status = posix_spawn(&backendPID, backendPathCString, &actions,
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
        [self observeBackendExitIfNeeded];
        if (![self isBackendRunning]) {
            [self logEvent:@"error" source:@"startup"
                    detail:[NSString stringWithFormat:
                                      @"backend process exited before health check passed; %@",
                                      self.backendExitDetail ?: @"unknown status"]];
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

- (void)observeBackendExitIfNeeded {
    pid_t backendPID = -1;
    @synchronized(self) {
        backendPID = self.backendPID;
    }
    if (backendPID <= 0) {
        return;
    }

    int status = 0;
    pid_t result = waitpid(backendPID, &status, WNOHANG);
    if (result != backendPID) {
        return;
    }

    NSString *detail = @"unknown";
    if (WIFEXITED(status)) {
        detail = [NSString stringWithFormat:@"exited code=%d", WEXITSTATUS(status)];
    } else if (WIFSIGNALED(status)) {
        detail = [NSString stringWithFormat:@"signaled signal=%d", WTERMSIG(status)];
    } else {
        detail = [NSString stringWithFormat:@"waitpid status=0x%x", status];
    }

    @synchronized(self) {
        if (self.backendPID == backendPID) {
            self.backendPID = -1;
        }
        self.backendExitStatus = status;
        self.backendExitObserved = YES;
        self.backendExitDetail = detail;
    }
    [self logEvent:@"error" source:@"backend_process"
            detail:[NSString stringWithFormat:@"pid=%d %@", backendPID, detail]];
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
        if (self.loadingDiagnosticLabel != nil) {
            NSString *timestamp =
                [self.logDateFormatter stringFromDate:[NSDate date]];
            self.loadingDiagnosticLabel.text =
                [NSString stringWithFormat:@"版本 %@ | %@ | %@",
                                           kDiagnosticVersion,
                                           timestamp, message ?: @"正在处理"];
        }
    });
}

- (void)showStartupError:(NSString *)title message:(NSString *)message {
    [self logEvent:@"error" source:@"ui"
            detail:[NSString stringWithFormat:@"title=%@ message=%@", title,
                                              message ?: @"none"]];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.startupFailureOverlayVisible = YES;
        self.loadingOverlayHidden = NO;
        self.loadingOverlay.hidden = NO;
        self.loadingOverlay.alpha = 1;
        self.loadingOverlay.userInteractionEnabled = YES;
        self.loadingTitle.text = title;
        self.loadingTitle.textColor = [UIColor systemRedColor];
        self.loadingMessage.text = message;
        self.loadingDiagnosticLabel.text =
            [NSString stringWithFormat:@"版本 %@ | 错误 | %@ | 可点击复制或导出日志",
                                       kDiagnosticVersion, title ?: @"启动失败"];
        [self.loadingSpinner stopAnimating];
        self.loadingSpinner.hidden = YES;
        self.loadingRetryButton.hidden = NO;
        [self.view bringSubviewToFront:self.diagnosticBar];
        [self updateDiagnosticBarStatus:
            [NSString stringWithFormat:@"CFData %@ | %@ | 日志入口可用",
                                       kDiagnosticVersion, title ?: @"错误"]];
    });
}

- (void)retryStartup:(UIButton *)sender {
    [self startBackend];
}

- (void)scheduleStartupWatchdogForGeneration:(NSUInteger)generation {
    if (self.webSocketWatchdogScheduled) {
        return;
    }
    self.webSocketWatchdogScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.loadingOverlayHidden ||
            self.startupFailureOverlayVisible ||
            self.startupGeneration != generation) {
            return;
        }
        NSString *state = self.pageLoadedSignalReceived
            ? [NSString stringWithFormat:
                  @"pageLoaded=YES webSocketOpen=%@ contentReady=%@",
                  self.webSocketOpenedSignalReceived ? @"YES" : @"NO",
                  self.pageContentReadySignalReceived ? @"YES" : @"NO"]
            : [NSString stringWithFormat:
                  @"pageLoaded=NO webSocketOpen=%@ contentReady=%@",
                  self.webSocketOpenedSignalReceived ? @"YES" : @"NO",
                  self.pageContentReadySignalReceived ? @"YES" : @"NO"];
        [self logEvent:@"error" source:@"startup_watchdog"
                detail:[NSString stringWithFormat:@"startup stuck for 15s; %@", state]];
        [self showStartupError:@"界面未完成连接"
                       message:@"页面加载超时，请点击“复制诊断日志”并把内容发给我；之后可以点击重试。"];
    });
}

- (NSString *)diagnosticSnapshotOnLogQueue {
    __block NSString *snapshot = @"";
    if (self.logQueue != nil) {
        dispatch_sync(self.logQueue, ^{
            snapshot = [self buildLogSnapshotLocked];
        });
    } else {
        snapshot = [self buildLogSnapshotLocked];
    }
    return snapshot;
}

- (void)copyDiagnostics:(UIButton *)sender {
    NSString *snapshot = [self diagnosticSnapshotOnLogQueue];
    UIPasteboard.generalPasteboard.string = snapshot;
    [self logEvent:@"info" source:@"ui"
            detail:[NSString stringWithFormat:@"diagnostic log copied (%lu bytes)",
                                              (unsigned long)snapshot.length]];

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"日志已复制"
                                            message:@"请粘贴到聊天窗口或备忘录中发给我。"
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)exportDiagnostics:(UIButton *)sender {
    [self logEvent:@"info" source:@"ui" detail:@"export diagnostics requested"];

    if (self.logQueue == nil) {
        [self showStartupError:@"导出失败" message:@"日志系统尚未初始化"];
        return;
    }

    NSString *snapshot = [self diagnosticSnapshotOnLogQueue];

    NSString *timestamp =
        [self.logDateFormatter stringFromDate:[NSDate date]];
    NSString *safeTimestamp =
        [timestamp stringByReplacingOccurrencesOfString:@":" withString:@"-"];
    safeTimestamp = [safeTimestamp stringByReplacingOccurrencesOfString:@"." withString:@"-"];
    NSString *fileName =
        [NSString stringWithFormat:@"cfdata-ios-diagnostics-%@.log", safeTimestamp];
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
    NSError *writeError = nil;
    if (![[snapshot dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path
                                                                options:NSDataWritingAtomic
                                                                  error:&writeError]) {
        [self showStartupError:@"导出失败"
                       message:writeError.localizedDescription ?: @"无法写入临时日志文件"];
        return;
    }

    self.pendingExportURL = [NSURL fileURLWithPath:path isDirectory:NO];
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForExportingURLs:@[self.pendingExportURL]
                                                               asCopy:YES];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)hideLoadingOverlay {
    if (self.loadingOverlayHidden) {
        return;
    }
    self.loadingOverlayHidden = YES;
    self.startupFailureOverlayVisible = NO;
    self.webSocketFallbackCheckScheduled = NO;
    self.loadingOverlay.userInteractionEnabled = NO;
    [self logEvent:@"info" source:@"ui" detail:@"native loading overlay hidden"];
    [self updateDiagnosticBarStatus:
        [NSString stringWithFormat:@"CFData %@ | 界面已显示 | %@",
                                   kDiagnosticVersion,
                                   self.webSocketOpenedSignalReceived
                                       ? @"WebSocket 已确认"
                                       : @"WebSocket 兼容启动"]];
    [UIView animateWithDuration:0.18 animations:^{
        self.loadingOverlay.alpha = 0;
    } completion:^(BOOL finished) {
        if (!self.startupFailureOverlayVisible) {
            self.loadingOverlay.hidden = YES;
            self.loadingOverlay.alpha = 0;
            self.loadingOverlay.userInteractionEnabled = NO;
            self.diagnosticBar.hidden = NO;
            self.diagnosticBar.alpha = 1;
            self.diagnosticBar.userInteractionEnabled = YES;
            [self.view bringSubviewToFront:self.diagnosticBar];
            [self forceWebViewRedrawAfterOverlayHidden];
            [self schedulePostHideContentHealthChecks];
        }
    }];
}

- (void)forceWebViewRedrawAfterOverlayHidden {
    self.webView.hidden = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (self == nil || self.startupFailureOverlayVisible) {
            return;
        }
        self.webView.hidden = NO;
        self.webView.alpha = 1;
        self.webView.opaque = YES;
        self.webView.userInteractionEnabled = YES;
        [self.webView setNeedsLayout];
        [self.webView layoutIfNeeded];
        [self.webView.scrollView setContentOffset:CGPointZero animated:NO];
        [self.view setNeedsLayout];
        [self.view layoutIfNeeded];
        [self.view bringSubviewToFront:self.diagnosticBar];
        [self logEvent:@"info"
                 source:@"native_render"
                 detail:[NSString stringWithFormat:
                                      @"forced redraw after overlay webViewFrame=%@"
                                      " webViewHidden=%@ webViewAlpha=%.3f"
                                      " webViewOpaque=%@ diagnosticBarFrame=%@",
                                      NSStringFromCGRect(self.webView.frame),
                                      self.webView.hidden ? @"YES" : @"NO",
                                      self.webView.alpha,
                                      self.webView.opaque ? @"YES" : @"NO",
                                      NSStringFromCGRect(self.diagnosticBar.frame)]];
        if (!self.startupSnapshotCaptured) {
            self.startupSnapshotCaptured = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self = weakSelf;
                if (self != nil && !self.startupFailureOverlayVisible) {
                    [self captureWebViewSnapshotWithReason:@"post_hide_450ms"];
                }
            });
        }
    });
}

- (void)captureWebViewSnapshotWithReason:(NSString *)reason {
    if (self.webView == nil || self.webView.superview == nil) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    [self.webView takeSnapshotWithConfiguration:nil
                              completionHandler:^(UIImage *snapshot, NSError *snapshotError) {
        __strong typeof(weakSelf) self = weakSelf;
        if (self == nil) {
            return;
        }
        NSString *timestamp =
            [self.logDateFormatter stringFromDate:[NSDate date]];
        NSString *safeTimestamp =
            [timestamp stringByReplacingOccurrencesOfString:@":" withString:@"-"];
        safeTimestamp = [safeTimestamp stringByReplacingOccurrencesOfString:@"." withString:@"-"];
        safeTimestamp = [safeTimestamp stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
        NSString *fileName =
            [NSString stringWithFormat:@"startup-%@-%@.png", reason, safeTimestamp];
        NSString *path =
            [self.logsDirectory stringByAppendingPathComponent:fileName];
        NSData *pngData = snapshot != nil ? UIImagePNGRepresentation(snapshot) : nil;
        NSError *writeError = nil;
        BOOL written = pngData.length > 0 &&
            [pngData writeToFile:path options:NSDataWritingAtomic error:&writeError];
        BOOL snapshotBlank =
            snapshot != nil && [self snapshotLooksBlank:snapshot];
        if (written) {
            self.lastStartupSnapshotPath = path;
        }
        [self logEvent:written ? @"info" : @"warning"
                 source:@"webview_snapshot"
                 detail:[NSString stringWithFormat:
                                      @"reason=%@ path=%@ bytes=%lu imageSize=%@"
                                      " blank=%@ error=%@ writeError=%@",
                                      reason ?: @"unknown",
                                      written ? path : @"none",
                                      (unsigned long)pngData.length,
                                      snapshot != nil
                                          ? NSStringFromCGSize(snapshot.size)
                                          : @"none",
                                      snapshotBlank ? @"YES" : @"NO",
                                      snapshotError.localizedDescription ?: @"none",
                                      writeError.localizedDescription ?: @"none"]];
        if (snapshotBlank) {
            [self handleBlankWebViewSnapshotAtPath:path reason:reason];
        }
    }];
}

- (BOOL)snapshotLooksBlank:(UIImage *)image {
    if (image == nil || image.CGImage == nil) {
        return NO;
    }
    const size_t sampleWidth = 24;
    const size_t sampleHeight = 32;
    const size_t bytesPerRow = sampleWidth * 4;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context =
        CGBitmapContextCreate(NULL,
                              sampleWidth,
                              sampleHeight,
                              8,
                              bytesPerRow,
                              colorSpace,
                              kCGImageAlphaPremultipliedLast |
                                  kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (context == NULL) {
        return NO;
    }
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawImage(context,
                       CGRectMake(0, 0, sampleWidth, sampleHeight),
                       image.CGImage);

    const unsigned char *pixels = CGBitmapContextGetData(context);
    double totalRed = 0;
    double totalGreen = 0;
    double totalBlue = 0;
    NSUInteger sampleCount = sampleWidth * sampleHeight;
    for (NSUInteger index = 0; index < sampleCount; index++) {
        const unsigned char *pixel = pixels + index * 4;
        totalRed += pixel[0];
        totalGreen += pixel[1];
        totalBlue += pixel[2];
    }
    double averageRed = totalRed / sampleCount;
    double averageGreen = totalGreen / sampleCount;
    double averageBlue = totalBlue / sampleCount;
    NSUInteger distinctPixels = 0;
    for (NSUInteger index = 0; index < sampleCount; index++) {
        const unsigned char *pixel = pixels + index * 4;
        double redDelta = fabs(pixel[0] - averageRed);
        double greenDelta = fabs(pixel[1] - averageGreen);
        double blueDelta = fabs(pixel[2] - averageBlue);
        double channelSpan =
            MAX(pixel[0], MAX(pixel[1], pixel[2])) -
            MIN(pixel[0], MIN(pixel[1], pixel[2]));
        if (redDelta > 14 || greenDelta > 14 || blueDelta > 14 ||
            channelSpan > 28) {
            distinctPixels++;
        }
    }
    CGContextRelease(context);
    double nearWhiteAverage =
        averageRed > 225 && averageGreen > 225 && averageBlue > 225;
    return nearWhiteAverage && distinctPixels <= 8;
}

- (void)handleBlankWebViewSnapshotAtPath:(NSString *)path
                                  reason:(NSString *)reason {
    [self logEvent:@"warning"
             source:@"webview_snapshot"
             detail:[NSString stringWithFormat:
                                  @"blank snapshot detected reason=%@ path=%@"
                                  " postHideReloadCount=%lu",
                                  reason ?: @"unknown",
                                  path ?: @"none",
                                  (unsigned long)self.postHideReloadCount]];
    if (self.postHideReloadCount > 0) {
        if (self.webView.isLoading) {
            [self logEvent:@"info"
                     source:@"webview_snapshot"
                     detail:@"blank snapshot arrived during reload; waiting for the new page before deciding failure"];
            return;
        }
        [self showStartupError:@"界面渲染异常"
                       message:@"WebView 截图仍为空白；请复制或导出日志，之后可点击重试。"];
        return;
    }

    self.postHideReloadCount = 1;
    self.emptyContentProbeCount = 0;
    self.healthyWithoutWebSocketProbeCount = 0;
    self.pageLoadedSignalReceived = NO;
    self.webSocketOpenedSignalReceived = NO;
    self.pageContentReadySignalReceived = NO;
    self.bridgeInjected = NO;
    self.startupSnapshotCaptured = NO;
    self.lastStartupSnapshotPath = nil;
    [self updateDiagnosticBarStatus:
        [NSString stringWithFormat:
            @"CFData %@ | 截图检测到白屏 | 已自动刷新一次",
            kDiagnosticVersion]];
    [self.webView reload];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (self != nil && !self.startupFailureOverlayVisible) {
            [self captureWebViewSnapshotWithReason:@"after_blank_reload"];
        }
    });
}

- (NSString *)webViewContentHealthScript {
    return @"(function(){try{"
            "function rectOf(el){if(!el||!el.getBoundingClientRect){return null;}"
            "var r=el.getBoundingClientRect();"
            "return {left:Math.round(r.left),top:Math.round(r.top),"
            "width:Math.round(r.width),height:Math.round(r.height),"
            "right:Math.round(r.right),bottom:Math.round(r.bottom)};}"
            "function safeText(value){try{return String(value||'');}"
            "catch(e){return '';}}"
            "function safeSlice(value,max){try{"
            "var chars=Array.from(String(value||''));"
            "return chars.slice(0,max).join('');}"
            "catch(e){return safeText(value).slice(0,max);}}"
            "function textOf(el){return safeText(el?el.innerText||el.textContent:'');}"
            "function styleOf(el){if(!el||!window.getComputedStyle){return null;}"
            "var s=window.getComputedStyle(el);"
            "return {backgroundColor:s.backgroundColor||'',color:s.color||'',"
            "backgroundImage:safeSlice(s.backgroundImage,220),"
            "opacity:s.opacity||'1',display:s.display||'',"
            "visibility:s.visibility||'',position:s.position||'',"
            "transform:safeSlice(s.transform,100),"
            "zIndex:s.zIndex||'',overflow:s.overflow||'',"
            "pointerEvents:s.pointerEvents||''};}"
            "var body=document.body||null;"
            "var html=document.documentElement||null;"
            "var container=null;try{container=document.querySelector('.container');}catch(e){}"
            "var elements=[];try{if(body){elements=body.querySelectorAll('*');}}catch(e){}"
            "var visibleElementCount=0,visibleTextLength=0;"
            "var viewportVisibleElementCount=0,viewportTextLength=0;"
            "function intersectsViewport(rect){return rect&&rect.width>0&&rect.height>0"
            "&&rect.right>0&&rect.bottom>0&&rect.left<window.innerWidth"
            "&&rect.top<window.innerHeight;}"
            "for(var i=0;i<elements.length&&i<800;i++){try{"
            "var el=elements[i];"
            "var style=window.getComputedStyle(el);"
            "var rect=rectOf(el);"
            "if(style.display!=='none'&&style.visibility!=='hidden'&&"
            "parseFloat(style.opacity||'1')>0&&rect&&rect.width>0&&rect.height>0){"
            "visibleElementCount++;"
            "var text=safeText(el.innerText||el.textContent||'').replace(/\\s+/g,'');"
            "visibleTextLength+=text.length;"
            "if(intersectsViewport(rect)){viewportVisibleElementCount++;"
            "viewportTextLength+=text.length;}"
            "}}catch(e){}}"
            "var htmlStyle=styleOf(html),bodyStyle=styleOf(body);"
            "var containerStyle=styleOf(container);"
            "var keyRects={};"
            "var keySelectors=['h1','#status','#btnStart','#btnOfficial','#btnNSB',"
            "'.container','#officialControls','#nsbControls'];"
            "for(var j=0;j<keySelectors.length;j++){try{"
            "var keyEl=document.querySelector(keySelectors[j]);"
            "keyRects[keySelectors[j]]=keyEl"
            "?{rect:rectOf(keyEl),style:styleOf(keyEl),text:safeSlice(textOf(keyEl),100)}"
            ":null;}catch(e){}}"
            "var cx=Math.max(1,window.innerWidth*0.5);"
            "var points=[[cx,window.innerHeight*0.22],[cx,window.innerHeight*0.45],"
            "[window.innerWidth*0.25,window.innerHeight*0.55],"
            "[window.innerWidth*0.75,window.innerHeight*0.55]];"
            "var viewportHits=[];"
            "for(var p=0;p<points.length;p++){try{"
            "var hitEl=document.elementFromPoint(Math.round(points[p][0]),"
            "Math.round(points[p][1]));"
            "if(hitEl){viewportHits.push({tag:hitEl.tagName||'',"
            "id:hitEl.id||'',"
            "className:safeSlice(hitEl.className,140),"
            "text:safeSlice(textOf(hitEl),100),rect:rectOf(hitEl),"
            "style:styleOf(hitEl)});}}catch(e){}}"
            "var visualViewport=null;"
            "try{if(window.visualViewport){visualViewport={"
            "width:window.visualViewport.width,height:window.visualViewport.height,"
            "scale:window.visualViewport.scale,"
            "offsetTop:window.visualViewport.offsetTop,"
            "offsetLeft:window.visualViewport.offsetLeft,"
            "pageTop:window.visualViewport.pageTop,"
            "pageLeft:window.visualViewport.pageLeft};}}catch(e){}"
            "var wsState=window.__cfdataIOSWebSocketState||'none';"
            "var wsReadyState='missing';"
            "try{if(typeof window.__cfdataIOSWebSocketReadyState==='number'){"
            "wsReadyState=String(window.__cfdataIOSWebSocketReadyState);}}catch(e){}"
            "try{if(typeof ws!=='undefined'&&ws&&typeof ws.readyState==='number'){"
            "wsReadyState=String(ws.readyState);}}catch(e){}"
            "return JSON.stringify({"
            "readyState:document.readyState,title:document.title,url:location.href,"
            "bodyChildren:body?body.children.length:-1,"
            "bodyText:body?safeSlice(textOf(body),600):'',"
            "bodyTextLength:body?textOf(body).length:-1,"
            "bodyHTML:body?safeSlice(body.innerHTML,600):'',"
            "bodyWidth:body?body.getBoundingClientRect().width:-1,"
            "bodyHeight:body?body.getBoundingClientRect().height:-1,"
            "scrollHeight:document.documentElement.scrollHeight,"
            "scrollY:window.scrollY||0,"
            "documentScrollTop:document.documentElement.scrollTop||0,"
            "innerWidth:window.innerWidth,innerHeight:window.innerHeight,"
            "visualViewport:visualViewport,htmlStyle:htmlStyle,"
            "bodyStyle:bodyStyle,containerStyle:containerStyle,"
            "keyRects:keyRects,viewportHits:viewportHits,"
            "visibleElementCount:visibleElementCount,"
            "visibleTextLength:visibleTextLength,"
            "viewportVisibleElementCount:viewportVisibleElementCount,"
            "viewportTextLength:viewportTextLength,"
            "webSocketState:wsState,webSocketReadyState:wsReadyState,"
            "pageBootError:window.__cfdataIOSPageBootError||'',"
            "installed:!!window.__cfdataIOSDiagnosticsInstalled,"
            "stage:window.__cfdataIOSDiagnosticStage||''"
            "});"
            "}catch(error){"
            "return JSON.stringify({probeError:String(error&&error.message?"
            "error.message:error)});"
            "}})()";
}

- (NSInteger)integerInState:(NSDictionary *)state
                        key:(NSString *)key
                  fallback:(NSInteger)fallback {
    id value = state[key];
    if ([value isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)value integerValue];
    }
    if ([value isKindOfClass:[NSString class]]) {
        return [(NSString *)value integerValue];
    }
    return fallback;
}

- (BOOL)visualStyleAllowsPainting:(NSDictionary *)style {
    if (![style isKindOfClass:[NSDictionary class]]) {
        return NO;
    }
    NSString *display = style[@"display"] ?: @"block";
    NSString *visibility = style[@"visibility"] ?: @"visible";
    NSString *opacityText = style[@"opacity"] ?: @"1";
    NSString *backgroundColor = style[@"backgroundColor"] ?: @"";
    NSString *backgroundImage = style[@"backgroundImage"] ?: @"";
    NSString *textColor = style[@"color"] ?: @"";
    double opacity = [opacityText doubleValue];
    BOOL hidden =
        [display isEqualToString:@"none"] ||
        [visibility isEqualToString:@"hidden"] ||
        [visibility isEqualToString:@"collapse"];
    BOOL transparentColor =
        backgroundColor.length == 0 ||
        [backgroundColor isEqualToString:@"transparent"] ||
        [backgroundColor containsString:@"rgba(0, 0, 0, 0)"] ||
        [backgroundColor containsString:@"rgba(0,0,0,0)"];
    BOOL hasBackground =
        (!transparentColor) ||
        (backgroundImage.length > 0 && ![backgroundImage isEqualToString:@"none"]);
    BOOL hasTextColor =
        textColor.length > 0 &&
        ![textColor isEqualToString:@"transparent"] &&
        ![textColor containsString:@"rgba(0, 0, 0, 0)"];
    return !hidden && opacity > 0.01 && hasBackground && hasTextColor;
}

- (BOOL)viewportHitsContainMeaningfulElement:(NSArray *)hits {
    if (![hits isKindOfClass:[NSArray class]]) {
        return NO;
    }
    NSSet<NSString *> *interactiveTags =
        [NSSet setWithArray:@[@"A", @"BUTTON", @"INPUT", @"SELECT", @"TEXTAREA",
                              @"LABEL", @"H1", @"H2", @"H3", @"OPTION", @"SPAN"]];
    for (NSDictionary *hit in hits) {
        if (![hit isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSString *tag = [hit[@"tag"] uppercaseString] ?: @"";
        NSString *text = hit[@"text"] ?: @"";
        NSDictionary *rect = hit[@"rect"];
        if (![rect isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        double width = [rect[@"width"] doubleValue];
        double height = [rect[@"height"] doubleValue];
        NSString *className = hit[@"className"];
        BOOL htmlRoot =
            [tag isEqualToString:@"HTML"] ||
            [tag isEqualToString:@"BODY"] ||
            ([tag isEqualToString:@"DIV"] &&
             [className isKindOfClass:[NSString class]] &&
             [className containsString:@"container"]);
        if (htmlRoot || width <= 0 || height <= 0) {
            continue;
        }
        if (text.length > 0 || [interactiveTags containsObject:tag]) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)webViewStateIndicatesHealthyContent:(NSDictionary *)state {
    NSString *readyState = state[@"readyState"];
    NSString *bodyText = state[@"bodyText"];
    NSString *bodyHTML = state[@"bodyHTML"];
    NSInteger bodyChildren = [self integerInState:state
                                             key:@"bodyChildren"
                                         fallback:-1];
    NSInteger bodyTextLength = [self integerInState:state
                                                key:@"bodyTextLength"
                                            fallback:-1];
    NSInteger visibleElementCount = [self integerInState:state
                                                     key:@"visibleElementCount"
                                                 fallback:-1];
    NSInteger visibleTextLength = [self integerInState:state
                                                   key:@"visibleTextLength"
                                               fallback:-1];
    NSInteger viewportVisibleElementCount =
        [self integerInState:state key:@"viewportVisibleElementCount" fallback:-1];
    NSInteger viewportTextLength =
        [self integerInState:state key:@"viewportTextLength" fallback:-1];
    double bodyWidth = [self integerInState:state key:@"bodyWidth" fallback:-1];
    double bodyHeight = [self integerInState:state key:@"bodyHeight" fallback:-1];
    double innerWidth = [self integerInState:state key:@"innerWidth" fallback:-1];
    double innerHeight = [self integerInState:state key:@"innerHeight" fallback:-1];

    BOOL pageIsLoaded =
        [readyState isEqualToString:@"interactive"] ||
        [readyState isEqualToString:@"complete"];
    BOOL hasBodyContent =
        bodyChildren > 0 &&
        bodyTextLength >= 8 &&
        [bodyText isKindOfClass:[NSString class]] &&
        bodyText.length > 0 &&
        [bodyHTML isKindOfClass:[NSString class]] &&
        bodyHTML.length > 0;
    BOOL hasViewportContent =
        visibleElementCount >= 3 &&
        visibleTextLength >= 8 &&
        viewportVisibleElementCount >= 2 &&
        viewportTextLength >= 8;
    BOOL hasUsableDimensions =
        bodyWidth > 1 && bodyHeight > 1 &&
        innerWidth > 1 && innerHeight > 1;
    BOOL bodyPaints =
        [self visualStyleAllowsPainting:state[@"bodyStyle"]];
    BOOL containerPaints =
        [self visualStyleAllowsPainting:state[@"containerStyle"]];
    BOOL viewportHitIsMeaningful =
        [self viewportHitsContainMeaningfulElement:state[@"viewportHits"]];
    NSDictionary *visualViewport = state[@"visualViewport"];
    BOOL viewportScaleIsUsable = YES;
    if ([visualViewport isKindOfClass:[NSDictionary class]]) {
        id scaleValue = visualViewport[@"scale"];
        if ([scaleValue isKindOfClass:[NSNumber class]] ||
            [scaleValue isKindOfClass:[NSString class]]) {
            double scale = [scaleValue doubleValue];
            viewportScaleIsUsable = scale >= 0.5 && scale <= 2;
        }
    }
    return pageIsLoaded && hasBodyContent && hasViewportContent &&
           hasUsableDimensions && bodyPaints && containerPaints &&
           viewportHitIsMeaningful && viewportScaleIsUsable;
}

- (void)processWebViewContentHealthResult:(id)result
                                    error:(NSError *)error
                                   reason:(NSString *)reason
                 allowHideWithoutWebSocket:(BOOL)allowHideWithoutWebSocket {
    (void)allowHideWithoutWebSocket;
    NSString *raw = [result isKindOfClass:[NSString class]]
        ? (NSString *)result
        : @"none";
    BOOL parsedOK = NO;
    NSDictionary *state = nil;
    if ([result isKindOfClass:[NSString class]]) {
        NSData *jsonData = [(NSString *)result
            dataUsingEncoding:NSUTF8StringEncoding];
        if (jsonData != nil) {
            id object = [NSJSONSerialization JSONObjectWithData:jsonData
                                                        options:0
                                                          error:nil];
            if ([object isKindOfClass:[NSDictionary class]]) {
                state = (NSDictionary *)object;
                parsedOK = YES;
            }
        }
    }

    NSString *webSocketReadyState = state[@"webSocketReadyState"];
    if (parsedOK &&
        !self.webSocketOpenedSignalReceived &&
        [webSocketReadyState isEqualToString:@"1"]) {
        self.webSocketOpenedSignalReceived = YES;
        [self logEvent:@"info"
                 source:@"websocket_fallback"
                 detail:@"readyState probe observed OPEN"];
        [self updateLoadingMessage:@"WebSocket 已就绪，正在确认界面内容..."];
        [self updateDiagnosticBarStatus:
            [NSString stringWithFormat:@"CFData %@ | WebSocket 已就绪",
                                       kDiagnosticVersion]];
    }

    NSDictionary *bodyStyle = state[@"bodyStyle"];
    NSDictionary *containerStyle = state[@"containerStyle"];
    NSArray *viewportHits = state[@"viewportHits"];
    NSUInteger viewportHitCount =
        [viewportHits isKindOfClass:[NSArray class]] ? viewportHits.count : 0;
    NSString *bodyStyleSummary =
        [bodyStyle isKindOfClass:[NSDictionary class]]
            ? [bodyStyle description]
            : @"none";
    NSString *containerStyleSummary =
        [containerStyle isKindOfClass:[NSDictionary class]]
            ? [containerStyle description]
            : @"none";
    [self logEvent:parsedOK ? @"info" : @"warning"
             source:@"content_health_summary"
             detail:[NSString stringWithFormat:
                                  @"reason=%@ readyState=%@ bodyChildren=%@"
                                  " bodyText=%@ viewportElements=%@ viewportText=%@"
                                  " inner=%@ scrollY=%@ scrollHeight=%@"
                                  " bodyStyle=%@ containerStyle=%@ hits=%lu vv=%@"
                                  " error=%@",
                                  reason ?: @"unknown",
                                  state[@"readyState"] ?: @"none",
                                  state[@"bodyChildren"] ?: @"none",
                                  state[@"bodyTextLength"] ?: @"none",
                                  state[@"viewportVisibleElementCount"] ?: @"none",
                                  state[@"viewportTextLength"] ?: @"none",
                                  [NSString stringWithFormat:@"%@x%@",
                                                             state[@"innerWidth"] ?: @"?",
                                                             state[@"innerHeight"] ?: @"?"],
                                  state[@"scrollY"] ?: @"none",
                                  state[@"scrollHeight"] ?: @"none",
                                  bodyStyleSummary ?: @"none",
                                  containerStyleSummary ?: @"none",
                                  (unsigned long)viewportHitCount,
                                  state[@"visualViewport"] ?: @"none",
                                  error.localizedDescription ?: @"none"]];

    NSString *loggedRaw = raw;
    if (loggedRaw.length > 6000) {
        loggedRaw = [loggedRaw substringToIndex:6000];
    }
    [self logEvent:parsedOK ? @"info" : @"warning"
             source:@"content_health"
             detail:[NSString stringWithFormat:
                                  @"reason=%@ raw=%@ error=%@",
                                  reason ?: @"unknown",
                                  loggedRaw ?: @"none",
                                  error.localizedDescription ?: @"none"]];

    if (!parsedOK) {
        return;
    }
    if (self.startupFailureOverlayVisible) {
        return;
    }

    NSString *readyState = state[@"readyState"];
    BOOL healthy = [self webViewStateIndicatesHealthyContent:state];
    if (healthy) {
        self.pageLoadedSignalReceived = YES;
        self.pageContentReadySignalReceived = YES;
        self.emptyContentProbeCount = 0;
        if (!self.loadingOverlayHidden) {
            if (self.webSocketOpenedSignalReceived) {
                [self updateLoadingMessage:@"界面内容已就绪，正在完成启动..."];
                [self hideLoadingOverlay];
                return;
            }

            if ([readyState isEqualToString:@"complete"]) {
                self.healthyWithoutWebSocketProbeCount += 1;
                if (self.healthyWithoutWebSocketProbeCount >= 2) {
                    [self logEvent:@"warning"
                             source:@"content_health"
                             detail:@"healthy page verified twice without WebSocket signal; using compatible startup fallback"];
                    [self updateLoadingMessage:
                        @"界面内容稳定，正在完成兼容启动..."];
                    [self updateDiagnosticBarStatus:
                        [NSString stringWithFormat:
                            @"CFData %@ | 页面稳定 | WebSocket 兼容启动",
                            kDiagnosticVersion]];
                    [self hideLoadingOverlay];
                    return;
                }

                [self updateLoadingMessage:
                    @"界面内容已就绪，等待 WebSocket 确认..."];
                [self updateDiagnosticBarStatus:
                    [NSString stringWithFormat:
                        @"CFData %@ | 页面正常 | 等待 WebSocket 确认",
                        kDiagnosticVersion]];
                [self scheduleWebSocketFallbackCheck];
                return;
            }

            self.healthyWithoutWebSocketProbeCount = 0;
            [self updateLoadingMessage:@"界面正在渲染，正在等待完整加载..."];
            return;
        }
        [self updateDiagnosticBarStatus:
            [NSString stringWithFormat:@"CFData %@ | 页面内容正常",
                                       kDiagnosticVersion]];
        return;
    }

    self.pageContentReadySignalReceived = NO;
    self.emptyContentProbeCount += 1;
    BOOL pageIsComplete = [readyState isEqualToString:@"complete"];

    if (self.loadingOverlayHidden && self.emptyContentProbeCount >= 2) {
        [self handleHiddenPageWhiteScreen:state reason:reason];
    } else if (!self.loadingOverlayHidden &&
               pageIsComplete &&
               self.emptyContentProbeCount >= 2) {
        [self showStartupError:@"页面内容为空"
                       message:@"页面已加载，但未检测到可见内容；请复制或导出诊断日志，之后可点击重试。"];
    } else {
        [self updateLoadingMessage:@"页面正在渲染，正在检查可见内容..."];
    }
}

- (void)scheduleWebSocketFallbackCheck {
    if (self.webSocketFallbackCheckScheduled || self.loadingOverlayHidden) {
        return;
    }
    self.webSocketFallbackCheckScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       __strong typeof(weakSelf) self = weakSelf;
                       if (self == nil) {
                           return;
                       }
                       self.webSocketFallbackCheckScheduled = NO;
                       if (self.loadingOverlayHidden ||
                           self.webSocketOpenedSignalReceived) {
                           return;
                       }
                       [self evaluateWebViewContentHealth:@"websocket_fallback_check"
                                 allowHideWithoutWebSocket:NO];
                   });
}

- (void)handleHiddenPageWhiteScreen:(NSDictionary *)state
                             reason:(NSString *)reason {
    NSString *summary = state[@"probeError"];
    if (summary.length == 0) {
        summary = [NSString stringWithFormat:
            @"readyState=%@ bodyTextLength=%@ visibleElements=%@",
            state[@"readyState"] ?: @"missing",
            state[@"bodyTextLength"] ?: @"missing",
            state[@"visibleElementCount"] ?: @"missing"];
    }
    [self logEvent:@"error"
             source:@"content_health"
             detail:[NSString stringWithFormat:
                                  @"hidden page became empty reason=%@ state=%@",
                                  reason ?: @"unknown", summary]];
    [self captureWebViewSnapshotWithReason:@"white_screen_detected"];

    if (self.postHideReloadCount == 0) {
        self.postHideReloadCount = 1;
        self.emptyContentProbeCount = 0;
        self.healthyWithoutWebSocketProbeCount = 0;
        self.pageLoadedSignalReceived = NO;
        self.webSocketOpenedSignalReceived = NO;
        self.pageContentReadySignalReceived = NO;
        self.bridgeInjected = NO;
        [self updateDiagnosticBarStatus:
            [NSString stringWithFormat:
                @"CFData %@ | 检测到白屏 | 已自动刷新一次，日志入口保持可用",
                kDiagnosticVersion]];
        [self.webView reload];
        return;
    }

    [self captureWebViewSnapshotWithReason:@"white_screen_persisted"];
    [self showStartupError:@"界面显示异常"
                   message:@"页面白屏仍持续，诊断栏可继续复制或导出日志；点击重试可重新启动。"];
    [self updateDiagnosticBarStatus:
        [NSString stringWithFormat:
            @"CFData %@ | 白屏未恢复 | 请复制诊断日志",
            kDiagnosticVersion]];
}

- (void)evaluateWebViewContentHealth:(NSString *)reason
            allowHideWithoutWebSocket:(BOOL)allowHideWithoutWebSocket {
    __weak typeof(self) weakSelf = self;
    [self.webView evaluateJavaScript:[self webViewContentHealthScript]
                   completionHandler:^(id result, NSError *error) {
                       __strong typeof(weakSelf) self = weakSelf;
                       if (self == nil) {
                           return;
                       }
                       [self processWebViewContentHealthResult:result
                                                        error:error
                                                       reason:reason
                                     allowHideWithoutWebSocket:allowHideWithoutWebSocket];
                   }];
}

- (void)schedulePostHideContentHealthChecks {
    if (self.contentHealthMonitorScheduled) {
        return;
    }
    self.contentHealthMonitorScheduled = YES;
    __block NSUInteger tick = 0;
    __weak typeof(self) weakSelf = self;
    dispatch_source_t timer =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                               dispatch_get_main_queue());
    self.contentHealthMonitorTimer = timer;
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                              2 * NSEC_PER_SEC,
                              250 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (self == nil || !self.loadingOverlayHidden) {
            return;
        }
        tick += 1;
        NSString *reason =
            [NSString stringWithFormat:@"post_hide_monitor_%lu",
                                       (unsigned long)tick];
        [self evaluateWebViewContentHealth:reason
                  allowHideWithoutWebSocket:YES];
    });
    dispatch_resume(timer);
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
    [self scheduleWebViewRuntimeProbes];
}

- (void)scheduleWebViewRuntimeProbes {
    if (self.loadingOverlayHidden) {
        return;
    }

    NSUInteger probeNumber = 0;
    @synchronized(self) {
        self.webViewProbeCount += 1;
        probeNumber = self.webViewProbeCount;
    }
    if (probeNumber > 20) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    NSString *reason = [NSString stringWithFormat:@"runtime_tick_%lu",
                                                  (unsigned long)probeNumber];
    [self.webView evaluateJavaScript:[self webViewContentHealthScript]
                   completionHandler:^(id result, NSError *error) {
                       __strong typeof(weakSelf) self = weakSelf;
                       if (self == nil || self.loadingOverlayHidden) {
                           return;
                       }
                       [self processWebViewContentHealthResult:result
                                                        error:error
                                                       reason:reason
                                     allowHideWithoutWebSocket:NO];
                   }];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       __strong typeof(weakSelf) self = weakSelf;
                       if (self != nil) {
                           [self scheduleWebViewRuntimeProbes];
                       }
                   });
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
    [self.webView evaluateJavaScript:@"!!window.__cfdataIOSDiagnosticsInstalled"
                   completionHandler:^(id result, NSError *error) {
                       [self logEvent:error == nil ? @"info" : @"warning"
                               source:@"webview"
                               detail:[NSString stringWithFormat:
                                                 @"runtimeDiagnosticInstalled=%@ error=%@",
                                                 result ?: @"none",
                                                 error.localizedDescription ?: @"none"]];
                   }];
    [self updateLoadingMessage:@"页面载入完成，正在检查界面内容..."];
    self.pageLoadedSignalReceived = YES;
    [self evaluateWebViewContentHealth:@"did_finish"
             allowHideWithoutWebSocket:NO];
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

- (void)handleRuntimeDiagnostic:(NSDictionary *)body {
    NSString *kind = body[@"kind"];
    NSString *detail = body[@"detail"];
    if (kind.length == 0) {
        kind = @"unknown";
    }
    if (detail.length == 0) {
        detail = @"none";
    }

    BOOL isError = [kind isEqualToString:@"error"];
    [self logEvent:isError ? @"error" : @"info"
             source:@"web_runtime"
             detail:[NSString stringWithFormat:@"kind=%@ detail=%@", kind, detail]];

    dispatch_async(dispatch_get_main_queue(), ^{
        if ([kind isEqualToString:@"websocket"]) {
            if ([detail hasPrefix:@"open"] || [detail hasPrefix:@"message"]) {
                self.webSocketOpenedSignalReceived = YES;
                [self updateLoadingMessage:@"WebSocket 已连接，正在确认界面内容..."];
                [self updateDiagnosticBarStatus:
                    [NSString stringWithFormat:@"CFData %@ | WebSocket 已连接",
                                               kDiagnosticVersion]];
                [self evaluateWebViewContentHealth:@"websocket_open"
                         allowHideWithoutWebSocket:NO];
            } else if ([detail hasPrefix:@"create"]) {
                [self updateLoadingMessage:@"WebSocket 正在创建..."];
                [self updateDiagnosticBarStatus:
                    [NSString stringWithFormat:@"CFData %@ | WebSocket 创建中",
                                               kDiagnosticVersion]];
            } else if ([detail hasPrefix:@"close"] && self.loadingDiagnosticLabel != nil) {
                self.loadingDiagnosticLabel.text =
                    [NSString stringWithFormat:@"版本 %@ | WebSocket 已关闭 | %@",
                                               kDiagnosticVersion, detail];
                [self updateDiagnosticBarStatus:
                    [NSString stringWithFormat:@"CFData %@ | WebSocket 已关闭",
                                               kDiagnosticVersion]];
            } else if ([detail hasPrefix:@"error"] && self.loadingDiagnosticLabel != nil) {
                self.loadingDiagnosticLabel.text =
                    [NSString stringWithFormat:@"版本 %@ | WebSocket 错误 | %@",
                                               kDiagnosticVersion, detail];
                [self updateDiagnosticBarStatus:
                    [NSString stringWithFormat:@"CFData %@ | WebSocket 错误",
                                               kDiagnosticVersion]];
            }
            return;
        }

        if ([kind isEqualToString:@"content_state"]) {
            [self evaluateWebViewContentHealth:@"page_content_state"
                     allowHideWithoutWebSocket:NO];
            return;
        }

        if ([kind isEqualToString:@"lifecycle"] && [detail hasPrefix:@"window_load"]) {
            self.pageLoadedSignalReceived = YES;
            if (!self.webSocketOpenedSignalReceived) {
                [self updateLoadingMessage:@"页面已载入，但尚未连接后端"];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                                   if (!self.webSocketOpenedSignalReceived) {
                                       [self updateLoadingMessage:
                                           @"页面已载入，但 WebSocket 尚未连接；请点击“复制诊断日志”"];
                                   }
                               });
            }
            return;
        }

        if ([kind isEqualToString:@"lifecycle"] && [detail hasPrefix:@"dom_content_loaded"]) {
            self.pageLoadedSignalReceived = YES;
            [self updateLoadingMessage:@"页面已载入，正在连接后端..."];
        }

        if (isError && self.loadingDiagnosticLabel != nil) {
            self.loadingDiagnosticLabel.text =
                [NSString stringWithFormat:@"版本 %@ | 页面错误 | %@", kDiagnosticVersion, detail];
        }
    });
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
    } else if ([action isEqualToString:@"runtimeDiagnostic"]) {
        [self handleRuntimeDiagnostic:body];
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
    if (self.contentHealthMonitorTimer != nil) {
        dispatch_source_cancel(self.contentHealthMonitorTimer);
        self.contentHealthMonitorTimer = nil;
    }
    [self stopLogPump];
    [self flushLogsToDocuments];
    [self stopBackend];
    if (self.webView != nil) {
        [self.webView.configuration.userContentController
            removeScriptMessageHandlerForName:kBridgeMessageName];
    }
}

@end
