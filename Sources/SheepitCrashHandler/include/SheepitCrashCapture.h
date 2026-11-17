// Sheepit SDK — the decidable parts of crash capture, as functions with no global state.
//
// The signal handler calls these; the Swift tests call them with synthetic inputs, because CI
// cannot raise a real signal on a device. Every function here is async-signal-safe: no heap, no
// locks, no Objective-C or Swift runtime, and memory that might be unmapped is read only through
// `sheepit_safe_read` (vm_read_overwrite), so a corrupt pointer returns an error instead of
// faulting inside the handler.

#ifndef SHEEPIT_CRASH_CAPTURE_H
#define SHEEPIT_CRASH_CAPTURE_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include "SheepitCrashHandler.h"

#ifdef __cplusplus
extern "C" {
#endif

/// The furthest a frame pointer may sit above the stack pointer (16 MiB — above any thread
/// stack on iOS, and the macOS main thread's 8 MiB default).
#define SHEEPIT_MAX_STACK_SPAN 16777216u  // 16 MiB; a literal so Swift imports it

/// Registers a stack walk starts from.
typedef struct {
    uintptr_t pc;
    uintptr_t lr;
    uintptr_t fp;
    uintptr_t sp;
    bool has_lr;   // arm64 only; x86_64 keeps the return address on the stack
} sheepit_register_seed_t;

/// Copy `len` bytes from `src` without dereferencing it. @return false if any byte is unreadable.
bool sheepit_safe_read(uintptr_t src, void *dst, size_t len);

/// Copy a NUL-terminated string from `src` into `dst` (at most `cap - 1` bytes, always
/// terminated). @return the bytes copied; 0 when `src` is NULL or unreadable.
size_t sheepit_safe_read_cstring(uintptr_t src, char *dst, size_t cap);

/// The all-ones mask covering every address up to `max_end` (the highest end of a loaded image).
/// Code addresses never exceed it, so the bits above it are pointer-auth signature bits.
uintptr_t sheepit_code_mask_for_end(uintptr_t max_end);

/// Strip pointer-auth bits from a code address with `code_mask` (see sheepit_code_mask_for_end).
uintptr_t sheepit_strip_pac(uintptr_t addr, uintptr_t code_mask);

/// Index of the image whose [load_address, load_address + size) contains `addr`, or -1.
int32_t sheepit_image_index_for_addr(uintptr_t addr, const sheepit_binary_image_list_t *images);

/// Whether `fp` can be the next frame record: non-zero, aligned, strictly above `prev_fp`,
/// at or above `sp`, and within SHEEPIT_MAX_STACK_SPAN of it.
bool sheepit_fp_plausible(uintptr_t fp, uintptr_t prev_fp, uintptr_t sp);

/// Walk a stack from `seed` into `out` (at most `max`): the PC, then the LR when present, then
/// each return address along the frame-pointer chain (the first one skipped when it repeats the
/// LR). Every candidate is pointer-auth stripped and must fall inside an image of `images`,
/// unless `accept_unmatched` (the image table was truncated); a candidate that does not is
/// counted in `*dropped` and left out. Frame records are read with sheepit_safe_read.
/// @return the number of frames written.
uint32_t sheepit_walk_stack(const sheepit_register_seed_t *seed,
                            const sheepit_binary_image_list_t *images,
                            uintptr_t code_mask,
                            bool accept_unmatched,
                            uintptr_t *out,
                            uint32_t max,
                            uint32_t *dropped);

/// Look up the compact-unwind encoding of the function containing `pc_offset` (bytes from the
/// image's mach header) in an `__unwind_info` section, and that function's start offset.
/// Handles regular and compressed second-level pages. @return false when it cannot tell.
bool sheepit_unwind_lookup(uintptr_t section_addr, uint64_t section_size, uint32_t pc_offset,
                           uint32_t *encoding, uint32_t *function_offset);

/// Whether LR still holds the return address of the function at `pc_offset`: true for a
/// frameless leaf or unknown encoding, false for an arm64 frame function past its prologue
/// (it has saved LR in its frame record, and LR now points inside the function).
bool sheepit_lr_is_live(uint32_t encoding, uint32_t pc_offset, uint32_t function_offset);

/// Whether a section `[section_addr, +section_size)` lies wholly inside its segment
/// `[segment_addr, +segment_size)` (link-time addresses; overflow-safe; empty is refused).
bool sheepit_section_within_segment(uint64_t section_addr, uint64_t section_size,
                                    uint64_t segment_addr, uint64_t segment_size);

/// Decode an arm64 `brk #imm` instruction word. @return false for any other instruction.
bool sheepit_decode_brk_immediate(uint32_t instruction, uint32_t *immediate);

/// Read the crash-annotation message from one `__crash_info` section (a
/// `crashreporter_annotations_t`, versions 4, 5 and 7) at `section_addr`: `message`, then
/// `message2` after a newline. A string is copied only when its NUL lies within
/// SHEEPIT_ANNOTATION_MAX_SCAN readable bytes (else it is not trusted to be a string), and at
/// most `cap - 1` bytes are kept. @return the bytes written to `out` (0 when there is none).
size_t sheepit_parse_crash_annotations(uintptr_t section_addr, uint64_t section_size,
                                       char *out, size_t cap);

#define SHEEPIT_ANNOTATION_MAX_SCAN 16384u

/// Whether an image's crash annotation may be uploaded, from its full path and its mach header's
/// `filetype` and `flags`: the process's executable (`MH_EXECUTE`), or a dylib in the dyld shared
/// cache (`MH_DYLIB_IN_CACHE`) named `libswiftCore`, `libswift_Concurrency`, `libc++abi`,
/// `libobjc.A`, `libdispatch` or `libsystem_*`. A bundled dylib with one of those names is not
/// in the cache and is refused; so is any other library's text.
bool sheepit_annotation_image_allowed(const char *image_path, uint32_t filetype, uint32_t flags);

/// The shared-cache `libswiftCore.dylib`, whose message is preferred over any other.
bool sheepit_annotation_image_is_swift_runtime(const char *image_path, uint32_t flags);

/// One image's `__crash_info` section, found while the image table was captured.
typedef struct {
    uintptr_t section_addr;
    uint64_t section_size;
    bool is_swift_runtime;
} sheepit_annotation_source_t;

/// The message of the first source that has one, the Swift runtime's preferred.
/// @return the bytes written to `out`.
size_t sheepit_read_crash_annotation_message(const sheepit_annotation_source_t *sources, uint32_t count,
                                             char *out, size_t cap);

/// The directory every image of the app lives under, from the main executable's path: through
/// the last ".app/" when there is one, else the executable's directory. @return its length.
size_t sheepit_app_bundle_prefix(const char *exe_path, char *out, size_t cap);

#ifdef __cplusplus
}
#endif

#endif /* SHEEPIT_CRASH_CAPTURE_H */
