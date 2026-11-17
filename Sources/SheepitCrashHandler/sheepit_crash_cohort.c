// Full crash occurrence identity and receipt: one bounded atomic cohort, see SheepitCrashSupplement.h.
#include "SheepitCrashSupplement.h"
#include <stdatomic.h>
#include <stddef.h>
#include <string.h>

_Static_assert(ATOMIC_CHAR_LOCK_FREE == 2 && ATOMIC_INT_LOCK_FREE == 2,
               "Crash cohort atomics must be lock-free in signal context");
static atomic_uint s_generation = 0;
static atomic_uchar s_bytes[sizeof(sheepit_crash_cohort_t)];

// Strict UTF-8, bounded to the API's 256 UTF-16 units; no repair or truncation.
static bool identity_valid(const char *text, bool optional) {
    if (!text) return optional;
    size_t length = strnlen(text, SHEEPIT_CRASH_IDENTITY_BYTES);
    if (length >= SHEEPIT_CRASH_IDENTITY_BYTES || (!optional && length == 0)) return false;
    unsigned units = 0;
    for (size_t i = 0; i < length;) {
        unsigned char first = (unsigned char)text[i++];
        unsigned code;
        unsigned trailing;
        if (first < 0x80) { code = first; trailing = 0; }
        else if (first >= 0xc2 && first <= 0xdf) { code = first & 0x1f; trailing = 1; }
        else if (first >= 0xe0 && first <= 0xef) { code = first & 0x0f; trailing = 2; }
        else if (first >= 0xf0 && first <= 0xf4) { code = first & 7; trailing = 3; }
        else return false;
        if (i + trailing > length) return false;
        for (unsigned j = 0; j < trailing; j++) {
            unsigned char next = (unsigned char)text[i++];
            if ((next & 0xc0) != 0x80) return false;
            code = (code << 6) | (next & 0x3f);
        }
        if ((trailing == 1 && code < 0x80) || (trailing == 2 && code < 0x800) ||
            (trailing == 3 && code < 0x10000) || code > 0x10ffff ||
            (code >= 0xd800 && code <= 0xdfff)) return false;
        units += code > 0xffff ? 2 : 1;
        if (units > 256) return false;
    }
    return true;
}

bool sheepit_crash_cohort_set(const char *user, const char *device, const char *session,
                              const char *token, bool identity_changed) {
    sheepit_crash_cohort_t next = {0};
    size_t token_length = token ? strnlen(token, SHEEPIT_ASSIGNMENT_TOKEN_BYTES) : 0;
    bool valid = identity_valid(user, true) && identity_valid(device, false) &&
                 identity_valid(session, true) && token_length < SHEEPIT_ASSIGNMENT_TOKEN_BYTES;
    if (valid) {
        next.valid = 1;
        next.has_user = user != NULL;
        next.has_session = session != NULL;
        if (user) memcpy(next.user_id, user, strlen(user));
        memcpy(next.device_id, device, strlen(device));
        if (session) memcpy(next.session_id, session, strlen(session));
        if (token) memcpy(next.assignment.token, token, token_length);
        next.assignment.identity_changed = identity_changed ? 1 : 0;
    }
    unsigned generation = atomic_load(&s_generation);
    for (;;) {
        if (!(generation & 1u) && atomic_compare_exchange_weak(
                &s_generation, &generation, generation + 1)) break;
        generation = atomic_load(&s_generation);
    }
    next.generation = generation + 2;
    const unsigned char *bytes = (const unsigned char *)&next;
    for (size_t i = 0; i < sizeof(next); i++) atomic_store(&s_bytes[i], bytes[i]);
    atomic_store(&s_generation, generation + 2);
    return valid;
}

void sheepit_crash_cohort_snapshot(sheepit_crash_cohort_t *out) {
    if (!out) return;
    out->valid = 0;
    unsigned before = atomic_load(&s_generation);
    if (before & 1u) return;
    unsigned char *bytes = (unsigned char *)out;
    for (size_t i = 0; i < sizeof(*out); i++) bytes[i] = atomic_load(&s_bytes[i]);
    unsigned after = atomic_load(&s_generation);
    if (before != after || out->generation != before) out->valid = 0;
}
