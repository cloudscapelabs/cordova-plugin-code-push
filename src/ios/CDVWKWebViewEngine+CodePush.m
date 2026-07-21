#import <Foundation/Foundation.h>
#import <Cordova/CDV.h>
#import <Cordova/NSDictionary+CordovaPreferences.h>
#import <Cordova/CDVWebViewEngineProtocol.h>
#import <WebKit/WebKit.h>
#import "CodePush.h"

/*
   What this file does: It's a small patch to how the app's screen (WebView) loads your web content, specifically handling what happens when a CodePush update fails to load.

   The bug that was breaking things: The code was silently checking for an old, outdated internal iOS component name
   that hasn't existed in years. Because that check always failed quietly, the entire safety-net feature — including
   the "if a CodePush update fails to load, recover gracefully" logic — was never actually running. It compiled fine,
   but did nothing at runtime. So when a CodePush update failed, the app was just left on a blank/stuck screen with no recovery.

   The fix:
   1. Stops relying on that broken/outdated check so the safety-net code actually runs again.
   2. Catches a second type of load failure that previously had zero handling at all (failures during the very first page load, before anything renders) — this is the case behind the classic "app stuck on splash screen forever."
   3. Adds a bounded retry (tries again up to 2 times) instead of retrying forever or not at all.
   4. If retries are exhausted and the failure was actually a CodePush package failing to load, silently rolls back to the last known-good version (or the original app store version if there is none) via CodePush.m's handleWebViewLoadFailure, so the user is never left stuck on a broken update. Failures unrelated to CodePush still fall through to the app's normal error page / DEBUG alert, unchanged.
*/


// NOTE ON HOW THIS FILE TARGETS cordova-ios's WEBVIEW CLASS:
//
// This category previously guarded itself with `#if __has_include("CDVWKWebViewEngine.h")` and
// imported that header directly. Two problems, confirmed by actually building a plugin-consuming
// app against cordova-ios 8.1.1 (not just reading source):
//
// 1. cordova-ios renamed this class from `CDVWKWebViewEngine` to `CDVWebViewEngine` (no "K") back
//    in cordova-ios 6.0.0, when WKWebView became the default (and only) supported engine. The old
//    name has not existed in any cordova-ios version this plugin currently supports.
// 2. Even after retargeting the guard/import to the *current* name (`CDVWebViewEngine.h`), that
//    header lives under cordova-ios's PRIVATE `CordovaLib/Classes/Private/Plugins/CDVWebViewEngine/`
//    directory. A default consuming app's header search paths and Xcode-generated header maps do
//    not expose that private header to plugin source files, so `__has_include` for it evaluates to
//    FALSE in a real build too - meaning the whole file (guard, original overrides, and everything
//    below) silently compiled to nothing (verified: the compiled .o contained no category symbols
//    at all).
//
// Root problem: silently depending on a private, non-guaranteed-reachable header via `__has_include`
// is exactly the kind of guard that can silently evaluate false for years without anyone noticing
// (which is how the original bug went undetected). The fix here is to stop depending on that private
// header entirely. We only need the compiler to know that a class named `CDVWebViewEngine` exists and
// roughly what it conforms to, so we can declare a category on it and override a few WKNavigationDelegate/
// CDVWebViewEngineProtocol methods - we do NOT need its full private interface. So we forward-declare a
// minimal interface ourselves, using only PUBLIC Cordova/WebKit headers (all confirmed reachable in a
// real build). If cordova-ios ever removes/renames this class again, this will now fail loudly at link
// time (undefined class symbol) instead of silently compiling away - a deliberate tradeoff, since a
// loud build break is far safer than another multi-year silent no-op.
@interface CDVWebViewEngine : CDVPlugin <CDVWebViewEngineProtocol, WKScriptMessageHandler, WKNavigationDelegate>
@end

@implementation CDVWebViewEngine (CodePush)

NSString* const IdentifierCodePushPath = @"codepush/deploy/versions";
NSString* lastLoadedURL = @"";

// Bounded retry state shared between didFailNavigation:withError: and
// didFailProvisionalNavigation:withError:. Reset whenever loadRequest: is called with a
// genuinely new URL, so a fresh, unrelated navigation is never penalized by a previous
// navigation's failure count. This also fixes a pre-existing bug where didFailNavigation:withError:
// retried unconditionally with no limit at all, which could loop forever if the same failure recurred.
static NSInteger cpNavFailureRetryCount = 0;
static NSInteger const CP_MAX_NAV_FAILURE_RETRIES = 2;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

