#define _DARWIN_C_SOURCE 1
#include "InputSafety.h"
#include <CoreFoundation/CoreFoundation.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "Input callback needs lock-free 64-bit atomics");
#define QSD_MAGIC UINT64_C(0x5153444e41544956)
#define QSD_QUEUE_CAPACITY 64
#define QSD_CALLBACK_BUDGET_NS UINT64_C(100000000)
#define QSD_WORKER_BUDGET_NS UINT64_C(250000000)
#define QSD_MAIN_BUDGET_NS UINT64_C(500000000)

typedef struct {
    uint64_t magic;
    _Atomic int32_t pid;
    _Atomic uint32_t phase, fault, lastType;
    _Atomic uint64_t events, suppressed, actions, maximumNS;
    _Atomic uint64_t callbackStarted, workerBeat, mainBeat;
} QSDSharedStatus;

struct QSDNativeInput {
    QSDSharedStatus *status;
    int statusFD, signalFDs[2];
    int32_t targetPID;
    pthread_t worker, guardian;
    pthread_mutex_t control;
    pthread_cond_t readyCondition, guardCondition;
    bool workerCreated, ready;
    _Atomic bool stopping, armed, shutdown;
    _Atomic uint64_t guardGeneration;
    CFRunLoopRef workerLoop;
    CFRunLoopTimerRef mainTimer;
    _Atomic uint32_t configVersion;
    _Atomic uint64_t leftBinding, rightBinding;
    _Atomic int32_t foregroundPID;
    _Atomic bool enabled, recording;
    _Atomic uint32_t head, tail;
    QSDNativeAction queue[QSD_QUEUE_CAPACITY];
    /* Owned exclusively by the input run loop. */
    uint32_t capturedMouse;
    uint64_t capturedKeys[2];
};

