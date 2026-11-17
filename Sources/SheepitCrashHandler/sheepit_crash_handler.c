// Sheepit SDK — Async-Signal-Safe Crash Handler
//
// This file implements POSIX signal handling for crash capture. Every function
// called from a signal handler context MUST be async-signal-safe. The POSIX
// standard defines a limited set of safe functions; notably, malloc/free,
// printf, and any Objective-C/Swift runtime function are NOT safe.
//
// Strategy:
// 1. At install time, mmap a file large enough for sheepit_crash_report_t.
// 2. Populate the crash context and breadcrumb regions from Swift (between crashes).
// 3. On crash, the signal handler writes signal info + thread backtraces into
//    the mmap'd region. The kernel persists it to disk on process exit.
//    Capture beyond the frozen struct (trap-site registers, the crash-annotation
//    message, per-image detail) goes to the supplement file — see
//    include/SheepitCrashSupplement.h. Image and thread capture live in
//    sheepit_crash_threads.c, the frame walk in sheepit_crash_walk.c.
// 4. On next launch, Swift reads the file and uploads the report.

#include "SheepitCrashHandler.h"
#include "SheepitCrashCapture.h"
#include "SheepitCrashSupplement.h"
#include "sheepit_crash_internal.h"

#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <pthread.h>
#include <stdatomic.h>

#if defined(__APPLE__)
#include <mach/mach.h>
#include <mach/thread_act.h>
#include <mach/thread_info.h>
#include <mach/vm_map.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <TargetConditionals.h>
#endif

// ── Static State ────────────────────────────────────────────────────

static sheepit_crash_report_t *s_report = NULL;
static int s_mmap_fd = -1;
static size_t s_mmap_size = 0;
static char s_crash_file_path[1024] = {0};

// Previous signal handlers (for chaining)
static struct sigaction s_prev_handlers[32] = {{0}};
static const int s_signals[] = { SIGABRT, SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGTRAP };
static const int s_signal_count = sizeof(s_signals) / sizeof(s_signals[0]);

// Flag: NSException handler already captured exception info
static volatile atomic_bool s_nsexception_caught = false;

// ── Async-Signal-Safe Helpers ───────────────────────────────────────

static const char *signal_name(int sig) {
    switch (sig) {
        case SIGABRT: return "SIGABRT";
        case SIGSEGV: return "SIGSEGV";
        case SIGBUS:  return "SIGBUS";
        case SIGFPE:  return "SIGFPE";
        case SIGILL:  return "SIGILL";
        case SIGTRAP: return "SIGTRAP";
        default:      return "UNKNOWN";
    }
}

static uint64_t timestamp_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (uint64_t)tv.tv_sec * 1000 + (uint64_t)tv.tv_usec / 1000;
}

// ── Signal Handler ──────────────────────────────────────────────────

