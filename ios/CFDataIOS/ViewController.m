#import "ViewController.h"

#import <arpa/inet.h>
#import <crt_externs.h>
#import <dispatch/dispatch.h>
#import <errno.h>
#import <fcntl.h>
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
static NSString *const kDiagnosticVersion = @"1.0.5";
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
@property (nonatomic) BOOL webSocketWatchdogScheduled;
@property (nonatomic) BOOL loadingOverlayHidden;
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
    self.webSocketWatchdogScheduled = NO;
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

    // Every event is fsync'ed before returning to the caller. This keeps a
    // useful trace even if applicationWillTerminate never gets a chance to run.
    [self appendRuntimeLineImmediately:line];
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
    [snapshot appendFormat:@"home=%@\ntemp=%@\nlogDirectories=%@\nbackendPID=%d\nexitStatus=%d\nexitObserved=%@\nexitDetail=%@\npageLoaded=%@\nwebSocketOpened=%@\n\n",
     NSHomeDirectory(), NSTemporaryDirectory(),
     [self.logDirectories componentsJoinedByString:@"\n"],
     self.backendPID, self.backendExitStatus,
     self.backendExitObserved ? @"YES" : @"NO",
     self.backendExitDetail ?: @"none",
     self.pageLoadedSignalReceived ? @"YES" : @"NO",
     self.webSocketOpenedSignalReceived ? @"YES" : @"NO"];
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

- (NSString *)runtimeDiagnosticScript {
    return @"(function(){"
            "if(window.__cfdataIOSDiagnosticsInstalled)return;"
            "window.__cfdataIOSDiagnosticsInstalled=true;"
            "window.__cfdataIOSWebSocketState='none';"
            "function report(kind,detail){"
            "detail=String(detail||'').slice(0,2000);"
            "try{if(window.webkit&&window.webkit.messageHandlers&&"
            "window.webkit.messageHandlers.cfdata){"
            "window.webkit.messageHandlers.cfdata.postMessage("
            "{action:'runtimeDiagnostic',kind:kind,detail:detail});}}catch(e){}"
            "}"
            "function safeSummary(prefix,error){"
            "try{return prefix+' '+(error&&error.message?error.message:String(error));}"
            "catch(e){return prefix;}"
            "}"
            "report('lifecycle','document_start userAgent='+navigator.userAgent);"
            "window.addEventListener('error',function(event){"
            "report('error',safeSummary('window_error line='+(event.lineno||0)+"
            "' col='+(event.colno||0),event.error||event.message));"
            "},true);"
            "window.addEventListener('unhandledrejection',function(event){"
            "report('error',safeSummary('unhandledrejection',event.reason));"
            "});"
            "document.addEventListener('DOMContentLoaded',function(){"
            "report('lifecycle','dom_content_loaded');"
            "window.setTimeout(function(){"
            "var text='';"
            "try{text=document.body&&document.body.innerText?"
            "document.body.innerText.slice(0,200):'';}catch(e){}"
            "report('page_state','readyState='+document.readyState+"
            "' title='+document.title+' text='+text);"
            "},500);"
            "});"
            "window.addEventListener('load',function(){"
            "report('lifecycle','window_load');"
            "});"
            "var NativeWebSocket=window.WebSocket;"
            "var WrappedWebSocket=function(url,protocols){"
            "var socket;"
            "try{socket=protocols?new NativeWebSocket(url,protocols):"
            "new NativeWebSocket(url);}"
            "catch(error){report('websocket',safeSummary('create_failed',error));"
            "throw error;}"
            "report('websocket','create '+url);"
            "socket.addEventListener('open',function(){"
            "window.__cfdataIOSWebSocketState='open';"
            "report('websocket','open');"
            "});"
            "socket.addEventListener('close',function(event){"
            "window.__cfdataIOSWebSocketState='closed';"
            "report('websocket','close code='+(event&&event.code)+"
            "' reason='+(event&&event.reason));"
            "});"
            "socket.addEventListener('error',function(){"
            "window.__cfdataIOSWebSocketState='error';"
            "report('websocket','error');"
            "});"
            "return socket;"
            "};"
            "if(NativeWebSocket){"
            "WrappedWebSocket.prototype=NativeWebSocket.prototype;"
            "WrappedWebSocket.CONNECTING=NativeWebSocket.CONNECTING;"
            "WrappedWebSocket.OPEN=NativeWebSocket.OPEN;"
            "WrappedWebSocket.CLOSING=NativeWebSocket.CLOSING;"
            "WrappedWebSocket.CLOSED=NativeWebSocket.CLOSED;"
            "window.WebSocket=WrappedWebSocket;"
            "}"
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

- (void)startBackend {
    [self logEvent:@"info" source:@"app" detail:@"startBackend requested"];
    [self stopBackend];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.loadingOverlayHidden = NO;
        self.webSocketWatchdogScheduled = NO;
        self.pageLoadedSignalReceived = NO;
        self.webSocketOpenedSignalReceived = NO;
        self.backendExitObserved = NO;
        self.backendExitStatus = 0;
        self.backendExitDetail = @"none";
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
            [self scheduleStartupWatchdog];
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
        self.loadingOverlayHidden = NO;
        self.loadingOverlay.hidden = NO;
        self.loadingOverlay.alpha = 1;
        self.loadingTitle.text = title;
        self.loadingTitle.textColor = [UIColor systemRedColor];
        self.loadingMessage.text = message;
        self.loadingDiagnosticLabel.text =
            [NSString stringWithFormat:@"版本 %@ | 错误 | %@ | 可点击复制或导出日志",
                                       kDiagnosticVersion, title ?: @"启动失败"];
        [self.loadingSpinner stopAnimating];
        self.loadingSpinner.hidden = YES;
        self.loadingRetryButton.hidden = NO;
    });
}

