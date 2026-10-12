// SonyGrab's front end: the part macOS sees as the running app.
//
// All the real work is done by launch.sh and the Python server it turns into.
// This keeps a Dock icon up for as long as that server runs, brings the
// browser tab back when the icon is clicked, and asks the server to stop on
// Quit. When the server stops by itself, the app goes with it.
//
// Built by build_app.sh. Nothing here knows about cards, photos or updates.

#import <Cocoa/Cocoa.h>

// The launcher and the server both find their files through $HOME, so this
// does too. NSHomeDirectory() ignores it, which would split a test run in two.
static NSString *HomeDir(void) {
    const char *h = getenv("HOME");
    return (h && *h) ? @(h) : NSHomeDirectory();
}

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong) NSTask *server;
@property BOOL askNothing;      // quit without the "still importing" question
@end

@implementation AppDelegate

// The server writes its address, token included, as the second line of this.
- (NSURL *)serverURL {
    NSString *path = [HomeDir() stringByAppendingPathComponent:@".sonygrab.pid"];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    if (lines.count < 2) return nil;
    NSString *url = [lines[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return url.length ? [NSURL URLWithString:url] : nil;
}

- (void)showPage:(id)sender {
    NSURL *url = [self serverURL];
    if (!url) return;
    // $BROWSER overrides the default browser, as it does for the server.
    const char *browser = getenv("BROWSER");
    if (browser && *browser) {
        NSTask *t = [NSTask new];
        t.executableURL = [NSURL fileURLWithPath:@(browser)];
        t.arguments = @[url.absoluteString];
        [t launchAndReturnError:nil];
    } else {
        [[NSWorkspace sharedWorkspace] openURL:url];
    }
}

// One short request to the server's own API. Returns nil if it does not answer.
- (NSData *)call:(NSString *)path method:(NSString *)method {
    NSURL *base = [self serverURL];
    if (!base) return nil;
    NSURLComponents *parts = [NSURLComponents componentsWithURL:base resolvingAgainstBaseURL:NO];
    NSString *token = nil;
    for (NSURLQueryItem *q in parts.queryItems) {
        if ([q.name isEqualToString:@"t"]) token = q.value;
    }
    parts.query = nil;
    parts.path = path;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:parts.URL];
    req.HTTPMethod = method;
    req.timeoutInterval = 3;
    [req setValue:token forHTTPHeaderField:@"X-Token"];
    if ([method isEqualToString:@"POST"]) {
        req.HTTPBody = [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    }

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.connectionProxyDictionary = @{};        // this is a loopback call, never via a proxy
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
    __block NSData *answer = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        if (!e) answer = data;
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC));
    [session invalidateAndCancel];
    return answer;
}

- (BOOL)serverBusy {
    NSData *data = [self call:@"/api/ping" method:@"GET"];
    if (!data) return NO;
    NSDictionary *d = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [d isKindOfClass:NSDictionary.class] && [d[@"busy"] boolValue];
}

- (void)buildMenu {
    NSMenu *bar = [NSMenu new];
    NSMenuItem *appItem = [bar addItemWithTitle:@"" action:nil keyEquivalent:@""];
    NSMenu *menu = [NSMenu new];
    NSMenuItem *show = [menu addItemWithTitle:@"Show SonyGrab" action:@selector(showPage:) keyEquivalent:@"o"];
    show.target = self;
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Quit SonyGrab" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = menu;
    NSApp.mainMenu = bar;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    [self buildMenu];

    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:@"/bin/bash"];
    t.arguments = @[[[NSBundle mainBundle] pathForResource:@"launch" ofType:@"sh"]];
    __weak AppDelegate *me = self;
    t.terminationHandler = ^(NSTask *task) {
        // The server is gone: Quit on the page, the idle timeout, or it never
        // started. Either way there is nothing left for a Dock icon to mean.
        dispatch_async(dispatch_get_main_queue(), ^{
            me.askNothing = YES;
            [NSApp terminate:nil];
        });
    };
    if (![t launchAndReturnError:nil]) {
        [NSApp terminate:nil];
        return;
    }
    self.server = t;
}

// A click on the Dock icon, or a second double-click on the app.
- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)visible {
    [self showPage:nil];
    return NO;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)app {
    if (!self.server.isRunning) return NSTerminateNow;

    // Same question the page's own Quit button asks.
    if (!self.askNothing && [self serverBusy]) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"SonyGrab is still importing.";
        alert.informativeText = @"Quitting now stops the import. Files already finished are kept.";
        [alert addButtonWithTitle:@"Keep Importing"];
        [alert addButtonWithTitle:@"Quit"];
        [NSApp activateIgnoringOtherApps:YES];
        if ([alert runModal] == NSAlertFirstButtonReturn) return NSTerminateCancel;
    }

    // Ask nicely first, so an import in flight is cancelled the way the page
    // would cancel it. The server takes a couple of seconds to wind down.
    [self call:@"/api/quit" method:@"POST"];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:6];
    while (self.server.isRunning && deadline.timeIntervalSinceNow > 0) {
        [NSThread sleepForTimeInterval:0.1];
    }
    if (self.server.isRunning) [self.server terminate];
    return NSTerminateNow;
}

@end

static AppDelegate *gDelegate;
static dispatch_source_t gTermSource;
static void ignore(int sig) {}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        gDelegate = [AppDelegate new];
        app.delegate = gDelegate;

        // A plain "kill" should shut down as tidily as Quit does. The handler
        // only exists to stop the default action; a handler, unlike SIG_IGN,
        // is not passed on to the server this app starts.
        signal(SIGTERM, ignore);
        gTermSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(gTermSource, ^{
            gDelegate.askNothing = YES;
            [NSApp terminate:nil];
        });
        dispatch_resume(gTermSource);

        [app run];
    }
    return 0;
}
