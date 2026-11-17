// Sheepit SDK — the crash supplement (sidecar) file: mapping it for the session and reading a
// previous session's. Format and rationale: include/SheepitCrashSupplement.h.

#include "SheepitCrashSupplement.h"
#include "SheepitCrashCapture.h"
#include "sheepit_crash_internal.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <stddef.h>

#if defined(__APPLE__)
#include <sys/sysctl.h>
#include <mach-o/dyld.h>
#endif

static sheepit_crash_supplement_t *s_supplement = NULL;
static int s_supplement_fd = -1;
void sheepit_internal_capture_cohort(void) {
    if (s_supplement)
        sheepit_crash_cohort_snapshot(&((sheepit_crash_supplement_v3_t *)s_supplement)->cohort);
}

static char s_app_prefix[1024] = {0};

sheepit_crash_supplement_t *sheepit_internal_supplement(void) {
    return s_supplement;
}

const char *sheepit_internal_app_prefix(void) {
    return s_app_prefix;
}

static const char *build_arch(void) {
#if defined(__arm64e__)
    return "arm64e";
#elif defined(__arm64__) || defined(__aarch64__)
    return "arm64";
#elif defined(__x86_64__)
    return "x86_64";
#else
    return "unknown";
#endif
}

int sheepit_crash_supplement_install(const char *supplement_file_path, const char *sdk_version) {
    if (s_supplement || !supplement_file_path) return -1;

    int fd = open(supplement_file_path, O_RDWR | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) return -1;
    if (ftruncate(fd, (off_t)sizeof(sheepit_crash_supplement_v3_t)) != 0) {
        close(fd);
        return -1;
    }
    void *map = mmap(NULL, sizeof(sheepit_crash_supplement_v3_t), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) {
        close(fd);
        return -1;
    }

    sheepit_crash_supplement_t *supp = (sheepit_crash_supplement_t *)map;
    memset(map, 0, sizeof(sheepit_crash_supplement_v3_t));
    sheepit_crash_cohort_set(NULL, NULL, NULL, NULL, false);
    supp->format_version = SHEEPIT_SUPPLEMENT_COHORT_VERSION;
    sheepit_internal_strlcpy(supp->arch, build_arch(), sizeof(supp->arch));
    sheepit_internal_strlcpy(supp->sdk_version, sdk_version ? sdk_version : "", sizeof(supp->sdk_version));

#if defined(__APPLE__)
    // Here, not in the handler: sysctl is not async-signal-safe.
    char build[sizeof(supp->os_build)];
    size_t len = sizeof(build);
    if (sysctlbyname("kern.osversion", build, &len, NULL, 0) == 0 && len > 0 && len <= sizeof(build)) {
        build[len - 1] = '\0';
        sheepit_internal_strlcpy(supp->os_build, build, sizeof(supp->os_build));
    }
    // dyld lists the main executable first.
    sheepit_app_bundle_prefix(_dyld_get_image_name(0), s_app_prefix, sizeof(s_app_prefix));
#endif

    s_supplement_fd = fd;
    s_supplement = supp;
    return 0;
}

void sheepit_internal_supplement_sync(void) {
    if (s_supplement) msync(s_supplement, sizeof(sheepit_crash_supplement_v3_t), MS_SYNC);
}

void sheepit_internal_supplement_uninstall(void) {
    sheepit_crash_cohort_set(NULL, NULL, NULL, NULL, false);
    if (s_supplement) {
        munmap(s_supplement, sizeof(sheepit_crash_supplement_v3_t));
        s_supplement = NULL;
    }
    if (s_supplement_fd >= 0) {
        close(s_supplement_fd);
        s_supplement_fd = -1;
    }
}

sheepit_crash_supplement_t *sheepit_read_crash_supplement(const char *supplement_file_path,
                                                          uint64_t report_timestamp_ms) {
    if (!supplement_file_path) return NULL;
    int fd = open(supplement_file_path, O_RDONLY);
    if (fd < 0) return NULL;

    struct stat st;
    if (fstat(fd, &st) != 0 || (size_t)st.st_size < sizeof(sheepit_crash_supplement_t)) {
        close(fd);
        return NULL;
    }
    sheepit_crash_supplement_t *supp = (sheepit_crash_supplement_t *)malloc(sizeof(sheepit_crash_supplement_t));
    if (!supp) {
        close(fd);
        return NULL;
    }
    size_t total = 0;
    while (total < sizeof(*supp)) {
        ssize_t n = read(fd, (char *)supp + total, sizeof(*supp) - total);
        if (n <= 0) break;
        total += (size_t)n;
    }
    close(fd);

    if (total < sizeof(*supp) ||
        supp->magic != SHEEPIT_SUPPLEMENT_MAGIC ||
        (supp->format_version != SHEEPIT_SUPPLEMENT_FORMAT_VERSION &&
         supp->format_version != SHEEPIT_SUPPLEMENT_ASSIGNMENT_VERSION &&
         supp->format_version != SHEEPIT_SUPPLEMENT_COHORT_VERSION) ||
        (supp->format_version == SHEEPIT_SUPPLEMENT_ASSIGNMENT_VERSION &&
         (size_t)st.st_size != sizeof(sheepit_crash_supplement_v2_t)) ||
        (supp->format_version == SHEEPIT_SUPPLEMENT_COHORT_VERSION &&
         (size_t)st.st_size != sizeof(sheepit_crash_supplement_v3_t)) ||
        supp->report_timestamp_ms != report_timestamp_ms ||
        supp->image_count > SHEEPIT_MAX_IMAGES) {
        free(supp);
        return NULL;
    }
    // A file from disk is untrusted: terminate every string before Swift reads it.
    supp->exception_message[sizeof(supp->exception_message) - 1] = '\0';
    supp->os_build[sizeof(supp->os_build) - 1] = '\0';
    supp->arch[sizeof(supp->arch) - 1] = '\0';
    supp->sdk_version[sizeof(supp->sdk_version) - 1] = '\0';
    return supp;
}

