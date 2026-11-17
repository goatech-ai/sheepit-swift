// Sheepit SDK — safe memory reads, pointer-auth stripping and the frame-pointer walk.
//
// Declared in include/SheepitCrashCapture.h. Everything here is async-signal-safe and free of
// global state, so the Swift tests drive it with synthetic stacks and image tables.

#include "SheepitCrashCapture.h"
#include "sheepit_crash_internal.h"

#include <string.h>

#if defined(__APPLE__)
#include <mach/mach.h>
#include <mach/vm_map.h>
#endif

#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif

// arm64 frame records are 16-byte aligned (SP alignment is enforced in hardware); x86_64 keeps
// rbp 8-byte aligned at minimum.
#if defined(__x86_64__)
#define SHEEPIT_FP_ALIGN 8u
#else
#define SHEEPIT_FP_ALIGN 16u
#endif

void sheepit_internal_strlcpy(char *dst, const char *src, size_t size) {
    if (!dst || size == 0) return;
    size_t i = 0;
    if (src) {
        while (i < size - 1 && src[i] != '\0') {
            dst[i] = src[i];
            i++;
        }
    }
    dst[i] = '\0';
}

size_t sheepit_internal_utf8_trim(char *s, size_t len) {
    if (!s || len == 0) return 0;
    // Find the lead byte of the last sequence (at most 3 continuation bytes back).
    size_t lead = len;
    size_t back = 0;
    while (lead > 0 && back < 4) {
        unsigned char c = (unsigned char)s[lead - 1];
        lead--;
        back++;
        if ((c & 0xC0u) != 0x80u) {
            size_t need = 1;
            if ((c & 0xE0u) == 0xC0u) need = 2;
            else if ((c & 0xF0u) == 0xE0u) need = 3;
            else if ((c & 0xF8u) == 0xF0u) need = 4;
            if (len - lead < need) {
                s[lead] = '\0';
                return lead;
            }
            return len;
        }
    }
    return len;
}

bool sheepit_safe_read(uintptr_t src, void *dst, size_t len) {
    if (len == 0) return true;
    if (src == 0 || dst == NULL) return false;
#if defined(__APPLE__)
    vm_size_t copied = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)src, (vm_size_t)len,
                                         (vm_address_t)dst, &copied);
    return kr == KERN_SUCCESS && copied == (vm_size_t)len;
#else
    return false;
#endif
}

size_t sheepit_safe_read_cstring(uintptr_t src, char *dst, size_t cap) {
    if (!dst || cap == 0) return 0;
    dst[0] = '\0';
    if (src == 0) return 0;
#if defined(__APPLE__)
    size_t page = (size_t)vm_page_size;
#else
    size_t page = 4096;
#endif
    if (page == 0) page = 4096;
    size_t copied = 0;
    // Page by page, so a string that ends just before an unmapped page is still read whole.
    while (copied < cap - 1) {
        uintptr_t at = src + copied;
        if (at < src) break;
        size_t want = cap - 1 - copied;
        size_t room = page - (size_t)(at % page);
        if (want > room) want = room;
        if (!sheepit_safe_read(at, dst + copied, want)) break;
        for (size_t i = 0; i < want; i++) {
            if (dst[copied + i] == '\0') return copied + i;
        }
        copied += want;
    }
    dst[copied] = '\0';
    return sheepit_internal_utf8_trim(dst, copied);
}

uintptr_t sheepit_code_mask_for_end(uintptr_t max_end) {
    if (max_end == 0) return ~(uintptr_t)0;
    uintptr_t m = max_end - 1;
    m |= m >> 1;
    m |= m >> 2;
    m |= m >> 4;
    m |= m >> 8;
    m |= m >> 16;
#if UINTPTR_MAX > 0xFFFFFFFFu
    m |= m >> 32;
#endif
    return m;
}

uintptr_t sheepit_strip_pac(uintptr_t addr, uintptr_t code_mask) {
#if __has_feature(ptrauth_calls)
    addr = (uintptr_t)ptrauth_strip((void *)addr, ptrauth_key_process_independent_code);
#endif
    // A non-arm64e build cannot use the intrinsic, and an arm64 process still sees signed return
    // addresses from the arm64e system libraries. Code never lies above the highest loaded
    // image, so every bit above `code_mask` is signature, not address.
    return addr & code_mask;
}

