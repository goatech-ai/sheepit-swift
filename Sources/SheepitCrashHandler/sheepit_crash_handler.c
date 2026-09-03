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
// 4. On next launch, Swift reads the file and uploads the report.

#include "SheepitCrashHandler.h"

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

static void safe_strlcpy(char *dst, const char *src, size_t size) {
    if (size == 0) return;
    size_t i = 0;
    while (i < size - 1 && src[i] != '\0') {
        dst[i] = src[i];
        i++;
    }
    dst[i] = '\0';
}

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

// ── Thread Capture (Mach APIs, async-signal-safe on Apple) ──────────

#if defined(__APPLE__)

static void capture_thread_backtrace(thread_t thread, sheepit_thread_state_t *state) {
    state->frame_count = 0;

#if defined(__arm64__) || defined(__aarch64__)
    arm_thread_state64_t thread_state;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    kern_return_t kr = thread_get_state(thread, ARM_THREAD_STATE64,
                                         (thread_state_t)&thread_state, &count);
    if (kr != KERN_SUCCESS) return;

    // Record PC as first frame
    uintptr_t pc = (uintptr_t)__darwin_arm_thread_state64_get_pc(thread_state);
    uintptr_t fp = (uintptr_t)__darwin_arm_thread_state64_get_fp(thread_state);

    if (pc != 0) {
        state->frames[state->frame_count++] = pc;
    }

    // Walk frame pointers: fp[0] = previous fp, fp[1] = return address
    while (fp != 0 && state->frame_count < SHEEPIT_MAX_FRAMES) {
        uintptr_t *frame = (uintptr_t *)fp;
        uintptr_t next_fp = frame[0];
        uintptr_t lr = frame[1];

        if (lr == 0) break;
        state->frames[state->frame_count++] = lr;

        // Sanity: fp must move forward (toward higher addresses on stack)
        if (next_fp <= fp) break;
        fp = next_fp;
    }
#elif defined(__x86_64__)
    x86_thread_state64_t thread_state;
    mach_msg_type_number_t count = x86_THREAD_STATE64_COUNT;
    kern_return_t kr = thread_get_state(thread, x86_THREAD_STATE64,
                                         (thread_state_t)&thread_state, &count);
    if (kr != KERN_SUCCESS) return;

    uintptr_t pc = (uintptr_t)thread_state.__rip;
    uintptr_t fp = (uintptr_t)thread_state.__rbp;

    if (pc != 0) {
        state->frames[state->frame_count++] = pc;
    }

    while (fp != 0 && state->frame_count < SHEEPIT_MAX_FRAMES) {
        uintptr_t *frame = (uintptr_t *)fp;
        uintptr_t next_fp = frame[0];
        uintptr_t lr = frame[1];

        if (lr == 0) break;
        state->frames[state->frame_count++] = lr;
        if (next_fp <= fp) break;
        fp = next_fp;
    }
#endif
}

static void capture_all_threads(sheepit_thread_capture_t *capture, thread_t crashed_thread) {
    capture->thread_count = 0;

    thread_act_array_t threads;
    mach_msg_type_number_t thread_count;
    kern_return_t kr = task_threads(mach_task_self(), &threads, &thread_count);
    if (kr != KERN_SUCCESS) return;

    uint32_t max = thread_count < SHEEPIT_MAX_THREADS ? thread_count : SHEEPIT_MAX_THREADS;

    for (uint32_t i = 0; i < max; i++) {
        sheepit_thread_state_t *state = &capture->threads[capture->thread_count];
        memset(state, 0, sizeof(sheepit_thread_state_t));

        state->thread_id = (uint64_t)threads[i];
        state->is_crashed_thread = (threads[i] == crashed_thread);

        // Get thread name
        thread_extended_info_data_t ext_info;
        mach_msg_type_number_t info_count = THREAD_EXTENDED_INFO_COUNT;
        if (thread_info(threads[i], THREAD_EXTENDED_INFO,
                        (thread_info_t)&ext_info, &info_count) == KERN_SUCCESS) {
            safe_strlcpy(state->name, ext_info.pth_name, sizeof(state->name));
        }

        if (threads[i] == crashed_thread) {
            // Crashed thread: backtrace from signal context (already in report via fp walk)
            capture_thread_backtrace(threads[i], state);
        } else {
            // Suspend, capture, resume other threads
            thread_suspend(threads[i]);
            capture_thread_backtrace(threads[i], state);
            thread_resume(threads[i]);
        }

        capture->thread_count++;
    }

    // Deallocate the thread list (vm_deallocate is signal-safe on Mach)
    vm_deallocate(mach_task_self(), (vm_address_t)threads,
                  thread_count * sizeof(thread_act_t));
}