static bool read_extension(const char *path, uint64_t timestamp_ms, uint32_t version,
                            void *out, size_t length, off_t offset) {
    if (!path || !out) return false;
    int fd = open(path, O_RDONLY);
    if (fd < 0) return false;
    struct stat st;
    sheepit_crash_supplement_t header;
    size_t expected = version == SHEEPIT_SUPPLEMENT_ASSIGNMENT_VERSION
        ? sizeof(sheepit_crash_supplement_v2_t) : sizeof(sheepit_crash_supplement_v3_t);
    bool valid = fstat(fd, &st) == 0 && st.st_size == (off_t)expected &&
                 pread(fd, &header, sizeof(header), 0) == sizeof(header) &&
                 header.magic == SHEEPIT_SUPPLEMENT_MAGIC && header.format_version == version &&
                 header.report_timestamp_ms == timestamp_ms && header.image_count <= SHEEPIT_MAX_IMAGES;
    ssize_t bytes = valid ? pread(fd, out, length, offset) : -1;
    close(fd);
    return valid && bytes == (ssize_t)length;
}

sheepit_crash_cohort_outcome_t sheepit_read_crash_cohort(
    const char *path, uint64_t timestamp_ms, uint32_t image_count, sheepit_crash_cohort_t *out) {
    if (!out) return SHEEPIT_COHORT_UNAVAILABLE;
    memset(out, 0, sizeof(*out));
    if (!path) return SHEEPIT_COHORT_LEGACY;
    int fd = open(path, O_RDONLY);
    if (fd < 0) return errno == ENOENT ? SHEEPIT_COHORT_LEGACY : SHEEPIT_COHORT_UNAVAILABLE;
    struct stat st;
    sheepit_crash_supplement_t header;
    bool read = fstat(fd, &st) == 0 &&
        pread(fd, &header, sizeof(header), 0) == sizeof(header) &&
        header.magic == SHEEPIT_SUPPLEMENT_MAGIC && header.report_timestamp_ms == timestamp_ms &&
        header.image_count == image_count && image_count <= SHEEPIT_MAX_IMAGES;
    if (!read) {
        close(fd);
        return SHEEPIT_COHORT_UNAVAILABLE;
    }
    if (header.format_version == SHEEPIT_SUPPLEMENT_FORMAT_VERSION ||
        header.format_version == SHEEPIT_SUPPLEMENT_ASSIGNMENT_VERSION) {
        read = st.st_size == (off_t)(header.format_version == SHEEPIT_SUPPLEMENT_FORMAT_VERSION
            ? sizeof(sheepit_crash_supplement_t) : sizeof(sheepit_crash_supplement_v2_t));
        close(fd);
        return read ? SHEEPIT_COHORT_LEGACY : SHEEPIT_COHORT_UNAVAILABLE;
    }
    read = header.format_version == SHEEPIT_SUPPLEMENT_COHORT_VERSION &&
        st.st_size == sizeof(sheepit_crash_supplement_v3_t) &&
        pread(fd, out, sizeof(*out), offsetof(sheepit_crash_supplement_v3_t, cohort)) == sizeof(*out);
    close(fd);
    if (!read || out->valid != 1 || (out->generation & 1u) || out->has_user > 1 ||
        out->has_session > 1 || out->reserved != 0 || out->assignment.identity_changed > 1) {
        memset(out, 0, sizeof(*out));
        return SHEEPIT_COHORT_UNAVAILABLE;
    }
    return SHEEPIT_COHORT_COHERENT;
}

bool sheepit_read_crash_assignment(const char *path, uint64_t timestamp_ms,
                                   sheepit_assignment_receipt_t *out) {
    if (!out) return false;
    memset(out, 0, sizeof(*out));
    bool read = read_extension(path, timestamp_ms, SHEEPIT_SUPPLEMENT_ASSIGNMENT_VERSION,
                               out, sizeof(*out), offsetof(sheepit_crash_supplement_v2_t, assignment));
    if (!read || out->identity_changed > 1 || out->token[sizeof(out->token) - 1] != 0) {
        memset(out, 0, sizeof(*out));
        return false;
    }
    return true;
}
