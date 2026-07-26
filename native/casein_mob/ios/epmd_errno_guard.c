#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <time.h>

#include "epmd_int.h"

/*
 * OTP's EPMD accept/select error paths log with dbg_perror() before
 * switching on errno. On iOS the logging call may change errno, turning the
 * expected non-fatal accept errors into epmd_cleanup_exit(). EPMD is embedded
 * in the app process, so that exit path also runs OpenSSL cleanup while BEAM
 * scheduler threads may still call RAND_bytes_ex().
 *
 * epmd_srv.c alone is compiled with
 * -Ddbg_perror=casein_mob_epmd_dbg_perror. This wrapper formats its variadic
 * arguments, preserves the syscall errno across OTP's real logger, and skips
 * logging for the exact non-fatal accept errors that epmd_srv.c immediately
 * handles. iOS can report those errors continuously after resuming a suspended
 * listener, so apply a small retry backoff as well; otherwise suppressing the
 * log avoids disk churn but leaves EPMD spinning at 100% CPU.
 */
void casein_mob_epmd_dbg_perror(EpmdVars *g, const char *format, ...) {
    int saved_errno = errno;
    char message[1024];
    va_list args;

    if (saved_errno == EAGAIN || saved_errno == EWOULDBLOCK ||
        saved_errno == EINTR || saved_errno == ECONNABORTED) {
        struct timespec delay = {.tv_sec = 0, .tv_nsec = 10 * 1000 * 1000};
        struct timespec remaining;

        while (nanosleep(&delay, &remaining) < 0 && errno == EINTR) {
            delay = remaining;
        }

        errno = saved_errno;
        return;
    }

    va_start(args, format);
    vsnprintf(message, sizeof(message), format, args);
    va_end(args);

    errno = saved_errno;
    dbg_perror(g, "%s", message);
    errno = saved_errno;
}
