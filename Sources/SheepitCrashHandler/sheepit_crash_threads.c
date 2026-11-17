// Sheepit SDK — binary-image and thread capture, run from inside the signal handler.
//
// The crashed thread is walked from the signal's ucontext — the registers at the trap site.
// Reading it with thread_get_state, as before 0.10.1, returned the state of a thread that was
// executing the handler, so the top frames were the handler's own. Every other thread is
// suspended and read with thread_get_state. All frame records are read with sheepit_safe_read.

#include "sheepit_crash_internal.h"
#include "SheepitCrashCapture.h"

#if defined(__APPLE__)

#include <string.h>
#include <pthread.h>
#include <signal.h>
#include <sys/ucontext.h>
#include <mach/mach.h>
#include <mach/thread_act.h>
#include <mach/thread_info.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/dyld_images.h>
#include <mach/task.h>

#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif

// Raw register fields of an arm64 thread state. The __darwin_arm_thread_state64_get_* accessors
// do NOT strip pointer auth: on a non-ptrauth build they return the field as-is, and on arm64e
// they AUTHENTICATE it, which can trap on a corrupt value — inside the handler (plan U-4,
// settled by reading <mach/arm/_structs.h> in the iOS 27.1 SDK). Read the field, strip ourselves.
#if defined(__arm64__) || defined(__aarch64__)
#if __DARWIN_OPAQUE_ARM_THREAD_STATE64
#define SHEEPIT_SS_PC(ss) ((uintptr_t)(ss).__opaque_pc)
#define SHEEPIT_SS_LR(ss) ((uintptr_t)(ss).__opaque_lr)
#define SHEEPIT_SS_FP(ss) ((uintptr_t)(ss).__opaque_fp)
#define SHEEPIT_SS_SP(ss) ((uintptr_t)(ss).__opaque_sp)
#else
#define SHEEPIT_SS_PC(ss) ((uintptr_t)(ss).__pc)
#define SHEEPIT_SS_LR(ss) ((uintptr_t)(ss).__lr)
#define SHEEPIT_SS_FP(ss) ((uintptr_t)(ss).__fp)
#define SHEEPIT_SS_SP(ss) ((uintptr_t)(ss).__sp)
#endif

/// Strip a signed stack/frame pointer (only arm64e signs them in a thread state).
static uintptr_t strip_data_pointer(uintptr_t value) {
#if __has_feature(ptrauth_calls)
    return (uintptr_t)ptrauth_strip((void *)value, ptrauth_key_process_independent_data);
#else
    return value;
#endif
}
#endif

// ── Images ──────────────────────────────────────────────────────────

// Sections found while the image table is captured, parallel to it, so nothing later in the
// handler walks an image's load commands again. Static: the handler runs once, and its stack
// is the faulting thread's.
static sheepit_image_sections_t s_sections[SHEEPIT_MAX_IMAGES];

const sheepit_image_sections_t *sheepit_internal_image_sections(void) {
    return s_sections;
}

/// A `__crash_info` / `__unwind_info` section seen in a segment: link-time address and size.
/// Kept only when it lies wholly inside that segment, so a corrupt header can never point the
/// handler's later reads outside the image's mapped extent.
static void note_section(const struct segment_command_64 *seg, const char *sectname,
                         uintptr_t *vmaddr, uint64_t *size) {
    uint64_t room = (seg->cmdsize - sizeof(struct segment_command_64)) / sizeof(struct section_64);
    uint32_t nsects = seg->nsects < room ? seg->nsects : (uint32_t)room;
    const struct section_64 *sect = (const struct section_64 *)(seg + 1);
    for (uint32_t k = 0; k < nsects; k++) {
        if (strncmp(sect[k].sectname, sectname, sizeof(sect[k].sectname)) != 0) continue;
        if (sheepit_section_within_segment(sect[k].addr, sect[k].size, seg->vmaddr, seg->vmsize)) {
            *vmaddr = (uintptr_t)sect[k].addr;
            *size = sect[k].size;
        }
        return;
    }
}

