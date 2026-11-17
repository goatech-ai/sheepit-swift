// Sheepit SDK — is the link register still the crashed function's return address?
//
// arm64 keeps a function's return address in LR only until the function saves it and makes a
// call; after that, LR points INSIDE the function, and recording it as frame 1 shows the
// crashing function twice. A frameless leaf (objc_msgSend, memcpy, …) never saves it, and LR is
// then the only record of its caller. The image's compact unwind info (`__TEXT,__unwind_info`)
// says which kind the function is — the same source Apple's unwinder uses. Read with
// sheepit_safe_read throughout; any doubt keeps LR, as the walk does when there is no unwind info.

#include "SheepitCrashCapture.h"
#include "sheepit_crash_internal.h"

#include <string.h>

#if defined(__APPLE__)
#include <mach-o/loader.h>
#endif

#define SHEEPIT_UNWIND_MODE_MASK        0x0F000000u
#define SHEEPIT_UNWIND_ARM64_FRAMELESS  0x02000000u
#define SHEEPIT_UNWIND_ARM64_FRAME      0x04000000u
#define SHEEPIT_UNWIND_ARM64_FRAME_PAC  0x05000000u
// `pacibsp; stp x29, x30, [sp, #-N]!; mov x29, sp` (or a `sub sp` + `add x29` pair) sets the
// frame within four instructions; before that, LR is still live.
#define SHEEPIT_PROLOGUE_BYTES 16u

static bool read_u32(uintptr_t base, uint64_t size, uint64_t offset, uint32_t *out) {
    if (offset > size || size - offset < sizeof(uint32_t)) return false;
    return sheepit_safe_read(base + (uintptr_t)offset, out, sizeof(uint32_t));
}

static bool read_u16(uintptr_t base, uint64_t size, uint64_t offset, uint16_t *out) {
    if (offset > size || size - offset < sizeof(uint16_t)) return false;
    return sheepit_safe_read(base + (uintptr_t)offset, out, sizeof(uint16_t));
}

bool sheepit_unwind_lookup(uintptr_t section_addr, uint64_t section_size, uint32_t pc_offset,
                           uint32_t *encoding, uint32_t *function_offset) {
    uint32_t version = 0, common_off = 0, common_count = 0, index_off = 0, index_count = 0;
    if (!read_u32(section_addr, section_size, 0, &version) || version != 1) return false;
    if (!read_u32(section_addr, section_size, 4, &common_off) ||
        !read_u32(section_addr, section_size, 8, &common_count) ||
        !read_u32(section_addr, section_size, 20, &index_off) ||
        !read_u32(section_addr, section_size, 24, &index_count) || index_count < 2) return false;

    // First level: entries of {functionOffset, secondLevelPagesSectionOffset, lsda} (12 bytes),
    // sorted, the last a sentinel. Find the last entry starting at or before pc_offset.
    uint32_t lo = 0, hi = index_count - 1;  // the sentinel is never a candidate
    uint32_t first_fn = 0;
    if (!read_u32(section_addr, section_size, index_off, &first_fn) || pc_offset < first_fn) return false;
    while (hi - lo > 1) {
        uint32_t mid = lo + (hi - lo) / 2;
        uint32_t fn = 0;
        if (!read_u32(section_addr, section_size, (uint64_t)index_off + (uint64_t)mid * 12u, &fn)) return false;
        if (fn <= pc_offset) lo = mid; else hi = mid;
    }
    uint32_t base_fn = 0, page_off = 0, end_fn = 0;
    uint64_t entry = (uint64_t)index_off + (uint64_t)lo * 12u;
    if (!read_u32(section_addr, section_size, entry, &base_fn) ||
        !read_u32(section_addr, section_size, entry + 4, &page_off) ||
        !read_u32(section_addr, section_size, entry + 12, &end_fn) ||
        page_off == 0 || pc_offset >= end_fn) return false;

    uint32_t kind = 0;
    if (!read_u32(section_addr, section_size, page_off, &kind)) return false;
    uint16_t entries_off = 0, entry_count = 0;
    if (!read_u16(section_addr, section_size, (uint64_t)page_off + 4, &entries_off) ||
        !read_u16(section_addr, section_size, (uint64_t)page_off + 6, &entry_count) || entry_count == 0) return false;
    uint64_t entries = (uint64_t)page_off + entries_off;

    // Second level: the last entry starting at or before pc_offset.
    uint32_t a = 0, b = entry_count;
    if (kind == 2) {  // UNWIND_SECOND_LEVEL_REGULAR: {functionOffset, encoding} pairs
        while (b - a > 1) {
            uint32_t mid = a + (b - a) / 2;
            uint32_t fn = 0;
            if (!read_u32(section_addr, section_size, entries + (uint64_t)mid * 8u, &fn)) return false;
            if (fn <= pc_offset) a = mid; else b = mid;
        }
        uint32_t fn = 0, enc = 0;
        if (!read_u32(section_addr, section_size, entries + (uint64_t)a * 8u, &fn) ||
            !read_u32(section_addr, section_size, entries + (uint64_t)a * 8u + 4, &enc) || fn > pc_offset) return false;
        *function_offset = fn;
        *encoding = enc;
        return true;
    }
    if (kind == 3) {  // UNWIND_SECOND_LEVEL_COMPRESSED: 24-bit offset from base_fn | 8-bit encoding index
        uint16_t encodings_off = 0, encodings_count = 0;
        if (!read_u16(section_addr, section_size, (uint64_t)page_off + 8, &encodings_off) ||
            !read_u16(section_addr, section_size, (uint64_t)page_off + 10, &encodings_count)) return false;
        while (b - a > 1) {
            uint32_t mid = a + (b - a) / 2;
            uint32_t e = 0;
            if (!read_u32(section_addr, section_size, entries + (uint64_t)mid * 4u, &e)) return false;
            if (base_fn + (e & 0x00FFFFFFu) <= pc_offset) a = mid; else b = mid;
        }
        uint32_t e = 0;
        if (!read_u32(section_addr, section_size, entries + (uint64_t)a * 4u, &e)) return false;
        uint32_t fn = base_fn + (e & 0x00FFFFFFu);
        uint32_t index = (e >> 24) & 0xFFu;
        if (fn > pc_offset) return false;
        uint32_t enc = 0;
        if (index < common_count) {
            if (!read_u32(section_addr, section_size, (uint64_t)common_off + (uint64_t)index * 4u, &enc)) return false;
        } else {
            uint32_t local = index - common_count;
            if (local >= encodings_count) return false;
            if (!read_u32(section_addr, section_size,
                          (uint64_t)page_off + encodings_off + (uint64_t)local * 4u, &enc)) return false;
        }
        *function_offset = fn;
        *encoding = enc;
        return true;
    }
    return false;
}

