// Sheepit SDK — Async-Signal-Safe Crash Handler
// This C module captures crashes via POSIX signal handlers and Mach exceptions.
// All code in signal handlers is async-signal-safe: no heap allocation,
// no Objective-C messaging, no Swift runtime calls, no locks.
//
// ON-DISK FORMAT IS FROZEN. The struct layouts below and the *_MAGIC values
// are an on-disk contract: a build stamps them into an mmap'd file, and the
// NEXT launch (possibly a newer build, post-update) reads them back. The C
// symbols were renamed lp_*/LP_* -> sheepit_*/SHEEPIT_* (LaunchPad -> Sheepit),
// but the magic VALUES were deliberately kept so a crash written by an older
// build is still readable after update. Do not reorder fields or change the
// magic bytes — a freshly-updated app would silently drop the pending report.

#ifndef SHEEPIT_CRASH_HANDLER_H
#define SHEEPIT_CRASH_HANDLER_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ── Limits ──────────────────────────────────────────────────────────

#define SHEEPIT_MAX_THREADS       128
#define SHEEPIT_MAX_FRAMES        128
#define SHEEPIT_MAX_BREADCRUMBS   32
#define SHEEPIT_BREADCRUMB_MSG_LEN 256
#define SHEEPIT_MAX_IMAGES        512

// ── Crash Context (mmap'd, written by Swift between crashes) ────────

typedef struct {
    char user_id[256];
    char device_id[256];
    char session_id[256];
    char app_version[64];
    char build_number[64];
    char os_version[64];
    char device_model[128];
    char screen_name[256];
    bool is_foreground;
    uint32_t free_memory_mb;
    uint32_t free_disk_mb;
    uint8_t battery_level;
    char active_flags_json[4096];
    char active_experiments_json[4096];
    uint32_t magic;
} sheepit_crash_context_t;

#define SHEEPIT_CRASH_CONTEXT_MAGIC 0x4C504358  // bytes "LPCX" — FROZEN on-disk magic (back-compat); do not change

// ── Breadcrumb Ring Buffer ──────────────────────────────────────────

typedef struct {
    uint64_t timestamp_ms;
    char category[32];
    char message[SHEEPIT_BREADCRUMB_MSG_LEN];
} sheepit_breadcrumb_t;

typedef struct {
    sheepit_breadcrumb_t entries[SHEEPIT_MAX_BREADCRUMBS];
    uint32_t write_index;
    uint32_t count;
    uint32_t magic;
} sheepit_breadcrumb_ring_t;

#define SHEEPIT_BREADCRUMB_MAGIC 0x4C504252  // bytes "LPBR" — FROZEN on-disk magic (back-compat); do not change

// ── Thread Capture ──────────────────────────────────────────────────

typedef struct {
    uintptr_t frames[SHEEPIT_MAX_FRAMES];
    uint32_t frame_count;
    uint64_t thread_id;
    bool is_crashed_thread;
    char name[64];
} sheepit_thread_state_t;

typedef struct {
    sheepit_thread_state_t threads[SHEEPIT_MAX_THREADS];
    uint32_t thread_count;
} sheepit_thread_capture_t;

// ── Binary Image Info ───────────────────────────────────────────────

typedef struct {
    char name[256];
    uintptr_t load_address;
    uintptr_t size;
    char uuid[37];  // UUID string "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"
} sheepit_binary_image_t;

typedef struct {
    sheepit_binary_image_t images[SHEEPIT_MAX_IMAGES];
    uint32_t image_count;
} sheepit_binary_image_list_t;

// ── Crash Report (written at crash time to mmap'd file) ─────────────

typedef struct {
    int signal_number;
    int signal_code;
    uintptr_t fault_address;
    char exception_type[128];
    char exception_message[512];
    char mechanism[32];          // "signal" or "nsexception"
    uint64_t timestamp_ms;
    sheepit_crash_context_t context;
    sheepit_breadcrumb_ring_t breadcrumbs;
    sheepit_thread_capture_t threads;
    sheepit_binary_image_list_t images;
    uint32_t magic;
} sheepit_crash_report_t;

#define SHEEPIT_CRASH_REPORT_MAGIC 0x4C504352  // bytes "LPCR" — FROZEN on-disk magic (back-compat); do not change

// ── Public API ──────────────────────────────────────────────────────

/// Install signal handlers and prepare the mmap'd crash report region.
/// @param crash_file_path Path to the file for the mmap'd crash report.
/// @return 0 on success, -1 on failure.
int sheepit_crash_handler_install(const char *crash_file_path);

/// Uninstall signal handlers, restoring the previous handlers.
void sheepit_crash_handler_uninstall(void);

/// Get a writable pointer to the crash context region.
/// Swift code updates this between crashes with current user/device state.
sheepit_crash_context_t *sheepit_get_crash_context(void);

/// Get a writable pointer to the breadcrumb ring buffer.
sheepit_breadcrumb_ring_t *sheepit_get_breadcrumb_ring(void);

/// Add a breadcrumb entry. Thread-safe (uses atomic write index).
/// @param category Short category string (e.g., "ui", "network", "track").
/// @param message Human-readable message, truncated to SHEEPIT_BREADCRUMB_MSG_LEN.
void sheepit_add_breadcrumb(const char *category, const char *message);

/// Check whether a valid crash report exists from a previous session.
bool sheepit_has_pending_crash_report(const char *crash_file_path);

/// Read the crash report from a previous session. Caller must free() the result.
/// @return A heap-allocated copy of the crash report, or NULL if none exists.
sheepit_crash_report_t *sheepit_read_pending_crash_report(const char *crash_file_path);

/// Delete the crash report file after successful upload.
void sheepit_clear_pending_crash_report(const char *crash_file_path);

/// Record that an NSException was caught (called from ObjC handler before SIGABRT).
/// Sets internal flag so the signal handler knows the exception info is already captured.
void sheepit_set_nsexception_info(const char *name, const char *reason);

/// Install the NSUncaughtExceptionHandler. Call after sheepit_crash_handler_install().
void sheepit_install_nsexception_handler(void);

/// Uninstall the NSException handler, restoring the previous one.
void sheepit_uninstall_nsexception_handler(void);

#ifdef __cplusplus
}
#endif

#endif /* SHEEPIT_CRASH_HANDLER_H */