/// Record one image (or, past SHEEPIT_MAX_IMAGES, only widen the code mask and flag truncation).
static void add_image(sheepit_binary_image_list_t *list, sheepit_crash_supplement_t *supp,
                      const char *name, const struct mach_header *header,
                      uintptr_t *max_end, sheepit_image_scan_t *scan) {
    uintptr_t text_size = 0;
    uintptr_t max_segment = 0;
    uintptr_t text_vmaddr = 0;
    bool has_text = false;
    const uint8_t *uuid = NULL;
    uintptr_t crash_info = 0, unwind_info = 0;
    uint64_t crash_info_size = 0, unwind_info_size = 0;
    const char *base = name;
    for (const char *p = name; *p; p++) {
        if (*p == '/') base = p + 1;
    }
    const struct mach_header_64 *h64 = (const struct mach_header_64 *)header;
    bool readable = sheepit_internal_load_commands_readable(h64);
    // filetype and flags, not the name, decide: see sheepit_annotation_image_allowed.
    bool annotations_allowed = readable && sheepit_annotation_image_allowed(name, h64->filetype, h64->flags);
    // An image whose commands cannot be walked gets no range; rather than drop every frame in
    // it as "in no image", stop dropping unmatched frames for this report.
    if (!readable) scan->truncated = true;
    if (readable) {
        uint32_t offset = 0;
        const struct load_command *cmd = NULL;
        while (sheepit_internal_next_command(h64, &offset, &cmd)) {
            if (cmd->cmd == LC_UUID && cmd->cmdsize >= sizeof(struct uuid_command)) {
                uuid = ((const struct uuid_command *)cmd)->uuid;
            } else if (cmd->cmd == LC_SEGMENT_64 && cmd->cmdsize >= sizeof(struct segment_command_64)) {
                const struct segment_command_64 *seg = (const struct segment_command_64 *)cmd;
                if (strncmp(seg->segname, "__TEXT", sizeof(seg->segname)) == 0) {
                    text_size = (uintptr_t)seg->vmsize;
                    text_vmaddr = (uintptr_t)seg->vmaddr;
                    has_text = true;
                    note_section(seg, "__unwind_info", &unwind_info, &unwind_info_size);
                } else if (annotations_allowed && crash_info == 0 &&
                           (strncmp(seg->segname, "__DATA", sizeof(seg->segname)) == 0 ||
                            strncmp(seg->segname, "__DATA_DIRTY", sizeof(seg->segname)) == 0)) {
                    note_section(seg, "__crash_info", &crash_info, &crash_info_size);
                }
                if (strncmp(seg->segname, "__TEXT", sizeof(seg->segname)) != 0 &&
                    strncmp(seg->segname, "__PAGEZERO", sizeof(seg->segname)) != 0 &&
                    seg->vmsize > max_segment) {
                    max_segment = (uintptr_t)seg->vmsize;
                }
            }
        }
    }
    // `size` is the image's address range: __TEXT, where its code is. Before 0.10.1 it was the
    // largest segment — the main executable's 4 GiB __PAGEZERO, or a shared-cache dylib's shared
    // __LINKEDIT — so frames were attributed to the wrong image.
    uintptr_t size = has_text ? text_size : max_segment;
    uintptr_t end = (uintptr_t)header + size;
    if (end > *max_end) *max_end = end;

    if (list->image_count >= SHEEPIT_MAX_IMAGES) {
        scan->truncated = true;
        return;
    }
    uint32_t idx = list->image_count;
    sheepit_binary_image_t *img = &list->images[idx];
    memset(img, 0, sizeof(sheepit_binary_image_t));
    // Section addresses are link-time; the slide (header minus __TEXT's vmaddr) maps them.
    intptr_t slide = has_text ? (intptr_t)((uintptr_t)header - text_vmaddr) : 0;
    sheepit_image_sections_t *sections = &s_sections[idx];
    memset(sections, 0, sizeof(*sections));
    if (has_text && crash_info != 0) {
        sections->crash_info = (uintptr_t)((intptr_t)crash_info + slide);
        sections->crash_info_size = crash_info_size;
        sections->is_swift_runtime = sheepit_annotation_image_is_swift_runtime(name, h64->flags);
    }
    if (has_text && unwind_info != 0) {
        sections->unwind_info = (uintptr_t)((intptr_t)unwind_info + slide);
        sections->unwind_info_size = unwind_info_size;
    }

    sheepit_internal_strlcpy(img->name, base, sizeof(img->name));
    img->load_address = (uintptr_t)header;
    img->size = size;
    if (uuid) {
        static const char hex[] = "0123456789ABCDEF";
        char *out = img->uuid;
        for (int k = 0; k < 16; k++) {
            *out++ = hex[uuid[k] >> 4];
            *out++ = hex[uuid[k] & 0xF];
            if (k == 3 || k == 5 || k == 7 || k == 9) *out++ = '-';
        }
        *out = '\0';
    }

    if (supp) {
        const char *prefix = sheepit_internal_app_prefix();
        size_t prefix_len = prefix ? strlen(prefix) : 0;
        supp->is_app_image[idx] = (prefix_len > 0 && strncmp(name, prefix, prefix_len) == 0) ? 1 : 0;
        supp->cpu_type[idx] = readable ? (int32_t)header->cputype : 0;
        supp->cpu_subtype[idx] = readable ? (int32_t)header->cpusubtype : 0;
        supp->vmaddr_slide[idx] = has_text ? (int64_t)((uintptr_t)header - text_vmaddr) : 0;
    }
    list->image_count++;
}

