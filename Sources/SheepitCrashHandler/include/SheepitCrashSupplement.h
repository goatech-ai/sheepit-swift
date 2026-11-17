// Sheepit SDK — crash supplement (sidecar) file.
//
// `sheepit_crash_report_t` is a FROZEN on-disk contract (see SheepitCrashHandler.h): an older
// build reads what a newer one wrote, and the reverse, so it can never grow. Everything the
// handler captures beyond it lives in this SEPARATE mmap'd file, with its own magic and its own
// `format_version`. A build that does not know the file never opens it; a report with no valid
// supplement is still read and uploaded, degraded to what the frozen struct holds.
//
// Correlation: the handler copies the report's `timestamp_ms` into `report_timestamp_ms` and the
// reader uses the supplement ONLY when the two are equal, so a stale sidecar (left by a crash an
// older build handled) never attaches to a newer report.
//
// ON-DISK FORMAT v1 IS FROZEN as well: do not reorder or resize fields. A change ships as a new
// `format_version`; a reader skips a version it does not know.
//
// Plan: Docs/Technical/CRASH_SYMBOLICATION_PLAN.md, "M1 — SDK".

#ifndef SHEEPIT_CRASH_SUPPLEMENT_H
#define SHEEPIT_CRASH_SUPPLEMENT_H

#include <stdint.h>
#include <stdbool.h>
#include "SheepitCrashHandler.h"

#ifdef __cplusplus
extern "C" {
#endif

#define SHEEPIT_SUPPLEMENT_MAGIC          0x534B5350  // bytes "SKSP"
#define SHEEPIT_SUPPLEMENT_FORMAT_VERSION 1
#define SHEEPIT_SUPPLEMENT_MESSAGE_LEN    1024

// `flags` bits.
#define SHEEPIT_SUPPLEMENT_HAS_REGISTERS    0x1u  // pc/lr/fp/sp came from the signal ucontext
#define SHEEPIT_SUPPLEMENT_HAS_BRK          0x2u  // brk_immediate holds the trapping `brk #imm`
#define SHEEPIT_SUPPLEMENT_IMAGES_TRUNCATED 0x4u  // image table incomplete (>512 images, or one unreadable): frames kept unchecked
#define SHEEPIT_SUPPLEMENT_HAS_ANNOTATION   0x8u  // exception_message came from a __crash_info section

typedef struct {
    uint32_t format_version;
    uint32_t flags;
    uint64_t report_timestamp_ms;   // == sheepit_crash_report_t.timestamp_ms, or ignore this file
    // Crashed thread at the trap site, pointer-auth bits stripped.
    uint64_t pc;
    uint64_t lr;
    uint64_t fp;
    uint64_t sp;
    uint32_t brk_immediate;
    uint32_t frames_dropped;        // candidate frames that matched no loaded image
    // The crash-annotation message (e.g. the Swift runtime's "Fatal error: …"), or for an
    // NSException its reason — the frozen report's field is only 512 bytes.
    char exception_message[SHEEPIT_SUPPLEMENT_MESSAGE_LEN];
    char os_build[32];              // kern.osversion, captured at install (sysctl is not signal-safe)
    char arch[16];
    char sdk_version[32];           // the SheepitKit version that captured this crash
    // Parallel to sheepit_crash_report_t.images.images[i]; image_count must equal the report's.
    uint32_t image_count;
    uint8_t is_app_image[SHEEPIT_MAX_IMAGES];
    int32_t cpu_type[SHEEPIT_MAX_IMAGES];
    int32_t cpu_subtype[SHEEPIT_MAX_IMAGES];
    int64_t vmaddr_slide[SHEEPIT_MAX_IMAGES];
    uint32_t magic;                 // written LAST by the handler
} sheepit_crash_supplement_t;

// The complete v1 prefix above and v2 receipt layout remain frozen.
#define SHEEPIT_SUPPLEMENT_ASSIGNMENT_VERSION 2
#define SHEEPIT_SUPPLEMENT_COHORT_VERSION 3
#define SHEEPIT_ASSIGNMENT_TOKEN_BYTES 97
#define SHEEPIT_CRASH_IDENTITY_BYTES 769

typedef struct {
    char token[SHEEPIT_ASSIGNMENT_TOKEN_BYTES];
    uint8_t identity_changed;
} sheepit_assignment_receipt_t;

typedef struct {
    sheepit_crash_supplement_t legacy;
    sheepit_assignment_receipt_t assignment;
} sheepit_crash_supplement_v2_t;

// One full occurrence identity and receipt; valid=0 is explicitly unavailable.
typedef struct {
    uint32_t generation;
    uint8_t valid;
    uint8_t has_user;
    uint8_t has_session;
    uint8_t reserved;
    char user_id[SHEEPIT_CRASH_IDENTITY_BYTES];
    char device_id[SHEEPIT_CRASH_IDENTITY_BYTES];
    char session_id[SHEEPIT_CRASH_IDENTITY_BYTES];
    sheepit_assignment_receipt_t assignment;
} sheepit_crash_cohort_t;

typedef struct {
    sheepit_crash_supplement_t legacy;
    sheepit_crash_cohort_t cohort;
} sheepit_crash_supplement_v3_t;

/// Serialized normal-context publication; invalid/oversized input invalidates the cohort.
bool sheepit_crash_cohort_set(const char *user, const char *device, const char *session,
                              const char *token, bool identity_changed);
/// One bounded lock-free read; a concurrent/interrupted writer yields valid=0, never retries.
void sheepit_crash_cohort_snapshot(sheepit_crash_cohort_t *out);
/// Read the saved v3 cohort. Failure never substitutes the uploader's current identity.
typedef enum {
    SHEEPIT_COHORT_LEGACY = 0,
    SHEEPIT_COHORT_COHERENT = 1,
    SHEEPIT_COHORT_UNAVAILABLE = 2
} sheepit_crash_cohort_outcome_t;
sheepit_crash_cohort_outcome_t sheepit_read_crash_cohort(
    const char *path, uint64_t timestamp_ms, uint32_t image_count, sheepit_crash_cohort_t *out);
/// Retain the recorded receipt of a valid v2 file; the v3 reader uses its single saved cohort.
bool sheepit_read_crash_assignment(const char *path, uint64_t timestamp_ms,
                                   sheepit_assignment_receipt_t *out);

/// Map the supplement file for this session (truncating it). Call right after
/// `sheepit_crash_handler_install`; a failure only degrades capture. `sheepit_crash_handler_uninstall`
/// unmaps it. `sdk_version` is stamped into the file. @return 0 on success, -1 on failure.
int sheepit_crash_supplement_install(const char *supplement_file_path, const char *sdk_version);

/// Read a supplement written for the report stamped `report_timestamp_ms`. Caller must free().
/// @return NULL when the file is absent, short, of another magic or format version, or written
///         for a different report.
sheepit_crash_supplement_t *sheepit_read_crash_supplement(const char *supplement_file_path,
                                                          uint64_t report_timestamp_ms);

#ifdef __cplusplus
}
#endif

#endif /* SHEEPIT_CRASH_SUPPLEMENT_H */
