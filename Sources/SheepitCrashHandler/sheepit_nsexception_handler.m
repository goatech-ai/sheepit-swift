// Sheepit SDK — NSException Handler
//
// Captures uncaught Objective-C exceptions BEFORE the subsequent SIGABRT.
// The ObjC runtime is still active when this handler runs, so we can safely
// access the exception's name, reason, and callStackReturnAddresses.

#import <Foundation/Foundation.h>
#include "SheepitCrashHandler.h"

static NSUncaughtExceptionHandler *s_previous_handler = NULL;

static void sheepit_nsexception_handler(NSException *exception) {
    // Write exception info to the mmap'd region
    sheepit_set_nsexception_info(
        exception.name.UTF8String,
        exception.reason.UTF8String
    );

    // Chain to previous handler (e.g., Sentry, Crashlytics)
    if (s_previous_handler) {
        s_previous_handler(exception);
    }
}

/// Install the NSException handler. Call after sheepit_crash_handler_install().
void sheepit_install_nsexception_handler(void) __attribute__((visibility("default")));
void sheepit_install_nsexception_handler(void) {
    s_previous_handler = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(&sheepit_nsexception_handler);
}

/// Uninstall the NSException handler, restoring the previous one.
void sheepit_uninstall_nsexception_handler(void) __attribute__((visibility("default")));
void sheepit_uninstall_nsexception_handler(void) {
    NSSetUncaughtExceptionHandler(s_previous_handler);
    s_previous_handler = NULL;
}
