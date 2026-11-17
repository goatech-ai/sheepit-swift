// Exercise the production atomics, including a writer interrupted at its odd generation.
#include <stdio.h>
#include <signal.h>
#include <unistd.h>
#include "../../Sources/SheepitCrashHandler/sheepit_crash_cohort.c"

#define CHECK(condition) do { if (!(condition)) { \
    fprintf(stderr, "Native cohort check failed at line %d.\n", __LINE__); return 1; } } while (0)
static void timeout_handler(int signal_number) { (void)signal_number; _exit(1); }

int main(void) {
    signal(SIGALRM, timeout_handler);
    sheepit_crash_cohort_t captured = {0};
    CHECK(sheepit_crash_cohort_set("user-A", "device-A", "session-A", "receipt-A", false));
    sheepit_crash_cohort_snapshot(&captured);
    CHECK(captured.valid == 1 && !strcmp(captured.user_id, "user-A"));
    CHECK(!strcmp(captured.assignment.token, "receipt-A"));
    unsigned even = atomic_load(&s_generation);
    atomic_store(&s_generation, even + 1);
    alarm(2);
    sheepit_crash_cohort_snapshot(&captured);
    alarm(0);
    CHECK(captured.valid == 0);
    atomic_store(&s_generation, even + 2);
    sheepit_crash_cohort_snapshot(&captured);
    CHECK(captured.valid == 0); // Bytes from another generation cannot become valid.
    CHECK(!sheepit_crash_cohort_set("\xc0\x80", "device", NULL, NULL, false));
    sheepit_crash_cohort_snapshot(&captured);
    CHECK(captured.valid == 0);
    CHECK(sizeof(sheepit_crash_supplement_t) == 9880);
    CHECK(offsetof(sheepit_crash_supplement_t, magic) == 9872);
    CHECK(offsetof(sheepit_crash_supplement_v2_t, assignment) == sizeof(sheepit_crash_supplement_t));
    CHECK(offsetof(sheepit_crash_supplement_v3_t, cohort) == sizeof(sheepit_crash_supplement_t));
    return 0;
}