static uint64_t qsd_now(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static bool qsd_expired(uint64_t now, uint64_t then, uint64_t budget) {
    return then != 0 && now > then && now - then > budget;
}

static void qsd_pause_ns(long nanoseconds) {
    struct timespec delay = { .tv_sec = 0, .tv_nsec = nanoseconds };
    while (nanosleep(&delay, &delay) != 0 && errno == EINTR) {}
}

static void qsd_fault(QSDNativeInput *input, uint32_t reason) {
    atomic_store(&input->status->fault, reason);
    atomic_store(&input->status->phase, 3);
    /* No dispatch, IPC, logging, allocator, or UI is involved in recovery. */
    if (atomic_load(&input->armed)) _exit((int)(70 + reason));
}

static void *qsd_guardian(void *context) {
    QSDNativeInput *input = context;
    for (;;) {
        pthread_mutex_lock(&input->control);
        while (!atomic_load(&input->armed) && !atomic_load(&input->shutdown)) {
            pthread_cond_wait(&input->guardCondition, &input->control);
        }
        pthread_mutex_unlock(&input->control);
        if (atomic_load(&input->shutdown)) return NULL;
        uint64_t pendingMainSince = 0, observedGeneration = UINT64_MAX;
        while (atomic_load(&input->armed) && !atomic_load(&input->shutdown)) {
            uint64_t generation = atomic_load(&input->guardGeneration);
            if (generation & 1) { qsd_pause_ns(20000000); continue; }
            uint64_t now = qsd_now();
            uint64_t callback = atomic_load(&input->status->callbackStarted);
            uint64_t worker = atomic_load(&input->status->workerBeat);
            uint64_t main = atomic_load(&input->status->mainBeat);
            if (generation == atomic_load(&input->guardGeneration) && atomic_load(&input->armed)) {
                if (qsd_expired(now, callback, QSD_CALLBACK_BUDGET_NS)) qsd_fault(input, 1);
                if (qsd_expired(now, worker, QSD_WORKER_BUDGET_NS)) qsd_fault(input, 2);
                /* AppKit can pause an idle main loop around display sleep/wake. The C
                   callback still passes ordinary input independently. Only an action
                   queue that stays undrained needs main-loop recovery. Measure the
                   wait here so a new action after an idle pause gets a full budget. */
                bool pending = atomic_load(&input->head) != atomic_load(&input->tail);
                if (generation != observedGeneration || !pending) pendingMainSince = 0;
                observedGeneration = generation;
                if (pending && pendingMainSince == 0) pendingMainSince = now;
                if (qsd_expired(now, main, QSD_MAIN_BUDGET_NS)
                    && qsd_expired(now, pendingMainSince, QSD_MAIN_BUDGET_NS)) qsd_fault(input, 3);
            }
            qsd_pause_ns(20000000);
        }
    }
}

static void qsd_main_heartbeat(CFRunLoopTimerRef timer, void *context) {
    (void)timer;
    QSDNativeInput *input = context;
    atomic_store(&input->status->mainBeat, qsd_now());
}

static void qsd_arm(QSDNativeInput *input) {
    atomic_fetch_add(&input->guardGeneration, 1);
    uint64_t now = qsd_now();
    atomic_store(&input->status->callbackStarted, 0);
    atomic_store(&input->status->mainBeat, now);
    atomic_store(&input->status->workerBeat, now);
    pthread_mutex_lock(&input->control);
    atomic_store(&input->armed, true);
    atomic_fetch_add(&input->guardGeneration, 1);
    pthread_cond_signal(&input->guardCondition);
    pthread_mutex_unlock(&input->control);
}

static uint64_t qsd_binding(QSDNativeShortcut value) {
    return (uint64_t)value.code | ((uint64_t)value.kind << 16) | ((uint64_t)value.modifiers << 24);
}

static uint8_t qsd_modifiers(CGEventFlags flags) {
    uint8_t result = 0;
    if (flags & kCGEventFlagMaskControl) result |= 1;
    if (flags & kCGEventFlagMaskAlternate) result |= 2;
    if (flags & kCGEventFlagMaskShift) result |= 4;
    if (flags & kCGEventFlagMaskCommand) result |= 8;
    return result;
}

static bool qsd_matches(uint64_t binding, uint8_t kind, uint16_t code, uint8_t modifiers) {
    uint8_t wanted = (uint8_t)(binding >> 24);
    /* Invalid or unpublished configurations always pass input through. */
    return wanted != 0 && wanted == modifiers && (uint8_t)(binding >> 16) == kind
        && (uint16_t)binding == code;
}

static bool qsd_enqueue(QSDNativeInput *input, int32_t direction) {
    uint32_t head = atomic_load_explicit(&input->head, memory_order_relaxed);
    uint32_t tail = atomic_load_explicit(&input->tail, memory_order_acquire);
    if (head - tail >= QSD_QUEUE_CAPACITY) { qsd_fault(input, 5); return false; }
    input->queue[head % QSD_QUEUE_CAPACITY] = (QSDNativeAction){direction,
        input->targetPID > 0 ? input->targetPID : atomic_load(&input->foregroundPID)};
    atomic_store_explicit(&input->head, head + 1, memory_order_release);
    atomic_fetch_add(&input->status->actions, 1);
    const unsigned char signal = 1;
    (void)write(input->signalFDs[1], &signal, 1); /* O_NONBLOCK, bounded queue */
    return true;
}

static CGEventRef qsd_route(QSDNativeInput *input, CGEventType type, CGEventRef event) {
    if (atomic_load(&input->stopping) || atomic_load(&input->status->fault)) return event;
    if (type == kCGEventTapDisabledByTimeout) { qsd_fault(input, 4); return event; }
    if (type == kCGEventTapDisabledByUserInput) {
        input->capturedMouse = 0;
        input->capturedKeys[0] = input->capturedKeys[1] = 0;
        return event;
    }
    if (!event) return event;
    uint16_t code;
    uint8_t kind;
    bool down = false, up = false, repeated = false;
    uint8_t modifiers = qsd_modifiers(CGEventGetFlags(event));
    switch (type) {
        case kCGEventLeftMouseDown: down = true; code = 0; kind = 0; break;
        case kCGEventLeftMouseUp: up = true; code = 0; kind = 0; break;
        case kCGEventLeftMouseDragged: code = 0; kind = 0; break;
        case kCGEventRightMouseDown: down = true; code = 1; kind = 0; break;
        case kCGEventRightMouseUp: up = true; code = 1; kind = 0; break;
        case kCGEventRightMouseDragged: code = 1; kind = 0; break;
        case kCGEventOtherMouseDown: case kCGEventOtherMouseUp: case kCGEventOtherMouseDragged: {
            int64_t button = CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber);
            if (button < 0 || button > 31) return event;
            code = (uint16_t)button; kind = 0;
            down = type == kCGEventOtherMouseDown; up = type == kCGEventOtherMouseUp;
            break;
        }
        case kCGEventKeyDown: case kCGEventKeyUp: {
            int64_t key = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
            if (key < 0 || key > 127) return event;
            code = (uint16_t)key; kind = 1;
            down = type == kCGEventKeyDown; up = !down;
            repeated = down && CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat) != 0;
            /* System Force Quit is unconditionally reserved. */
            if (code == 53 && (modifiers & 10) == 10) {
                input->capturedKeys[0] &= ~(UINT64_C(1) << 53);
                return event;
            }
            break;
        }
        default: return event;
    }
    uint64_t bit = UINT64_C(1) << (code % 64);
    bool captured = kind ? ((input->capturedKeys[code / 64] & bit) != 0)
                         : ((input->capturedMouse & (uint32_t)bit) != 0);
    if (captured) {
        if (up) {
            if (kind) input->capturedKeys[code / 64] &= ~bit;
            else input->capturedMouse &= ~(uint32_t)bit;
        }
        return NULL;
    }
    if (!down || repeated) return event;
    uint32_t version = atomic_load_explicit(&input->configVersion, memory_order_acquire);
    if (version & 1) return event;
    bool enabled = atomic_load(&input->enabled), recording = atomic_load(&input->recording);
    uint64_t left = atomic_load(&input->leftBinding), right = atomic_load(&input->rightBinding);
    if (version != atomic_load_explicit(&input->configVersion, memory_order_acquire)
        || !enabled || recording) return event;
    int32_t direction = qsd_matches(left, kind, code, modifiers) ? 0
        : (qsd_matches(right, kind, code, modifiers) ? 1 : -1);
    if (direction < 0 || !qsd_enqueue(input, direction)) return event;
    if (kind) input->capturedKeys[code / 64] |= bit;
    else input->capturedMouse |= (uint32_t)bit;
    return NULL;
}

