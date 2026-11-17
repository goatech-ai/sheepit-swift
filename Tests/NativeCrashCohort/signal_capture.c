// Drive the actual production signal handler in a single-threaded child, then read its saved cohort.
#include "SheepitCrashHandler.h"
#include "SheepitCrashSupplement.h"
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>

static void previous_handler(int signal_number) {
    _exit(signal_number == SIGTRAP ? 0 : 100 + signal_number);
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    char report_path[4096];
    char supplement_path[4096];
    if (snprintf(report_path, sizeof(report_path), "%s/signal.crash", argv[1]) >= (int)sizeof(report_path) ||
        snprintf(supplement_path, sizeof(supplement_path), "%s/signal.supplement", argv[1]) >= (int)sizeof(supplement_path))
        return 2;
    char user[SHEEPIT_CRASH_IDENTITY_BYTES] = {0};
    for (size_t i = 0; i < 256; i++) memcpy(user + i * 3, "\xe7\x95\x8c", 3);
    pid_t child = fork();
    if (child < 0) return 2;
    if (child == 0) {
        struct rlimit cores = {0, 0};
        if (setrlimit(RLIMIT_CORE, &cores) != 0) _exit(10);
        struct sigaction previous;
        memset(&previous, 0, sizeof(previous));
        previous.sa_handler = previous_handler;
        sigemptyset(&previous.sa_mask);
        const int signals[] = {SIGTRAP, SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV};
        for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); i++)
            if (sigaction(signals[i], &previous, NULL) != 0) _exit(11);
        if (sheepit_crash_handler_install(report_path) != 0 ||
            sheepit_crash_supplement_install(supplement_path, "native-test") != 0 ||
            !sheepit_crash_cohort_set(user, "device-signal", "session-signal", "signal-receipt", false)) _exit(12);
        raise(SIGTRAP);
        _exit(13); // The saved prior handler must exit; falling through is a test failure.
    }
    int status = 0;
    if (waitpid(child, &status, 0) != child || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        fprintf(stderr, "Native capture child did not exit through its prior signal handler: %d\n", status);
        return 1;
    }
    sheepit_crash_report_t *report = sheepit_read_pending_crash_report(report_path);
    if (!report) return 1;
    sheepit_crash_cohort_t cohort = {0};
    sheepit_crash_cohort_outcome_t outcome = sheepit_read_crash_cohort(
        supplement_path, report->timestamp_ms, report->images.image_count, &cohort);
    free(report);
    if (outcome != SHEEPIT_COHORT_COHERENT || !cohort.valid || strcmp(cohort.user_id, user) ||
        strcmp(cohort.device_id, "device-signal") || strcmp(cohort.session_id, "session-signal") ||
        strcmp(cohort.assignment.token, "signal-receipt")) {
        fprintf(stderr, "Production signal handler did not persist its complete identity/receipt cohort (outcome=%d).\n", outcome);
        return 1;
    }
    return 0;
}
