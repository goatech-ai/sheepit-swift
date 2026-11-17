// Sheepit SDK — the crash-annotation message (`__crash_info` / crashreporter_annotations_t).
//
// The Swift runtime (libswiftCore) writes its fatal-error text — "Fatal error: Unexpectedly found
// nil while unwrapping an Optional value" — into its own `__DATA,__crash_info` section before it
// traps; libsystem writes abort() reasons the same way. Apple's crash reporter reads them as
// "Application Specific Information". Without this a Swift trap reached the server as a bare
// SIGTRAP with an empty message.
//
// Layout (CrashReporterClient.h, not in the public SDK): eight uint64_t fields — version,
// message, signature_string, backtrace, message2, thread, dialog_mode, abort_cause. Only the
// first five are read, which versions 4, 5 and 7 share. Only allowlisted images are read
// (sheepit_annotation_image_allowed): their sections are located once, while the image table is
// captured (sheepit_crash_threads.c), so this file walks no image list of its own.

#include "SheepitCrashCapture.h"
#include "SheepitCrashSupplement.h"
#include "sheepit_crash_internal.h"

#include <string.h>
#include <mach-o/loader.h>

#ifndef MH_DYLIB_IN_CACHE
#define MH_DYLIB_IN_CACHE 0x80000000
#endif

typedef struct {
    uint64_t version;
    uint64_t message;
    uint64_t signature_string;
    uint64_t backtrace;
    uint64_t message2;
} sheepit_crash_annotations_head_t;

static bool annotations_version_supported(uint64_t version) {
    return version == 4 || version == 5 || version == 7;
}

/// Copy the C string at `src`, keeping the first `cap - 1` bytes, only when its NUL lies within
/// SHEEPIT_ANNOTATION_MAX_SCAN readable bytes. No NUL in the window, or an unreadable byte before
/// it, rejects the pointer: a stale pointer into reused memory must not upload that memory as the
/// crash message, so an over-long message is dropped rather than truncated.
static size_t read_terminated(uintptr_t src, char *out, size_t cap) {
    out[0] = '\0';
    if (src == 0 || cap == 0) return 0;
    char chunk[64];
    size_t copied = 0;
    size_t scanned = 0;
    while (scanned < SHEEPIT_ANNOTATION_MAX_SCAN) {
        uintptr_t at = src + scanned;
        if (at < src) break;
        size_t want = sizeof(chunk);
        size_t page_room = 4096 - (size_t)(at % 4096);
        if (want > page_room) want = page_room;
        if (want > SHEEPIT_ANNOTATION_MAX_SCAN - scanned) want = SHEEPIT_ANNOTATION_MAX_SCAN - scanned;
        if (!sheepit_safe_read(at, chunk, want)) {
            out[0] = '\0';
            return 0;
        }
        for (size_t i = 0; i < want; i++) {
            if (chunk[i] == '\0') {
                out[copied] = '\0';
                return sheepit_internal_utf8_trim(out, copied);
            }
            if (copied < cap - 1) out[copied++] = chunk[i];
        }
        scanned += want;
    }
    out[0] = '\0';  // no NUL within the window, or the address wrapped
    return 0;
}

size_t sheepit_parse_crash_annotations(uintptr_t section_addr, uint64_t section_size,
                                       char *out, size_t cap) {
    if (!out || cap == 0) return 0;
    out[0] = '\0';
    if (section_addr == 0 || section_size < sizeof(sheepit_crash_annotations_head_t)) return 0;

    sheepit_crash_annotations_head_t head;
    if (!sheepit_safe_read(section_addr, &head, sizeof(head))) return 0;
    if (!annotations_version_supported(head.version)) return 0;

    size_t len = read_terminated((uintptr_t)head.message, out, cap);
    if (head.message2 != 0) {
        size_t start = len > 0 ? len + 1 : 0;   // room for the '\n' separator
        if (start + 1 < cap) {
            size_t more = read_terminated((uintptr_t)head.message2, out + start, cap - start);
            if (more > 0) {
                if (len > 0) out[len] = '\n';
                len = start + more;
            } else {
                out[len] = '\0';
            }
        }
    }
    return len;
}

static const char *basename_of(const char *path) {
    const char *base = path;
    for (const char *p = path; *p; p++) {
        if (*p == '/') base = p + 1;
    }
    return base;
}

bool sheepit_annotation_image_allowed(const char *image_path, uint32_t filetype, uint32_t flags) {
    // The process's own executable: its text is the app's, whatever its name or path.
    if (filetype == MH_EXECUTE) return true;
    // Otherwise only Apple's runtimes, and only the copies in the dyld shared cache: a dylib an
    // app bundles (or any other path) can carry any name, but cannot be in the shared cache.
    if (!(flags & MH_DYLIB_IN_CACHE) || !image_path) return false;
    const char *base = basename_of(image_path);
    static const char *const exact[] = {
        "libswiftCore.dylib", "libswift_Concurrency.dylib", "libc++abi.dylib",
        "libobjc.A.dylib", "libdispatch.dylib",
    };
    for (size_t i = 0; i < sizeof(exact) / sizeof(exact[0]); i++) {
        if (strcmp(base, exact[i]) == 0) return true;
    }
    return strncmp(base, "libsystem_", 10) == 0;
}

bool sheepit_annotation_image_is_swift_runtime(const char *image_path, uint32_t flags) {
    return (flags & MH_DYLIB_IN_CACHE) && image_path &&
           strcmp(basename_of(image_path), "libswiftCore.dylib") == 0;
}

size_t sheepit_read_crash_annotation_message(const sheepit_annotation_source_t *sources, uint32_t count,
                                             char *out, size_t cap) {
    if (!out || cap == 0) return 0;
    out[0] = '\0';
    if (!sources) return 0;

    char candidate[SHEEPIT_SUPPLEMENT_MESSAGE_LEN];
    size_t limit = cap < sizeof(candidate) ? cap : sizeof(candidate);
    size_t best = 0;
    for (uint32_t i = 0; i < count; i++) {
        size_t len = sheepit_parse_crash_annotations(sources[i].section_addr, sources[i].section_size,
                                                     candidate, limit);
        if (len == 0) continue;
        // The Swift runtime's message names the actual failure; anything else found first is
        // only a fallback.
        if (best == 0 || sources[i].is_swift_runtime) {
            memcpy(out, candidate, len + 1);
            best = len;
        }
        if (sources[i].is_swift_runtime) break;
    }
    return best;
}