static CGEventRef qsd_callback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *context) {
    (void)proxy;
    QSDNativeInput *input = context;
    uint64_t started = qsd_now();
    atomic_store(&input->status->callbackStarted, started);
    atomic_store(&input->status->lastType, type);
    atomic_fetch_add(&input->status->events, 1);
    CGEventRef result = qsd_route(input, type, event);
    if (!result) atomic_fetch_add(&input->status->suppressed, 1);
    uint64_t elapsed = qsd_now() - started;
    if (elapsed > atomic_load(&input->status->maximumNS)) atomic_store(&input->status->maximumNS, elapsed);
    atomic_store(&input->status->callbackStarted, 0);
    return result;
}

static void *qsd_worker(void *context) {
    QSDNativeInput *input = context;
    CGEventMask mask = CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventLeftMouseUp)
        | CGEventMaskBit(kCGEventLeftMouseDragged) | CGEventMaskBit(kCGEventRightMouseDown)
        | CGEventMaskBit(kCGEventRightMouseUp) | CGEventMaskBit(kCGEventRightMouseDragged)
        | CGEventMaskBit(kCGEventOtherMouseDown) | CGEventMaskBit(kCGEventOtherMouseUp)
        | CGEventMaskBit(kCGEventOtherMouseDragged) | CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp);
    atomic_store(&input->status->workerBeat, qsd_now());
    CFMachPortRef tap = input->targetPID > 0
        ? CGEventTapCreateForPid(input->targetPID, kCGHeadInsertEventTap, kCGEventTapOptionDefault, mask, qsd_callback, input)
        : CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, mask, qsd_callback, input);
    CFRunLoopSourceRef source = tap ? CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) : NULL;
    CFRunLoopRef loop = CFRunLoopGetCurrent();
    if (source) CFRunLoopAddSource(loop, source, kCFRunLoopDefaultMode);
    pthread_mutex_lock(&input->control);
    CFRetain(loop);
    input->workerLoop = loop;
    atomic_store(&input->status->phase, source ? 1 : 2);
    input->ready = true;
    pthread_cond_signal(&input->readyCondition);
    pthread_mutex_unlock(&input->control);
    while (source && !atomic_load(&input->stopping)) {
        atomic_store(&input->status->workerBeat, qsd_now());
        if (CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false) == kCFRunLoopRunFinished) break;
    }
    if (tap) { CGEventTapEnable(tap, false); CFMachPortInvalidate(tap); }
    if (source) { CFRunLoopRemoveSource(loop, source, kCFRunLoopDefaultMode); CFRelease(source); }
    if (tap) CFRelease(tap);
    pthread_mutex_lock(&input->control);
    CFRelease(input->workerLoop);
    input->workerLoop = NULL;
    pthread_mutex_unlock(&input->control);
    atomic_store(&input->armed, false);
    atomic_fetch_add(&input->guardGeneration, 2);
    if (atomic_load(&input->status->phase) == 1) atomic_store(&input->status->phase, 0);
    return NULL;
}