- (void)retryStartup:(UIButton *)sender {
    [self startBackend];
}

- (void)scheduleStartupWatchdog {
    if (self.webSocketWatchdogScheduled) {
        return;
    }
    self.webSocketWatchdogScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.loadingOverlayHidden || self.webSocketOpenedSignalReceived) {
            return;
        }
        NSString *state = self.pageLoadedSignalReceived
            ? @"pageLoaded=YES webSocketOpen=NO"
            : @"pageLoaded=NO webSocketOpen=NO";
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
    [self.webView evaluateJavaScript:@"!!window.__cfdataIOSDiagnosticsInstalled"
                   completionHandler:^(id result, NSError *error) {
                       [self logEvent:error == nil ? @"info" : @"warning"
                               source:@"webview"
                               detail:[NSString stringWithFormat:
                                                 @"runtimeDiagnosticInstalled=%@ error=%@",
                                                 result ?: @"none",
                                                 error.localizedDescription ?: @"none"]];
                   }];
    [self updateLoadingMessage:@"页面已载入，正在等待界面连接..."];
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
            if ([detail hasPrefix:@"open"]) {
                self.webSocketOpenedSignalReceived = YES;
                [self hideLoadingOverlay];
            } else if ([detail hasPrefix:@"create"]) {
                [self updateLoadingMessage:@"WebSocket 正在创建..."];
            } else if ([detail hasPrefix:@"close"] && self.loadingDiagnosticLabel != nil) {
                self.loadingDiagnosticLabel.text =
                    [NSString stringWithFormat:@"版本 %@ | WebSocket 已关闭 | %@",
                                               kDiagnosticVersion, detail];
            } else if ([detail hasPrefix:@"error"] && self.loadingDiagnosticLabel != nil) {
                self.loadingDiagnosticLabel.text =
                    [NSString stringWithFormat:@"版本 %@ | WebSocket 错误 | %@",
                                               kDiagnosticVersion, detail];
            }
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
    [self stopLogPump];
    [self flushLogsToDocuments];
    [self stopBackend];
    if (self.webView != nil) {
        [self.webView.configuration.userContentController
            removeScriptMessageHandlerForName:kBridgeMessageName];
    }
}

@end
