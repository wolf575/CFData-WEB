#import "ViewController.h"

#import <crt_externs.h>
#import <errno.h>
#import <fcntl.h>
#import <signal.h>
#import <spawn.h>
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

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.backendPID = -1;

    [self configureDataDirectory];
    [self configureWebView];
    [self configureLoadingOverlay];
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
    [self stopBackend];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.loadingRetryButton.hidden = YES;
        self.loadingTitle.text = @"CFData";
        self.loadingTitle.textColor = [UIColor labelColor];
        self.loadingSpinner.hidden = NO;
        [self.loadingSpinner startAnimating];
    });

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self updateLoadingMessage:@"正在准备本地服务..."];

        NSError *error = nil;
        NSString *backendPath = [self prepareBackendBinary:&error];
        if (backendPath == nil) {
            [self showStartupError:@"启动失败" message:error.localizedDescription];
            return;
        }

        if (chdir(self.dataDirectory.fileSystemRepresentation) != 0) {
            [self showStartupError:@"启动失败"
                           message:[NSString stringWithFormat:@"无法设置工作目录: %s",
                                                                 strerror(errno)]];
            return;
        }

        pid_t backendPID = [self spawnBackend:backendPath error:&error];
        if (backendPID < 0) {
            [self showStartupError:@"启动失败" message:error.localizedDescription];
            return;
        }

        @synchronized(self) {
            self.backendPID = backendPID;
        }

        [self updateLoadingMessage:@"正在连接本地服务..."];
        if (![self waitForBackend]) {
            NSString *message = @"本地服务启动超时";
            NSString *logTail = [self backendLogTail];
            if (logTail.length > 0) {
                message = [message stringByAppendingFormat:@"\n\n%@", logTail];
            }
            [self showStartupError:@"启动失败" message:message];
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
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
        return nil;
    }
    if (![fileManager setAttributes:@{NSFilePosixPermissions : @0755}
                       ofItemAtPath:targetPath
                              error:error]) {
        return nil;
    }

    self.backendPath = targetPath;
    return targetPath;
}

- (pid_t)spawnBackend:(NSString *)backendPath error:(NSError **)error {
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
        NULL,
    };

    pid_t backendPID = -1;
    int status = posix_spawn(&backendPID, backendPath.fileSystemRepresentation, &actions,
                             NULL, argv, *_NSGetEnviron());
    posix_spawn_file_actions_destroy(&actions);

    if (status != 0) {
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
    return backendPID;
}

- (BOOL)waitForBackend {
    NSURL *healthURL = [NSURL URLWithString:[NSString
        stringWithFormat:@"http://127.0.0.1:%d/favicon.png", kBackendPort]];
    NSURLSessionConfiguration *configuration =
        [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForRequest = 0.8;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:45];
    while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
        if (![self isBackendRunning]) {
            return NO;
        }
        __block BOOL ready = NO;
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        [[session dataTaskWithURL:healthURL
                completionHandler:^(NSData *data, NSURLResponse *response,
                                    NSError *error) {
                    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
                    ready = error == nil && httpResponse.statusCode < 500;
                    dispatch_semaphore_signal(semaphore);
                }] resume];
        dispatch_semaphore_wait(semaphore,
                                dispatch_time(DISPATCH_TIME_NOW,
                                              (int64_t)(1.0 * NSEC_PER_SEC)));
        if (ready) {
            return YES;
        }
        usleep(250 * 1000);
    }
    return NO;
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
    didFinishNavigation:(WKNavigation *)navigation {
    [self injectExportBridge];
    [self hideLoadingOverlay];
}

- (void)webView:(WKWebView *)webView
    didFailProvisionalNavigation:(WKNavigation *)navigation
                       withError:(NSError *)error {
    [self showStartupError:@"加载失败" message:error.localizedDescription];
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
    [self stopBackend];
    if (self.webView != nil) {
        [self.webView.configuration.userContentController
            removeScriptMessageHandlerForName:kBridgeMessageName];
    }
}

@end