QSDNativeInput *QSDNativeInputCreate(const char *path, int32_t targetPID) {
    QSDNativeInput *input = calloc(1, sizeof(*input));
    if (!input) return NULL;
    input->statusFD = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (input->statusFD < 0) { free(input); return NULL; }
    if (ftruncate(input->statusFD, sizeof(QSDSharedStatus)) != 0) { close(input->statusFD); free(input); return NULL; }
    input->status = mmap(NULL, sizeof(QSDSharedStatus), PROT_READ | PROT_WRITE, MAP_SHARED, input->statusFD, 0);
    if (input->status == MAP_FAILED) { close(input->statusFD); free(input); return NULL; }
    memset(input->status, 0, sizeof(QSDSharedStatus));
    input->status->magic = QSD_MAGIC;
    atomic_store(&input->status->pid, getpid());
    input->targetPID = targetPID;
    if (pipe(input->signalFDs) != 0) { munmap(input->status, sizeof(QSDSharedStatus)); close(input->statusFD); free(input); return NULL; }
    for (int i = 0; i < 2; ++i) {
        fcntl(input->signalFDs[i], F_SETFL, fcntl(input->signalFDs[i], F_GETFL) | O_NONBLOCK);
        fcntl(input->signalFDs[i], F_SETFD, FD_CLOEXEC);
    }
    fcntl(input->signalFDs[1], F_SETNOSIGPIPE, 1);
    pthread_mutex_init(&input->control, NULL);
    pthread_cond_init(&input->readyCondition, NULL);
    pthread_cond_init(&input->guardCondition, NULL);
    if (pthread_create(&input->guardian, NULL, qsd_guardian, input) != 0) {
        close(input->signalFDs[0]); close(input->signalFDs[1]);
        munmap(input->status, sizeof(QSDSharedStatus)); close(input->statusFD); free(input); return NULL;
    }
    return input;
}

void QSDNativeInputConfigure(QSDNativeInput *input, QSDNativeConfiguration value) {
    atomic_fetch_add(&input->configVersion, 1);
    atomic_store(&input->leftBinding, qsd_binding(value.left));
    atomic_store(&input->rightBinding, qsd_binding(value.right));
    atomic_store(&input->foregroundPID, value.foregroundPID);
    atomic_store(&input->enabled, value.enabled);
    atomic_store(&input->recording, value.recording);
    atomic_fetch_add(&input->configVersion, 1);
}

bool QSDNativeInputStart(QSDNativeInput *input) {
    if (input->workerCreated || input->targetPID < 0 || atomic_load(&input->status->fault)) return false;
    atomic_store(&input->stopping, false);
    input->ready = false;
    CFRunLoopTimerContext timerContext = {0, input, NULL, NULL, NULL};
    input->mainTimer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 0.05, 0.05, 0, 0, qsd_main_heartbeat, &timerContext);
    if (!input->mainTimer) return false;
    CFRunLoopAddTimer(CFRunLoopGetMain(), input->mainTimer, kCFRunLoopCommonModes);
    qsd_arm(input);
    if (pthread_create(&input->worker, NULL, qsd_worker, input) != 0) {
        atomic_store(&input->armed, false);
        CFRunLoopTimerInvalidate(input->mainTimer); CFRelease(input->mainTimer); input->mainTimer = NULL;
        return false;
    }
    input->workerCreated = true;
    pthread_mutex_lock(&input->control);
    while (!input->ready) pthread_cond_wait(&input->readyCondition, &input->control);
    pthread_mutex_unlock(&input->control);
    return atomic_load(&input->status->phase) == 1;
}

