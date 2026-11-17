// Sheepit SDK — declarations shared by the crash handler's translation units. Not public:
// lives beside the .c files, outside include/, so no Swift module sees it.

#ifndef SHEEPIT_CRASH_INTERNAL_H
#define SHEEPIT_CRASH_INTERNAL_H

#include <stddef.h>
#include <stdint.h>
#include "SheepitCrashHandler.h"
#include "SheepitCrashSupplement.h"
#include "SheepitCrashCapture.h"

/// Bounded copy that always terminates `dst`. Async-signal-safe.
void sheepit_internal_strlcpy(char *dst, const char *src, size_t size);

/// Cut a trailing incomplete UTF-8 sequence off `s` (length `len`); returns the new length.
size_t sheepit_internal_utf8_trim(char *s, size_t len);

/// Capture the full cohort into the live v3 supplement, in signal context.
void sheepit_internal_capture_cohort(void);

/// The live supplement mapping for this session, or NULL (sheepit_crash_supplement.c).
sheepit_crash_supplement_t *sheepit_internal_supplement(void);

/// The app-bundle prefix captured at supplement install ("" when unknown).
const char *sheepit_internal_app_prefix(void);

/// msync + munmap the supplement mapping (called from sheepit_crash_handler_uninstall).
void sheepit_internal_supplement_sync(void);
void sheepit_internal_supplement_uninstall(void);

#if defined(__APPLE__)
#include <stdbool.h>

struct mach_header_64;
struct load_command;

/// Whether a 64-bit header and its whole load-command area are mapped (probed with safe reads).
/// Every load-command walk in the handler calls this first (sheepit_crash_unwind.c).
bool sheepit_internal_load_commands_readable(const struct mach_header_64 *header);

/// The next load command at `*offset` (from 0), bounded by `sizeofcmds`; advances `*offset`.
/// @return false at the end or on a command that does not fit.
bool sheepit_internal_next_command(const struct mach_header_64 *header, uint32_t *offset,
                                   const struct load_command **cmd);

/// Load-command areas larger than this are treated as corrupt and never walked.
#define SHEEPIT_MAX_LOAD_COMMANDS_BYTES 65536u

/// Sections of one captured image, slide applied; 0 when absent. Parallel to the image table.
typedef struct {
    uintptr_t crash_info;        // only for images sheepit_annotation_image_allowed admits
    uint64_t crash_info_size;
    uintptr_t unwind_info;
    uint64_t unwind_info_size;
    bool is_swift_runtime;
} sheepit_image_sections_t;

/// The table sheepit_internal_capture_images filled (SHEEPIT_MAX_IMAGES entries).
const sheepit_image_sections_t *sheepit_internal_image_sections(void);

/// The allowlisted `__crash_info` sections of the captured image table, into `out` (≤ max).
uint32_t sheepit_internal_annotation_sources(const sheepit_binary_image_list_t *list,
                                             sheepit_annotation_source_t *out, uint32_t max);

/// sheepit_lr_is_live for the function at `pc`, from its image's __unwind_info as captured;
/// true when the image or its unwind info is unknown (sheepit_crash_unwind.c).
bool sheepit_internal_lr_is_live_at(uintptr_t pc, const sheepit_binary_image_list_t *images);

/// What an image scan learned beyond the table it filled.
typedef struct {
    uintptr_t code_mask;   // sheepit_code_mask_for_end over EVERY loaded image, not just the stored ones
    bool truncated;        // more images were loaded than SHEEPIT_MAX_IMAGES
} sheepit_image_scan_t;

/// Capture the binary image table; fills the supplement's parallel arrays when `supp` is set.
sheepit_image_scan_t sheepit_internal_capture_images(sheepit_binary_image_list_t *list,
                                                     sheepit_crash_supplement_t *supp);

/// Capture every thread. The crashed thread (the one running the handler) is walked from
/// `ucontext` when it is non-NULL; every other thread is suspended and read with
/// thread_get_state. Fills the supplement's registers, brk immediate and drop count.
void sheepit_internal_capture_threads(sheepit_thread_capture_t *capture,
                                      const sheepit_binary_image_list_t *images,
                                      sheepit_image_scan_t scan,
                                      void *ucontext,
                                      sheepit_crash_supplement_t *supp);
#endif

#endif /* SHEEPIT_CRASH_INTERNAL_H */
