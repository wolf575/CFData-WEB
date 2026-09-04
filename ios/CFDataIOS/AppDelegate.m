#import "AppDelegate.h"

#import "ViewController.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [ViewController writeBootstrapLog];
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.rootViewController = [[ViewController alloc] init];
    self.window.rootViewController = self.rootViewController;
    [self.window makeKeyAndVisible];
    return YES;
}

- (void)applicationWillTerminate:(UIApplication *)application {
    [self.rootViewController flushLogsToDocuments];
    [self.rootViewController stopBackend];
}

- (void)applicationWillResignActive:(UIApplication *)application {
    [self.rootViewController flushLogsToDocuments];
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    [self.rootViewController flushLogsToDocuments];
}

@end