void QSDNativeInputStop(QSDNativeInput *input) {
    if (!input) return;
    atomic_store(&input->stopping, true);
    pthread_mutex_lock(&input->control);
    CFRunLoopRef loop = input->workerLoop;
    if (loop) CFRetain(loop);
    pthread_mutex_unlock(&input->control);
    if (loop) { CFRunLoopWakeUp(loop); CFRelease(loop); }
    if (input->workerCreated) { pthread_join(input->worker, NULL); input->workerCreated = false; }
    atomic_store(&input->armed, false);
    atomic_fetch_add(&input->guardGeneration, 2);
    if (input->mainTimer) { CFRunLoopTimerInvalidate(input->mainTimer); CFRelease(input->mainTimer); input->mainTimer = NULL; }
    atomic_store(&input->tail, atomic_load(&input->head));
    QSDNativeInputDrainSignal(input);
    if (!atomic_load(&input->status->fault)) atomic_store(&input->status->phase, 0);
}

void QSDNativeInputDestroy(QSDNativeInput *input) {
    if (!input) return;
    QSDNativeInputStop(input);
    pthread_mutex_lock(&input->control);
    atomic_store(&input->shutdown, true);
    pthread_cond_signal(&input->guardCondition);
    pthread_mutex_unlock(&input->control);
    pthread_join(input->guardian, NULL);
    close(input->signalFDs[0]); close(input->signalFDs[1]);
    munmap(input->status, sizeof(QSDSharedStatus)); close(input->statusFD);
    pthread_cond_destroy(&input->readyCondition); pthread_cond_destroy(&input->guardCondition);
    pthread_mutex_destroy(&input->control);
    free(input);
}

void QSDNativeInputResetFault(QSDNativeInput *input) {
    if (input->workerCreated) return;
    atomic_store(&input->status->fault, 0);
    atomic_store(&input->status->phase, 0);
    atomic_store(&input->stopping, false);
    input->capturedMouse = 0; input->capturedKeys[0] = input->capturedKeys[1] = 0;
}

bool QSDNativeInputIsRunning(QSDNativeInput *input) { return atomic_load(&input->status->phase) == 1 && !atomic_load(&input->stopping); }
uint32_t QSDNativeInputFault(QSDNativeInput *input) { return atomic_load(&input->status->fault); }
int QSDNativeInputSignalFD(QSDNativeInput *input) { return input->signalFDs[0]; }
void QSDNativeInputDrainSignal(QSDNativeInput *input) { unsigned char data[128]; while (read(input->signalFDs[0], data, sizeof(data)) > 0) {} }
bool QSDNativeInputReadAction(QSDNativeInput *input, QSDNativeAction *action) {
    uint32_t tail = atomic_load_explicit(&input->tail, memory_order_relaxed);
    if (tail == atomic_load_explicit(&input->head, memory_order_acquire)) return false;
    *action = input->queue[tail % QSD_QUEUE_CAPACITY];
    atomic_store_explicit(&input->tail, tail + 1, memory_order_release);
    return true;
}

bool QSDNativeInputReadStatus(const char *path, QSDNativeStatus *status) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return false;
    struct stat info;
    if (fstat(fd, &info) != 0 || info.st_size != sizeof(QSDSharedStatus)) { close(fd); return false; }
    const QSDSharedStatus *shared = mmap(NULL, sizeof(QSDSharedStatus), PROT_READ, MAP_SHARED, fd, 0);
    close(fd);
    if (shared == MAP_FAILED) return false;
    if (shared->magic != QSD_MAGIC) { munmap((void *)shared, sizeof(*shared)); return false; }
    *status = (QSDNativeStatus){atomic_load(&shared->pid), atomic_load(&shared->phase), atomic_load(&shared->fault),
        atomic_load(&shared->lastType), atomic_load(&shared->events), atomic_load(&shared->suppressed),
        atomic_load(&shared->actions), atomic_load(&shared->maximumNS)};
    munmap((void *)shared, sizeof(*shared));
    return true;
}

bool QSDNativeInputRouteForTesting(QSDNativeInput *input, CGEventType type, CGEventRef event) {
    return qsd_callback(NULL, type, event, input) == NULL;
}
