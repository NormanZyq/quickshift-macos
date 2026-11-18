#define _DARWIN_C_SOURCE 1
#include <CoreGraphics/CoreGraphics.h>
#include <inttypes.h>
#include <libproc.h>
#include <mach/mach.h>
#include <poll.h>
#include <stdio.h>
#include <sys/resource.h>
#include <unistd.h>

/* Exercise the production worker, run loop and watchdog using a private Mach
   port. No mode in this executable can install an input filter or post input. */
static void discard_message(CFMachPortRef port, void *message, CFIndex size, void *info) {
    (void)port; (void)message; (void)size; (void)info;
}

static CFMachPortRef probe_port(CGEventMask mask) {
    (void)mask;
    return CFMachPortCreate(NULL, discard_message, NULL, NULL);
}

static bool stallCallback;
static bool probeEnabled = true;
static CGEventFlags probe_flags(CGEventRef event) {
    if (stallCallback) sleep(2);
    return CGEventGetFlags(event);
}

#define CGEventTapCreate(place, order, options, mask, callback, info) probe_port(mask)
#define CGEventTapCreateForPid(pid, order, options, mask, callback, info) probe_port(mask)
#define CGEventTapEnable(tap, enable) ((void)(tap))
#define CGEventTapIsEnabled(tap) (probeEnabled)
#define CGEventGetFlags(event) probe_flags(event)
#include "../../Sources/InputSafety/InputSafety.c"

static void on_worker(QSDNativeInput *input, void (^work)(void)) {
    CFRunLoopPerformBlock(input->workerLoop, kCFRunLoopDefaultMode, work);
    CFRunLoopWakeUp(input->workerLoop);
}

static double cpu_seconds(void) {
    struct rusage usage;
    getrusage(RUSAGE_SELF, &usage);
    return usage.ru_utime.tv_sec + usage.ru_stime.tv_sec
        + (usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6;
}

static void measure_idle(void) {
    /* Keep the same main run loop available to both versions during sampling. */
    CFRunLoopSourceContext context = {0};
    CFRunLoopSourceRef source = CFRunLoopSourceCreate(NULL, 0, &context);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 2, false);
    struct proc_taskinfo before, after;
    if (proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &before, sizeof(before)) != sizeof(before)) exit(69);
    double started = cpu_seconds();
    uint64_t startTime = qsd_now();
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 30, false);
    double elapsed = (qsd_now() - startTime) / 1e9;
    double cpu = cpu_seconds() - started;
    if (proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &after, sizeof(after)) != sizeof(after)) exit(69);
    printf("{\"seconds\":%.3f,\"cpuPercent\":%.4f,\"threads\":%d,\"contextSwitchesPerSecond\":%.2f}\n",
           elapsed, 100 * cpu / elapsed, after.pti_threadnum, (after.pti_csw - before.pti_csw) / elapsed);
    CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode);
    CFRelease(source);
}

int main(int argc, char **argv) {
    if (argc != 3) return 64;
    const char *mode = argv[1], *path = argv[2];
    if (strcmp(mode, "status") == 0) {
        QSDNativeStatus status;
        if (!QSDNativeInputReadStatus(path, &status)) return 65;
        printf("{\"fault\":%u,\"phase\":%u,\"events\":%" PRIu64 ",\"maximumCallbackNanoseconds\":%" PRIu64 "}\n",
               status.fault, status.phase, status.events, status.maximumCallbackNanoseconds);
        return 0;
    }
    QSDNativeInput *input = QSDNativeInputCreate(path, 0);
    if (!input) return 66;
    QSDNativeInputConfigure(input, (QSDNativeConfiguration){
        .left = {.code = 0, .modifiers = 13}, .right = {.code = 1, .modifiers = 13}, .foregroundPID = getpid(), .enabled = true
    });
    bool routeEvents = strcmp(mode, "callback-stall") == 0 || strcmp(mode, "healthy") == 0;
    CGEventRef ordinary = routeEvents
        ? CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, CGPointZero, kCGMouseButtonLeft) : NULL;
    if (routeEvents && !ordinary) return 67;
    stallCallback = strcmp(mode, "callback-stall") == 0;
    if (!QSDNativeInputStart(input)) return 68;

    if (routeEvents) {
        on_worker(input, ^{
            for (int i = 0; i < 120; ++i) QSDNativeInputRouteForTesting(input, kCGEventLeftMouseDown, ordinary);
        });
        usleep(stallCallback ? 2000000 : 600000);
        if (atomic_load(&input->status->events) != 120) return 69;
    } else if (strcmp(mode, "tap-disabled") == 0 || strcmp(mode, "stale-disable") == 0) {
        bool disabled = strcmp(mode, "tap-disabled") == 0;
        on_worker(input, ^{
            probeEnabled = !disabled;
            QSDNativeInputRouteForTesting(input, kCGEventTapDisabledByUserInput, NULL);
        });
        struct pollfd signal = {.fd = QSDNativeInputSignalFD(input), .events = POLLIN};
        int ready = poll(&signal, 1, 500);
        if (ready != (disabled ? 1 : 0) || QSDNativeInputIsRunning(input) == disabled) return 69;
    } else if (strcmp(mode, "worker-stall") == 0) {
        on_worker(input, ^{ sleep(2); });
        sleep(2);
    } else if (strcmp(mode, "parked-worker-stall") == 0) {
        /* An unresponsive thread can strand a new event before any callback
           starts. Suspending just this fixture's worker exercises that case. */
        while (!CFRunLoopIsWaiting(input->workerLoop)) usleep(1000);
        if (thread_suspend(pthread_mach_thread_np(input->worker)) != KERN_SUCCESS) return 69;
        sleep(2);
    } else if (strcmp(mode, "main-stall") == 0) {
        on_worker(input, ^{ qsd_enqueue(input, 0); });
        sleep(2);
    } else if (strcmp(mode, "busy-main-stall") == 0) {
        on_worker(input, ^{ qsd_enqueue(input, 0); });
        for (int i = 0; i < 2000; ++i) {
            /* A stream of healthy worker turns must not postpone an older action. */
            on_worker(input, ^{});
            usleep(1000);
        }
    } else if (strcmp(mode, "pending-tail-advances") == 0) {
        on_worker(input, ^{ qsd_enqueue(input, 0); });
        usleep(320000);
        on_worker(input, ^{ qsd_enqueue(input, 1); });
        usleep(50000);
        QSDNativeAction action;
        if (!QSDNativeInputReadAction(input, &action) || action.direction != 0) return 69;
        usleep(220000);
        if (!QSDNativeInputReadAction(input, &action) || action.direction != 1) return 69;
        usleep(320000);
    } else if (strcmp(mode, "idle-main-pause") == 0) {
        sleep(1);
    } else if (strcmp(mode, "main-resumes-with-work") == 0) {
        usleep(700000);
        on_worker(input, ^{ qsd_enqueue(input, 0); });
        usleep(100000);
        QSDNativeAction action;
        if (!QSDNativeInputReadAction(input, &action)) return 69;
        usleep(500000);
    } else if (strcmp(mode, "disarmed") == 0) {
        QSDNativeInputStop(input);
        sleep(1);
    } else if (strcmp(mode, "restart") == 0) {
        for (int i = 0; i < 20; ++i) {
            QSDNativeInputStop(input);
            if (!QSDNativeInputStart(input)) return 68;
        }
        usleep(550000);
    } else if (strcmp(mode, "idle-cost") == 0) {
        measure_idle();
    } else {
        return 64;
    }
    QSDNativeInputDestroy(input);
    if (ordinary) CFRelease(ordinary);
    return 0;
}