- (id)loadRequest:(NSURLRequest *)request {
    NSString* requestedURL = request.URL.absoluteString;
    if (![requestedURL isEqualToString:lastLoadedURL]) {
        cpNavFailureRetryCount = 0;
    }
    lastLoadedURL = requestedURL;
    NSURL *readAccessURL;

    NSURL* bundleURL = [[NSBundle mainBundle] bundleURL];
    if (![lastLoadedURL containsString:bundleURL.path] && ![lastLoadedURL containsString:IdentifierCodePushPath]) {
        return [self loadPluginRequest:request];
    }

    if (request.URL.isFileURL) {
        // All file URL requests should be handled with the setServerBasePath in case it is an Ionic app.
        if ([CodePush hasIonicWebViewEngine: self]) {
            NSString* specifiedServerPath = [CodePush getCurrentServerBasePath];
            if (![specifiedServerPath containsString:IdentifierCodePushPath] || [request.URL.path containsString:IdentifierCodePushPath]) {
                [CodePush setServerBasePath:request.URL.path webView: self];
            }

            return nil;
        }

        if ([request.URL.absoluteString containsString:IdentifierCodePushPath]) {
            // If the app is attempting to load a CodePush update, then we can lock the WebView down to
            // just the CodePush "versions" directory. This prevents non-CodePush assets from being accessible,
            // while still allowing us to navigate to a future update, as well as to the binary if a rollback is needed.
            NSString *libraryPath = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES)[0];
            readAccessURL = [NSURL fileURLWithPathComponents:@[libraryPath, @"NoCloud", @"codepush", @"deploy", @"versions"]];
        } else {
            // In order to allow the WebView to be navigated from the app bundle to another location, we (for some
            // entirely unknown reason) need to ensure that the "read access URL" is set to the parent of the bundle
            // as opposed to the www folder, which is what the WKWebViewEngine would attempt to set it to by default.
            // If we didn't set this, then the attempt to navigate from the bundle to a CodePush update would fail.
            readAccessURL = [[[NSBundle mainBundle] bundleURL] URLByDeletingLastPathComponent];
        }

        return [(WKWebView*)self.engineWebView loadFileURL:request.URL allowingReadAccessToURL:readAccessURL];
    } else {
        return [(WKWebView*)self.engineWebView loadRequest: request];
    }
}

- (id)loadPluginRequest:(NSURLRequest *)request {
    if (request.URL.fileURL) {
        NSDictionary* settings = self.commandDelegate.settings;
        NSString *bind = [settings cordovaSettingForKey:@"Hostname"];
        if(bind == nil){
            bind = @"localhost";
        }
        NSString *scheme = [settings cordovaSettingForKey:@"iosScheme"];
        if(scheme == nil || [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]  || [scheme isEqualToString:@"file"]){
            scheme = @"ionic";
        }
        NSString *CDV_LOCAL_SERVER = [NSString stringWithFormat:@"%@://%@", scheme, bind];
        
        NSURL* startURL = [NSURL URLWithString:((CDVViewController *)self.viewController).startPage];
        NSString* startFilePath = [self.commandDelegate pathForResource:[startURL path]];
        NSURL *url = [[NSURL URLWithString:CDV_LOCAL_SERVER] URLByAppendingPathComponent:request.URL.path];
        if ([request.URL.path isEqualToString:startFilePath]) {
            url = [NSURL URLWithString:CDV_LOCAL_SERVER];
        }
        if(request.URL.query) {
            url = [NSURL URLWithString:[@"?" stringByAppendingString:request.URL.query] relativeToURL:url];
        }
        if(request.URL.fragment) {
            url = [NSURL URLWithString:[@"#" stringByAppendingString:request.URL.fragment] relativeToURL:url];
        }
        request = [NSURLRequest requestWithURL:url];
    }
    return [(WKWebView*)self.engineWebView loadRequest:request];
}

#pragma clang diagnostic pop