sheepit_image_scan_t sheepit_internal_capture_images(sheepit_binary_image_list_t *list,
                                                     sheepit_crash_supplement_t *supp) {
    sheepit_image_scan_t scan = { ~(uintptr_t)0, false };
    list->image_count = 0;
    uintptr_t max_end = 0;

    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        const struct mach_header *header = _dyld_get_image_header(i);
        if (!name || !header) continue;
        add_image(list, supp, name, header, &max_end, &scan);
    }

    // dyld is not in its own image list, yet every main-thread stack ends in its `start`;
    // without it that frame matched no image and was dropped from every report.
    struct task_dyld_info dyld_info;
    mach_msg_type_number_t info_count = TASK_DYLD_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_DYLD_INFO, (task_info_t)&dyld_info, &info_count) == KERN_SUCCESS &&
        dyld_info.all_image_info_addr != 0) {
        struct dyld_all_image_infos infos;
        if (sheepit_safe_read((uintptr_t)dyld_info.all_image_info_addr, &infos, sizeof(infos)) &&
            infos.dyldImageLoadAddress != NULL) {
            add_image(list, supp, "/usr/lib/dyld", infos.dyldImageLoadAddress, &max_end, &scan);
        }
    }

    if (supp) {
        supp->image_count = list->image_count;
        if (scan.truncated) supp->flags |= SHEEPIT_SUPPLEMENT_IMAGES_TRUNCATED;
    }
    scan.code_mask = sheepit_code_mask_for_end(max_end);
    return scan;
}

uint32_t sheepit_internal_annotation_sources(const sheepit_binary_image_list_t *list,
                                             sheepit_annotation_source_t *out, uint32_t max) {
    uint32_t n = 0;
    uint32_t count = list->image_count < SHEEPIT_MAX_IMAGES ? list->image_count : SHEEPIT_MAX_IMAGES;
    for (uint32_t i = 0; i < count && n < max; i++) {
        if (s_sections[i].crash_info == 0) continue;
        out[n].section_addr = s_sections[i].crash_info;
        out[n].section_size = s_sections[i].crash_info_size;
        out[n].is_swift_runtime = s_sections[i].is_swift_runtime;
        n++;
    }
    return n;
}

// ── Threads ─────────────────────────────────────────────────────────

static bool seed_from_ucontext(void *ucontext, sheepit_register_seed_t *seed) {
    ucontext_t *uc = (ucontext_t *)ucontext;
    if (!uc || !uc->uc_mcontext) return false;
#if defined(__arm64__) || defined(__aarch64__)
    seed->pc = SHEEPIT_SS_PC(uc->uc_mcontext->__ss);
    seed->lr = SHEEPIT_SS_LR(uc->uc_mcontext->__ss);
    seed->fp = strip_data_pointer(SHEEPIT_SS_FP(uc->uc_mcontext->__ss));
    seed->sp = strip_data_pointer(SHEEPIT_SS_SP(uc->uc_mcontext->__ss));
    seed->has_lr = true;
    return true;
#elif defined(__x86_64__)
    seed->pc = (uintptr_t)uc->uc_mcontext->__ss.__rip;
    seed->fp = (uintptr_t)uc->uc_mcontext->__ss.__rbp;
    seed->sp = (uintptr_t)uc->uc_mcontext->__ss.__rsp;
    seed->lr = 0;
    seed->has_lr = false;
    return true;
#else
    return false;
#endif
}

static bool seed_from_thread(thread_t thread, sheepit_register_seed_t *seed) {
#if defined(__arm64__) || defined(__aarch64__)
    arm_thread_state64_t ts;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(thread, ARM_THREAD_STATE64, (thread_state_t)&ts, &count) != KERN_SUCCESS) return false;
    seed->pc = SHEEPIT_SS_PC(ts);
    seed->lr = SHEEPIT_SS_LR(ts);
    seed->fp = strip_data_pointer(SHEEPIT_SS_FP(ts));
    seed->sp = strip_data_pointer(SHEEPIT_SS_SP(ts));
    seed->has_lr = true;
    return true;
#elif defined(__x86_64__)
    x86_thread_state64_t ts;
    mach_msg_type_number_t count = x86_THREAD_STATE64_COUNT;
    if (thread_get_state(thread, x86_THREAD_STATE64, (thread_state_t)&ts, &count) != KERN_SUCCESS) return false;
    seed->pc = (uintptr_t)ts.__rip;
    seed->fp = (uintptr_t)ts.__rbp;
    seed->sp = (uintptr_t)ts.__rsp;
    seed->lr = 0;
    seed->has_lr = false;
    return true;
