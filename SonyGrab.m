// SonyGrab's front end: the part macOS sees as the running app.
//
// All the real work is done by launch.sh and the Python server it turns into.
// This puts that server's page in a window of its own, keeps the Dock icon up
// for as long as the server runs, and asks the server to stop when the window
// is closed or the app is quit. When the server stops by itself, the app goes
// with it.
//
// Built by build_app.sh. Nothing here knows about cards, photos or updates.

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include <signal.h>

// The launcher and the server both find their files through $HOME, so this
// does too. NSHomeDirectory() ignores it, which would split a test run in two.
static NSString *HomeDir(void) {
    const char *h = getenv("HOME");
    return (h && *h) ? @(h) : NSHomeDirectory();
}

// One line in the log the launcher and the server already write to.
static void Log(NSString *line) {
    NSString *path = [HomeDir() stringByAppendingPathComponent:@"Library/Logs/SonyGrab.log"];
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd < 0) return;
    NSData *data = [[NSString stringWithFormat:@"front end: %@\n", line] dataUsingEncoding:NSUTF8StringEncoding];
    write(fd, data.bytes, data.length);
    close(fd);
}

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate>
@property (strong) NSTask *launcher;    // launch.sh, which becomes the server
@property (strong) NSWindow *window;
@property (strong) WKWebView *web;
@property (strong) NSURL *serverURL;    // set once the server is up and its page is being shown
@property pid_t serverPid;
@property int retries;
@property BOOL askNothing;              // quit without the "still importing" question
@end

@implementation AppDelegate

// The server writes its pid, then its address with the token in it, as the
// first two lines of ~/.sonygrab.pid. Only a server that is still alive counts.
- (BOOL)findServer:(pid_t *)pid url:(NSURL **)url {
    NSString *path = [HomeDir() stringByAppendingPathComponent:@".sonygrab.pid"];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    if (lines.count < 2) return NO;
    pid_t p = (pid_t)lines[0].intValue;
    NSString *address = [lines[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSURL *u = address.length ? [NSURL URLWithString:address] : nil;
    if (p <= 0 || !u || kill(p, 0) != 0) return NO;
    *pid = p;
    *url = u;
    return YES;
}

- (BOOL)serverAlive {
    if (!self.serverPid) return NO;
    // For the server this app started, the task knows first. A finished child
    // still answers kill() until it has been collected.
    if (self.launcher && self.serverPid == self.launcher.processIdentifier) return self.launcher.isRunning;
    return kill(self.serverPid, 0) == 0;
}

// One short request to the server's own API. Returns nil if it does not answer.
- (NSData *)call:(NSString *)path method:(NSString *)method {
    if (!self.serverURL) return nil;
    NSURLComponents *parts = [NSURLComponents componentsWithURL:self.serverURL resolvingAgainstBaseURL:NO];
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

// ------------------------------------------------------------------ set-up

static NSMenuItem *Item(NSMenu *menu, NSString *title, SEL action, NSString *key) {
    return [menu addItemWithTitle:title action:action keyEquivalent:key];
}

- (void)buildMenus {
    NSMenu *bar = [NSMenu new];

    NSMenu *app = [NSMenu new];
    Item(app, @"Hide SonyGrab", @selector(hide:), @"h");
    [app addItem:[NSMenuItem separatorItem]];
    Item(app, @"Quit SonyGrab", @selector(terminate:), @"q");
    [bar addItemWithTitle:@"" action:nil keyEquivalent:@""].submenu = app;

    // Without these, Cmd-C and Cmd-V do nothing in the page's text boxes.
    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
    Item(edit, @"Undo", @selector(undo:), @"z");
    Item(edit, @"Redo", @selector(redo:), @"Z");
    [edit addItem:[NSMenuItem separatorItem]];
    Item(edit, @"Cut", @selector(cut:), @"x");
    Item(edit, @"Copy", @selector(copy:), @"c");
    Item(edit, @"Paste", @selector(paste:), @"v");
    Item(edit, @"Select All", @selector(selectAll:), @"a");
    [bar addItemWithTitle:@"Edit" action:nil keyEquivalent:@""].submenu = edit;

    NSMenu *window = [[NSMenu alloc] initWithTitle:@"Window"];
    Item(window, @"Minimize", @selector(performMiniaturize:), @"m");
    Item(window, @"Reload", @selector(reload:), @"r").target = self.web;
    Item(window, @"Close", @selector(performClose:), @"w");
    [bar addItemWithTitle:@"Window" action:nil keyEquivalent:@""].submenu = window;

    NSApp.mainMenu = bar;
    NSApp.windowsMenu = window;
}

- (void)buildWindow {
    NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                              NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1180, 820)
                                              styleMask:style backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"SonyGrab";
    self.window.releasedWhenClosed = NO;
    self.window.minSize = NSMakeSize(760, 560);
    self.window.delegate = self;
    [self.window center];
    [self.window setFrameAutosaveName:@"SonyGrab"];

    WKWebViewConfiguration *cfg = [WKWebViewConfiguration new];
    cfg.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
    self.web = [[WKWebView alloc] initWithFrame:self.window.contentView.bounds configuration:cfg];
    self.web.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.web.navigationDelegate = self;
    self.web.UIDelegate = self;
    [self.window.contentView addSubview:self.web];

    // Something to look at while the launcher checks for an update.
    [self.web loadHTMLString:@"<!doctype html><meta charset=utf-8>"
        "<style>html,body{height:100%;margin:0}body{display:flex;align-items:center;justify-content:center;"
        "font:15px -apple-system,sans-serif;color:GrayText;color-scheme:light dark}</style>"
        "<body>Starting SonyGrab…" baseURL:nil];
    [self.window makeKeyAndOrderFront:nil];
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    [self buildWindow];
    [self buildMenus];

    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:@"/bin/bash"];
    t.arguments = @[[[NSBundle mainBundle] pathForResource:@"launch" ofType:@"sh"]];
    // Tells the launcher the page has a window waiting, so no browser tab.
    NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy];
    env[@"SONYGRAB_WINDOW"] = @"1";
    t.environment = env;
    if (![t launchAndReturnError:nil]) {
        [NSApp terminate:nil];
        return;
    }
    self.launcher = t;

    [NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(watch:) userInfo:nil repeats:YES];
}