// Shared handling for both didFailNavigation:withError: and didFailProvisionalNavigation:withError:.
// If this looks like a CodePush-path load failure or an unexplained webview termination, retries
// a bounded number of times (fixing a pre-existing bug where didFailNavigation:withError: retried
// unconditionally with no limit at all). Returns YES if it retried, or if it fully handled the
// failure itself (see below) - the caller should do nothing further in either case. Returns NO
// only when this isn't CodePush-related at all, so the caller should run its own default/error-page
// behavior instead.
//
// Once retries are exhausted: if this was a genuine CodePush package load failure (isCodePushPath),
// it's silently handled by rolling back to the last known-good version via CodePush.m's
// handleWebViewLoadFailure - never shown as an error. A bare WebView termination that wasn't tied to
// a CodePush path has nothing to roll back, so it still falls through to the normal error page.
- (BOOL)cp_handleNavigationFailure:(NSError*)error {
    // NSURLErrorFailingURLStringErrorKey is the URL which caused a load to fail; if it's null,
    // the webView was terminated for some reason.
    BOOL webViewWasTerminated = [[error userInfo] objectForKey:NSURLErrorFailingURLStringErrorKey] == nil;
    BOOL isCodePushPath = [lastLoadedURL containsString:IdentifierCodePushPath];

    if (!(webViewWasTerminated || isCodePushPath)) {
        return NO;
    }

    if (cpNavFailureRetryCount < CP_MAX_NAV_FAILURE_RETRIES) {
        cpNavFailureRetryCount++;
        NSURL* retryURL = [[NSURL alloc] initWithString:lastLoadedURL];
        if (retryURL) {
            // Retry by manually reloading the last requested URL via this category's loadRequest override
            [self loadRequest:[NSURLRequest requestWithURL:retryURL]];
            return YES;
        }
    }

    if (!isCodePushPath) {
        // Just a bare WebView termination, not tied to a CodePush package - there's nothing to
        // roll back, so let the caller show its normal error page.
        return NO;
    }

    // Retries exhausted for a genuine CodePush package load failure - silently roll back instead
    // of surfacing an error. CodePush.m owns the rollback/version-reporting machinery, so we reach
    // its plugin instance the standard Cordova way rather than duplicating any of that logic here.
    CodePush* codePushPlugin = (CodePush*)[(CDVViewController*)self.viewController getCommandInstance:@"CodePush"];
    [codePushPlugin handleWebViewLoadFailure];
    return YES;
}

// Shared "hard failure" presentation, used only for load failures unrelated to a CodePush package
// (see cp_handleNavigationFailure above) - either immediately, or once retries for an unexplained
// WebView termination are exhausted. This is the same default behavior CDVWebViewEngine.m normally
// runs on any load failure: release the user agent lock, navigate to the app's configured error
// page if one exists, and (DEBUG builds only) show an alert. Extracted here so both delegate
// methods below behave identically.
- (void)cp_presentNavigationFailureError:(NSError*)error webView:(WKWebView*)theWebView {
    CDVViewController* vc = (CDVViewController*)self.viewController;
#ifndef __CORDOVA_6_0_0
    [CDVUserAgentUtil releaseLock:vc.userAgentLockToken];
#endif

    NSString* message = [NSString stringWithFormat:@"Failed to load webpage with error: %@", [error localizedDescription]];
    NSLog(@"%@", message);

    NSURL* errorUrl = vc.errorURL;
    if (errorUrl) {
        NSCharacterSet *charSet = [NSCharacterSet URLFragmentAllowedCharacterSet];
        errorUrl = [NSURL URLWithString:[NSString stringWithFormat:@"?error=%@", [message stringByAddingPercentEncodingWithAllowedCharacters:charSet]] relativeToURL:errorUrl];
        NSLog(@"%@", [errorUrl absoluteString]);
        [theWebView loadRequest:[NSURLRequest requestWithURL:errorUrl]];
    }
#ifdef DEBUG
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"] message:message preferredStyle:UIAlertControllerStyleAlert];
    [alertController addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil) style:UIAlertActionStyleDefault handler:nil]];
    [vc presentViewController:alertController animated:YES completion:nil];
#endif
}

// Handles WKWebView failing to navigate after a CodePush update has been loaded: retries a bounded
// number of times, then either silently rolls back (CodePush-related failure) or falls through to
// a hard failure (unrelated failure) - see cp_handleNavigationFailure above.
- (void)webView:(WKWebView*)theWebView didFailNavigation:(WKNavigation*)navigation withError:(NSError*)error {
    if ([self cp_handleNavigationFailure:error]) {
        return;
    }

    // Not CodePush-related - fall through to the same default failure behavior CDVWebViewEngine.m
    // normally runs.
    [self cp_presentNavigationFailureError:error webView:theWebView];
}

// WKWebView calls didFailProvisionalNavigation:withError: (not didFailNavigation:withError:) when
// the FIRST/initial load of a URL fails before anything commits - this is the exact delegate
// callback behind WebPageProxy::didFailProvisionalLoadForFrame, which is what actually fires for
// the production "file doesn't exist" (NSCocoaErrorDomain code 4) stuck-splash bug. This method
// previously did not exist at all in this category, meaning this failure had NO recovery - the
// WKWebView was simply left on its blank/splash state forever. It now gets the same bounded-retry-
// then-rollback-or-error-page treatment as didFailNavigation:withError:, so the app is never left
// stuck on a broken CodePush update.
- (void)webView:(WKWebView*)theWebView didFailProvisionalNavigation:(WKNavigation*)navigation withError:(NSError*)error {
    if ([self cp_handleNavigationFailure:error]) {
        return;
    }

    [self cp_presentNavigationFailureError:error webView:theWebView];
}

@end