#else
    (void)thread;
    (void)seed;
    return false;
#endif
}

/// Registers, trap immediate and drop count for the crashed thread.
static void record_trap_site(sheepit_crash_supplement_t *supp, const sheepit_register_seed_t *seed,
                             uintptr_t code_mask, uint32_t dropped) {
    supp->pc = sheepit_strip_pac(seed->pc, code_mask);
    supp->lr = sheepit_strip_pac(seed->lr, code_mask);  // the register, live or not; 0 on x86_64
    supp->fp = seed->fp;
    supp->sp = seed->sp;
    supp->frames_dropped = dropped;
    supp->flags |= SHEEPIT_SUPPLEMENT_HAS_REGISTERS;
#if defined(__arm64__) || defined(__aarch64__)
    uint32_t instruction = 0;
    uint32_t immediate = 0;
    if (sheepit_safe_read((uintptr_t)supp->pc, &instruction, sizeof(instruction)) &&
        sheepit_decode_brk_immediate(instruction, &immediate)) {
        supp->brk_immediate = immediate;
        supp->flags |= SHEEPIT_SUPPLEMENT_HAS_BRK;
    }
#endif
}

void sheepit_internal_capture_threads(sheepit_thread_capture_t *capture,
                                      const sheepit_binary_image_list_t *images,
                                      sheepit_image_scan_t scan,
                                      void *ucontext,
                                      sheepit_crash_supplement_t *supp) {
    capture->thread_count = 0;

    // The thread running the handler is the one that faulted (synchronous signals are delivered
    // to the faulting thread; abort() raises on its caller). Unlike mach_thread_self(), this
    // takes no new port right, so nothing leaks.
    thread_t crashed = pthread_mach_thread_np(pthread_self());

    thread_act_array_t threads;
    mach_msg_type_number_t thread_count;
    if (task_threads(mach_task_self(), &threads, &thread_count) != KERN_SUCCESS) return;

    uint32_t max = thread_count < SHEEPIT_MAX_THREADS ? thread_count : SHEEPIT_MAX_THREADS;
    for (uint32_t i = 0; i < max; i++) {
        sheepit_thread_state_t *state = &capture->threads[capture->thread_count];
        memset(state, 0, sizeof(sheepit_thread_state_t));
        bool is_crashed = threads[i] == crashed;
        state->thread_id = (uint64_t)threads[i];
        state->is_crashed_thread = is_crashed;

        thread_extended_info_data_t ext_info;
        mach_msg_type_number_t info_count = THREAD_EXTENDED_INFO_COUNT;
        if (thread_info(threads[i], THREAD_EXTENDED_INFO, (thread_info_t)&ext_info, &info_count) == KERN_SUCCESS) {
            sheepit_internal_strlcpy(state->name, ext_info.pth_name, sizeof(state->name));
        }

        sheepit_register_seed_t seed;
        memset(&seed, 0, sizeof(seed));
        bool from_ucontext = false;
        bool have = false;
        if (is_crashed) {
            from_ucontext = seed_from_ucontext(ucontext, &seed);
            // No ucontext: fall back to the pre-0.10.1 read (the handler's own frames on top).
            have = from_ucontext || seed_from_thread(threads[i], &seed);
        } else {
            thread_suspend(threads[i]);
            have = seed_from_thread(threads[i], &seed);
        }

        if (have) {
            const sheepit_register_seed_t registers = seed;
#if defined(__arm64__) || defined(__aarch64__)
            // Past the prologue of a frame function, LR points inside it: frame 1 would repeat
            // frame 0's function. The frame record holds the real return address instead.
            if (seed.has_lr && !sheepit_internal_lr_is_live_at(sheepit_strip_pac(seed.pc, scan.code_mask), images)) {
                seed.has_lr = false;
            }
#endif
            uint32_t dropped = 0;
            state->frame_count = sheepit_walk_stack(&seed, images, scan.code_mask, scan.truncated,
                                                    state->frames, SHEEPIT_MAX_FRAMES, &dropped);
            if (is_crashed && from_ucontext && supp) record_trap_site(supp, &registers, scan.code_mask, dropped);
        }
        if (!is_crashed) thread_resume(threads[i]);

        capture->thread_count++;
    }

    for (mach_msg_type_number_t i = 0; i < thread_count; i++) {
        mach_port_deallocate(mach_task_self(), threads[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)threads, thread_count * sizeof(thread_act_t));
}

#endif // __APPLE__