// Runs for the life of the app. First it waits for a server to show, then it
// watches for that server stopping.
- (void)watch:(NSTimer *)timer {
    if (self.serverPid) {
        // Quit on the page, the idle timeout, or a crash: nothing left to show.
        if (![self serverAlive]) {
            self.askNothing = YES;
            [NSApp terminate:nil];
        }
        return;
    }

    pid_t pid = 0;
    NSURL *url = nil;
    if ([self findServer:&pid url:&url]) {
        // Some other server is up while ours is still starting. Ours will
        // either take over or bow out; wait to see which.
        if (self.launcher.isRunning && pid != self.launcher.processIdentifier) return;
        // Ours, or one left running by a copy of this app that was force quit.
        self.serverPid = pid;
        self.serverURL = url;
        [self.web loadRequest:[NSURLRequest requestWithURL:url]];
        return;
    }
    if (!self.launcher.isRunning) {
        // The launcher gave up, and has already put up an alert saying why.
        self.askNothing = YES;
        [NSApp terminate:nil];
    }
}

// ------------------------------------------------------------------ the page

- (BOOL)isServerPage:(NSURL *)url {
    return self.serverURL && [url.host isEqualToString:self.serverURL.host] && [url.port isEqual:self.serverURL.port];
}

// The window only ever shows the server's own page. Anything else is a link
// to somewhere else and belongs in the browser.
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action
                                                     decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = action.request.URL;
    if ([url.scheme isEqualToString:@"about"] || [self isServerPage:url]) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }
    if ([url.scheme hasPrefix:@"http"]) [[NSWorkspace sharedWorkspace] openURL:url];
    decisionHandler(WKNavigationActionPolicyCancel);
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    if (![self isServerPage:webView.URL]) return;
    self.retries = 0;
    [webView evaluateJavaScript:@"document.title + ', ' + document.querySelectorAll('button').length + ' buttons'"
              completionHandler:^(id result, NSError *error) {
        Log([NSString stringWithFormat:@"page loaded (%@)", result ?: error.localizedDescription]);
    }];
}

- (void)retryAfter:(NSError *)error {
    Log([NSString stringWithFormat:@"page did not load: %@", error.localizedDescription]);
    if (![self serverAlive] || self.retries++ >= 20) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
        [self.web loadRequest:[NSURLRequest requestWithURL:self.serverURL]];
    });
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self retryAfter:error];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self retryAfter:error];
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    Log(@"page process ended, reloading");
    if (self.serverURL) [webView loadRequest:[NSURLRequest requestWithURL:self.serverURL]];
}

// A web view shows no alert() or confirm() unless the app does it for it, and
// the page relies on confirm() before importing and before quitting.
- (void)webView:(WKWebView *)webView runJavaScriptAlertPanelWithMessage:(NSString *)message
                                                        initiatedByFrame:(WKFrameInfo *)frame
                                                       completionHandler:(void (^)(void))completionHandler {
    NSAlert *alert = [NSAlert new];
    alert.messageText = message;
    [alert addButtonWithTitle:@"OK"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) { completionHandler(); }];
}

- (void)webView:(WKWebView *)webView runJavaScriptConfirmPanelWithMessage:(NSString *)message
                                                          initiatedByFrame:(WKFrameInfo *)frame
                                                         completionHandler:(void (^)(BOOL))completionHandler {
    NSAlert *alert = [NSAlert new];
    alert.messageText = message;
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        completionHandler(r == NSAlertFirstButtonReturn);
    }];
}

// ------------------------------------------------------------------ leaving

// A click on the Dock icon, or a second double-click on the app.
- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)visible {
    if (self.window.isMiniaturized) [self.window deminiaturize:nil];
    [self.window makeKeyAndOrderFront:nil];
    return NO;
}

// The window is the app. Closing it is quitting, and quitting asks first if
// an import is running, so the window stays put until that is answered.
- (BOOL)windowShouldClose:(NSWindow *)sender {
    [NSApp terminate:nil];
    return NO;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)app {
    if (![self serverAlive]) {
        if (self.launcher.isRunning) [self.launcher terminate];     // still starting up
        return NSTerminateNow;
    }

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
    while ([self serverAlive] && deadline.timeIntervalSinceNow > 0) {
        [NSThread sleepForTimeInterval:0.1];
    }
    if ([self serverAlive]) kill(self.serverPid, SIGTERM);
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