bool sheepit_lr_is_live(uint32_t encoding, uint32_t pc_offset, uint32_t function_offset) {
    uint32_t mode = encoding & SHEEPIT_UNWIND_MODE_MASK;
    if (mode == SHEEPIT_UNWIND_ARM64_FRAME || mode == SHEEPIT_UNWIND_ARM64_FRAME_PAC) {
        return pc_offset - function_offset < SHEEPIT_PROLOGUE_BYTES;
    }
    return true;  // frameless leaf; DWARF-only or no unwind info: no evidence against LR
}

#if defined(__APPLE__)

bool sheepit_internal_load_commands_readable(const struct mach_header_64 *header) {
    if (!header) return false;
    struct mach_header_64 copy;
    if (!sheepit_safe_read((uintptr_t)header, &copy, sizeof(copy)) || copy.magic != MH_MAGIC_64) return false;
    // Real images carry a few KB of load commands; anything larger is corrupt, and probing it
    // would cost a trap per page inside the handler.
    if (copy.sizeofcmds > SHEEPIT_MAX_LOAD_COMMANDS_BYTES) return false;
    // Probe one byte per page of the load-command area: a header whose commands run into an
    // unmapped page (a corrupt or half-loaded image) is skipped instead of faulting the handler.
    uintptr_t start = (uintptr_t)header;
    uintptr_t end = start + sizeof(copy) + copy.sizeofcmds;
    if (end < start) return false;
    uint8_t byte;
    for (uintptr_t at = start; at < end; at += 4096) {
        if (!sheepit_safe_read(at, &byte, 1)) return false;
    }
    return sheepit_safe_read(end - 1, &byte, 1);
}

bool sheepit_internal_next_command(const struct mach_header_64 *header, uint32_t *offset,
                                   const struct load_command **cmd) {
    // `offset` walks [0, sizeofcmds); every command must fit inside it.
    if (*offset >= header->sizeofcmds || header->sizeofcmds - *offset < sizeof(struct load_command)) return false;
    const struct load_command *c = (const struct load_command *)((const uint8_t *)(header + 1) + *offset);
    if (c->cmdsize < sizeof(struct load_command) || c->cmdsize > header->sizeofcmds - *offset) return false;
    *cmd = c;
    *offset += c->cmdsize;
    return true;
}

bool sheepit_internal_lr_is_live_at(uintptr_t pc, const sheepit_binary_image_list_t *images) {
    int32_t i = sheepit_image_index_for_addr(pc, images);
    if (i < 0) return true;
    uintptr_t base = images->images[i].load_address;
    // Located once, when the image table was captured: no second load-command walk here.
    const sheepit_image_sections_t *sections = &sheepit_internal_image_sections()[i];
    if (sections->unwind_info == 0) return true;
    uint32_t encoding = 0, function_offset = 0;
    uint32_t pc_offset = (uint32_t)(pc - base);
    if (!sheepit_unwind_lookup(sections->unwind_info, sections->unwind_info_size, pc_offset,
                               &encoding, &function_offset)) return true;
    return sheepit_lr_is_live(encoding, pc_offset, function_offset);
}

#endif