static void capture_binary_images(sheepit_binary_image_list_t *list) {
    list->image_count = 0;
    uint32_t count = _dyld_image_count();
    uint32_t max = count < SHEEPIT_MAX_IMAGES ? count : SHEEPIT_MAX_IMAGES;

    for (uint32_t i = 0; i < max; i++) {
        const char *name = _dyld_get_image_name(i);
        const struct mach_header *header = _dyld_get_image_header(i);
        if (!name || !header) continue;

        sheepit_binary_image_t *img = &list->images[list->image_count];
        memset(img, 0, sizeof(sheepit_binary_image_t));

        // Store just the filename, not the full path
        const char *slash = name;
        const char *p = name;
        while (*p) {
            if (*p == '/') slash = p + 1;
            p++;
        }
        safe_strlcpy(img->name, slash, sizeof(img->name));
        img->load_address = (uintptr_t)header;

        // Walk load commands to find LC_UUID and segment size
        if (header->magic == MH_MAGIC_64) {
            const struct mach_header_64 *h64 = (const struct mach_header_64 *)header;
            const uint8_t *cmd_ptr = (const uint8_t *)(h64 + 1);
            for (uint32_t j = 0; j < h64->ncmds; j++) {
                const struct load_command *cmd = (const struct load_command *)cmd_ptr;
                if (cmd->cmd == LC_UUID) {
                    const struct uuid_command *uuid_cmd = (const struct uuid_command *)cmd;
                    const uint8_t *u = uuid_cmd->uuid;
                    // Format as UUID string (async-signal-safe, just pointer arithmetic)
                    static const char hex[] = "0123456789ABCDEF";
                    char *out = img->uuid;
                    for (int k = 0; k < 16; k++) {
                        *out++ = hex[u[k] >> 4];
                        *out++ = hex[u[k] & 0xF];
                        if (k == 3 || k == 5 || k == 7 || k == 9) *out++ = '-';
                    }
                    *out = '\0';
                } else if (cmd->cmd == LC_SEGMENT_64) {
                    const struct segment_command_64 *seg = (const struct segment_command_64 *)cmd;
                    if (seg->vmsize > img->size) {
                        img->size = (uintptr_t)seg->vmsize;
                    }
                }
                cmd_ptr += cmd->cmdsize;
            }
        }

        list->image_count++;
    }
}

#endif // __APPLE__

// ── Signal Handler ──────────────────────────────────────────────────

static void sheepit_signal_handler(int sig, siginfo_t *info, void *ucontext) {
    if (!s_report) goto chain;

    // Fill in signal info
    s_report->signal_number = sig;
    s_report->signal_code = info ? info->si_code : 0;
    s_report->fault_address = info ? (uintptr_t)info->si_addr : 0;
    s_report->timestamp_ms = timestamp_ms();

    // Exception type/message — unless NSException handler already set them
    if (!atomic_load(&s_nsexception_caught)) {
        safe_strlcpy(s_report->mechanism, "signal", sizeof(s_report->mechanism));
        safe_strlcpy(s_report->exception_type, signal_name(sig),
                     sizeof(s_report->exception_type));
        // Build a minimal message
        s_report->exception_message[0] = '\0';
    }

#if defined(__APPLE__)
    // Capture all threads
    thread_t crashed = mach_thread_self();
    capture_all_threads(&s_report->threads, crashed);

    // Capture binary images
    capture_binary_images(&s_report->images);
#endif

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

    safe_strlcpy(s_crash_file_path, crash_file_path, sizeof(s_crash_file_path));
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
    safe_strlcpy(entry->category, category, sizeof(entry->category));
    safe_strlcpy(entry->message, message, sizeof(entry->message));

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

    safe_strlcpy(s_report->mechanism, "nsexception", sizeof(s_report->mechanism));
    safe_strlcpy(s_report->exception_type, name ? name : "NSException",
                 sizeof(s_report->exception_type));
    safe_strlcpy(s_report->exception_message, reason ? reason : "",
                 sizeof(s_report->exception_message));

    atomic_store(&s_nsexception_caught, true);
}
