#include "../../Sources/InputSafety/InputSafety.c"
#include <inttypes.h>
#include <stdio.h>

/* Deliberately installs no event tap. Faults affect this subprocess only. */
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
    CGEventRef ordinary = strcmp(mode, "healthy") == 0
        ? CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, CGPointZero, kCGMouseButtonLeft) : NULL;
    qsd_arm(input);
    if (strcmp(mode, "callback-stall") == 0) {
        atomic_store(&input->status->callbackStarted, qsd_now());
        sleep(2);
    } else if (strcmp(mode, "worker-stall") == 0 || strcmp(mode, "main-stall") == 0) {
        if (strcmp(mode, "main-stall") == 0) qsd_enqueue(input, 0);
        for (int i = 0; i < 400; ++i) {
            if (strcmp(mode, "worker-stall") == 0) atomic_store(&input->status->mainBeat, qsd_now());
            else atomic_store(&input->status->workerBeat, qsd_now());
            qsd_pause_ns(5000000);
        }
    } else if (strcmp(mode, "idle-main-pause") == 0 || strcmp(mode, "main-resumes-with-work") == 0) {
        for (int i = 0; i < 200; ++i) {
            atomic_store(&input->status->workerBeat, qsd_now());
            if (strcmp(mode, "main-resumes-with-work") == 0) {
                if (i == 140) qsd_enqueue(input, 0);
                if (i >= 155) {
                    atomic_store(&input->status->mainBeat, qsd_now());
                    QSDNativeAction action;
                    while (QSDNativeInputReadAction(input, &action)) {}
                }
            }
            qsd_pause_ns(5000000);
        }
    } else if (strcmp(mode, "disarmed") == 0) {
        QSDNativeInputStop(input);
        atomic_store(&input->status->callbackStarted, qsd_now());
        sleep(1);
    } else if (strcmp(mode, "healthy") == 0) {
        for (int i = 0; i < 120; ++i) {
            atomic_store(&input->status->mainBeat, qsd_now());
            atomic_store(&input->status->workerBeat, qsd_now());
            QSDNativeInputRouteForTesting(input, kCGEventLeftMouseDown, ordinary);
            qsd_pause_ns(5000000);
        }
        CFRelease(ordinary);
    } else {
        return 64;
    }
    QSDNativeInputDestroy(input);
    return 0;
}