static void sheepit_signal_handler(int sig, siginfo_t *info, void *ucontext) {
    if (!s_report) goto chain;

    // Fill in signal info
    s_report->signal_number = sig;
    s_report->signal_code = info ? info->si_code : 0;
    s_report->fault_address = info ? (uintptr_t)info->si_addr : 0;
    s_report->timestamp_ms = timestamp_ms();

    sheepit_crash_supplement_t *supp = sheepit_internal_supplement();

    // Exception type/message — unless NSException handler already set them
    if (!atomic_load(&s_nsexception_caught)) {
        sheepit_internal_strlcpy(s_report->mechanism, "signal", sizeof(s_report->mechanism));
        sheepit_internal_strlcpy(s_report->exception_type, signal_name(sig),
                                 sizeof(s_report->exception_type));
    }

#if defined(__APPLE__)
    // Images first: the stack walk validates every candidate frame against them, and the
    // annotation sections were located while they were captured.
    sheepit_image_scan_t scan = sheepit_internal_capture_images(&s_report->images, supp);
    sheepit_internal_capture_threads(&s_report->threads, &s_report->images, scan, ucontext, supp);

    if (!atomic_load(&s_nsexception_caught)) {
        // The crash-annotation message (a Swift fatal error's text, an abort() reason), from
        // allowlisted images only. The supplement keeps up to 1023 bytes; the frozen 512-byte
        // field gets a whole-character prefix so a build that predates the supplement still
        // shows the reason.
        static sheepit_annotation_source_t sources[SHEEPIT_MAX_IMAGES];
        uint32_t source_count = sheepit_internal_annotation_sources(&s_report->images, sources,
                                                                    SHEEPIT_MAX_IMAGES);
        if (supp) {
            size_t len = sheepit_read_crash_annotation_message(sources, source_count,
                                                               supp->exception_message,
                                                               sizeof(supp->exception_message));
            if (len > 0) supp->flags |= SHEEPIT_SUPPLEMENT_HAS_ANNOTATION;
            sheepit_internal_strlcpy(s_report->exception_message, supp->exception_message,
                                     sizeof(s_report->exception_message));
        } else {
            sheepit_read_crash_annotation_message(sources, source_count, s_report->exception_message,
                                                  sizeof(s_report->exception_message));
        }
        sheepit_internal_utf8_trim(s_report->exception_message, strlen(s_report->exception_message));
    }
#endif

    // The supplement is stamped with the report's timestamp and marked valid first, so a
    // report never claims a supplement that is still being written.
    if (supp) {
        sheepit_internal_capture_cohort();
        supp->report_timestamp_ms = s_report->timestamp_ms;
        supp->magic = SHEEPIT_SUPPLEMENT_MAGIC;
        sheepit_internal_supplement_sync();
    }

    // Mark report as valid
    s_report->magic = SHEEPIT_CRASH_REPORT_MAGIC;

    // Sync mmap to disk
    msync(s_report, s_mmap_size, MS_SYNC);

chain:
    // Chain to previous handler
    for (int i = 0; i < s_signal_count; i++) {
        if (s_signals[i] == sig) {
            struct sigaction *prev = &s_prev_handlers[sig];
            if (prev->sa_flags & SA_SIGINFO) {
                if (prev->sa_sigaction) {
                    prev->sa_sigaction(sig, info, ucontext);
                    return;
                }
            } else {
                if (prev->sa_handler != SIG_DFL && prev->sa_handler != SIG_IGN) {
                    prev->sa_handler(sig);
                    return;
                }
            }
            break;
        }
    }

    // Restore default and re-raise
    signal(sig, SIG_DFL);
    raise(sig);
}

// ── Public API Implementation ───────────────────────────────────────

int sheepit_crash_handler_install(const char *crash_file_path) {
    if (s_report) return -1;  // Already installed

    sheepit_internal_strlcpy(s_crash_file_path, crash_file_path, sizeof(s_crash_file_path));
    s_mmap_size = sizeof(sheepit_crash_report_t);

    // Create/open the crash file
    int fd = open(crash_file_path, O_RDWR | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) return -1;

    // Extend file to required size
    if (ftruncate(fd, (off_t)s_mmap_size) != 0) {
        close(fd);
        return -1;
    }

    // Memory-map the file
    void *map = mmap(NULL, s_mmap_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) {
        close(fd);
        return -1;
    }

    s_mmap_fd = fd;
    s_report = (sheepit_crash_report_t *)map;
    memset(s_report, 0, s_mmap_size);

    // Initialize breadcrumb ring magic
    s_report->breadcrumbs.magic = SHEEPIT_BREADCRUMB_MAGIC;

    // Install signal handlers
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = sheepit_signal_handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigfillset(&sa.sa_mask);

    for (int i = 0; i < s_signal_count; i++) {
        int sig = s_signals[i];
        sigaction(sig, &sa, &s_prev_handlers[sig]);
    }

    return 0;
}

void sheepit_crash_handler_uninstall(void) {
    // Restore previous handlers
    for (int i = 0; i < s_signal_count; i++) {
        int sig = s_signals[i];
        sigaction(sig, &s_prev_handlers[sig], NULL);
    }

    if (s_report) {
        munmap(s_report, s_mmap_size);
        s_report = NULL;
    }
    if (s_mmap_fd >= 0) {
        close(s_mmap_fd);
        s_mmap_fd = -1;
    }
    sheepit_internal_supplement_uninstall();
}