int32_t sheepit_image_index_for_addr(uintptr_t addr, const sheepit_binary_image_list_t *images) {
    if (!images || addr == 0) return -1;
    uint32_t n = images->image_count < SHEEPIT_MAX_IMAGES ? images->image_count : SHEEPIT_MAX_IMAGES;
    for (uint32_t i = 0; i < n; i++) {
        uintptr_t start = images->images[i].load_address;
        uintptr_t size = images->images[i].size;
        if (addr >= start && addr - start < size) return (int32_t)i;
    }
    return -1;
}

bool sheepit_fp_plausible(uintptr_t fp, uintptr_t prev_fp, uintptr_t sp) {
    if (fp == 0) return false;
    if (fp % SHEEPIT_FP_ALIGN != 0) return false;
    if (fp <= prev_fp) return false;
    if (sp != 0) {
        if (fp < sp) return false;
        if (fp - sp > SHEEPIT_MAX_STACK_SPAN) return false;
    }
    return true;
}

static bool accept_frame(uintptr_t addr, const sheepit_binary_image_list_t *images, bool accept_unmatched) {
    return accept_unmatched || sheepit_image_index_for_addr(addr, images) >= 0;
}

uint32_t sheepit_walk_stack(const sheepit_register_seed_t *seed,
                            const sheepit_binary_image_list_t *images,
                            uintptr_t code_mask,
                            bool accept_unmatched,
                            uintptr_t *out,
                            uint32_t max,
                            uint32_t *dropped) {
    uint32_t n = 0;
    uint32_t drops = 0;
    if (!seed || !out || max == 0) {
        if (dropped) *dropped = 0;
        return 0;
    }

    uintptr_t pc = sheepit_strip_pac(seed->pc, code_mask);
    if (pc != 0) {
        if (accept_frame(pc, images, accept_unmatched)) out[n++] = pc;
        else drops++;
    }

    uintptr_t kept_lr = 0;
    if (seed->has_lr && n < max) {
        uintptr_t lr = sheepit_strip_pac(seed->lr, code_mask);
        if (lr != 0 && lr != pc) {  // LR == PC: trapped right after the call that set it
            if (accept_frame(lr, images, accept_unmatched)) {
                out[n++] = lr;
                kept_lr = lr;
            } else {
                drops++;
            }
        }
    }

    // fp[0] = the caller's fp, fp[1] = the return address. Bounded in steps as well as frames,
    // so a chain of records whose return addresses are all dropped still ends.
    uintptr_t fp = seed->fp;
    uintptr_t prev = 0;
    bool first = true;
    uint32_t steps_left = max * 2u + 2u;
    while (n < max && steps_left-- > 0 && sheepit_fp_plausible(fp, prev, seed->sp)) {
        uintptr_t record[2];
        if (!sheepit_safe_read(fp, record, sizeof(record))) break;
        uintptr_t ret = sheepit_strip_pac(record[1], code_mask);
        if (ret == 0) break;
        // A function past its prologue saved LR in this record: the same frame twice.
        bool repeats_lr = first && kept_lr != 0 && ret == kept_lr;
        if (!repeats_lr) {
            if (accept_frame(ret, images, accept_unmatched)) out[n++] = ret;
            else drops++;
        }
        first = false;
        prev = fp;
        fp = record[0];
    }

    if (dropped) *dropped = drops;
    return n;
}

bool sheepit_decode_brk_immediate(uint32_t instruction, uint32_t *immediate) {
    // BRK #imm16: 1101 0100 001 imm16 000 00
    if ((instruction & 0xFFE0001Fu) != 0xD4200000u) return false;
    if (immediate) *immediate = (instruction >> 5) & 0xFFFFu;
    return true;
}

size_t sheepit_app_bundle_prefix(const char *exe_path, char *out, size_t cap) {
    if (!out || cap == 0) return 0;
    out[0] = '\0';
    if (!exe_path) return 0;
    size_t len = strlen(exe_path);
    size_t end = 0;
    for (size_t i = 0; i + 5 <= len; i++) {
        if (memcmp(exe_path + i, ".app/", 5) == 0) end = i + 5;
    }
    if (end == 0) {
        for (size_t i = 0; i < len; i++) {
            if (exe_path[i] == '/') end = i + 1;
        }
    }
    if (end == 0 || end >= cap) return 0;
    memcpy(out, exe_path, end);
    out[end] = '\0';
    return end;
}

bool sheepit_section_within_segment(uint64_t section_addr, uint64_t section_size,
                                    uint64_t segment_addr, uint64_t segment_size) {
    if (section_size == 0 || section_addr < segment_addr) return false;
    uint64_t offset = section_addr - segment_addr;
    return offset <= segment_size && section_size <= segment_size - offset;
}
