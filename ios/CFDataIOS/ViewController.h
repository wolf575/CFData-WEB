#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface ViewController : UIViewController
    <WKNavigationDelegate,
     WKUIDelegate,
     WKScriptMessageHandler,
     UIDocumentPickerDelegate>

- (void)stopBackend;
- (void)flushLogsToDocuments;
+ (void)writeBootstrapLog;

@end