sheepit_crash_context_t *sheepit_get_crash_context(void) {
    if (!s_report) return NULL;
    return &s_report->context;
}

sheepit_breadcrumb_ring_t *sheepit_get_breadcrumb_ring(void) {
    if (!s_report) return NULL;
    return &s_report->breadcrumbs;
}

void sheepit_add_breadcrumb(const char *category, const char *message) {
    if (!s_report) return;

    sheepit_breadcrumb_ring_t *ring = &s_report->breadcrumbs;
    uint32_t idx = __atomic_fetch_add(&ring->write_index, 1, __ATOMIC_RELAXED)
                   % SHEEPIT_MAX_BREADCRUMBS;

    sheepit_breadcrumb_t *entry = &ring->entries[idx];
    entry->timestamp_ms = timestamp_ms();
    sheepit_internal_strlcpy(entry->category, category, sizeof(entry->category));
    sheepit_internal_strlcpy(entry->message, message, sizeof(entry->message));

    uint32_t old_count = __atomic_load_n(&ring->count, __ATOMIC_RELAXED);
    if (old_count < SHEEPIT_MAX_BREADCRUMBS) {
        __atomic_compare_exchange_n(&ring->count, &old_count, old_count + 1,
                                    true, __ATOMIC_RELAXED, __ATOMIC_RELAXED);
    }
}

bool sheepit_has_pending_crash_report(const char *crash_file_path) {
    struct stat st;
    if (stat(crash_file_path, &st) != 0) return false;
    if ((size_t)st.st_size < sizeof(sheepit_crash_report_t)) return false;

    int fd = open(crash_file_path, O_RDONLY);
    if (fd < 0) return false;

    // Read just the magic at the end of the struct
    uint32_t magic = 0;
    off_t offset = (off_t)offsetof(sheepit_crash_report_t, magic);
    if (pread(fd, &magic, sizeof(magic), offset) == sizeof(magic)) {
        close(fd);
        return magic == SHEEPIT_CRASH_REPORT_MAGIC;
    }

    close(fd);
    return false;
}

sheepit_crash_report_t *sheepit_read_pending_crash_report(const char *crash_file_path) {
    int fd = open(crash_file_path, O_RDONLY);
    if (fd < 0) return NULL;

    struct stat st;
    if (fstat(fd, &st) != 0 || (size_t)st.st_size < sizeof(sheepit_crash_report_t)) {
        close(fd);
        return NULL;
    }

    sheepit_crash_report_t *report = (sheepit_crash_report_t *)malloc(sizeof(sheepit_crash_report_t));
    if (!report) {
        close(fd);
        return NULL;
    }

    ssize_t bytes_read = read(fd, report, sizeof(sheepit_crash_report_t));
    close(fd);

    if (bytes_read < (ssize_t)sizeof(sheepit_crash_report_t) ||
        report->magic != SHEEPIT_CRASH_REPORT_MAGIC) {
        free(report);
        return NULL;
    }

    return report;
}

void sheepit_clear_pending_crash_report(const char *crash_file_path) {
    unlink(crash_file_path);
}

void sheepit_set_nsexception_info(const char *name, const char *reason) {
    if (!s_report) return;

    sheepit_internal_strlcpy(s_report->mechanism, "nsexception", sizeof(s_report->mechanism));
    sheepit_internal_strlcpy(s_report->exception_type, name ? name : "NSException",
                 sizeof(s_report->exception_type));
    sheepit_internal_strlcpy(s_report->exception_message, reason ? reason : "",
                 sizeof(s_report->exception_message));
    sheepit_internal_utf8_trim(s_report->exception_message, strlen(s_report->exception_message));
    sheepit_crash_supplement_t *supp = sheepit_internal_supplement();
    if (supp) {
        // The reason in full (up to 1023 bytes); the frozen field above holds 511.
        sheepit_internal_strlcpy(supp->exception_message, reason ? reason : "",
                                 sizeof(supp->exception_message));
        sheepit_internal_utf8_trim(supp->exception_message, strlen(supp->exception_message));
    }

    atomic_store(&s_nsexception_caught, true);
}
