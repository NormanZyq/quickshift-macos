#ifndef QSD_INPUT_SAFETY_H
#define QSD_INPUT_SAFETY_H

#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct QSDNativeInput QSDNativeInput;

typedef struct {
    uint16_t code;
    uint8_t kind;       /* 0: mouse, 1: physical key */
    uint8_t modifiers;  /* control=1, option=2, shift=4, command=8 */
} QSDNativeShortcut;

typedef struct {
    QSDNativeShortcut left;
    QSDNativeShortcut right;
    int32_t foregroundPID;
    bool enabled;
    bool recording;
} QSDNativeConfiguration;

typedef struct {
    int32_t direction;  /* 0: left, 1: right */
    int32_t foregroundPID;
} QSDNativeAction;

typedef struct {
    int32_t processID;
    uint32_t phase;     /* 0: stopped, 1: running, 2: startup failed, 3: safety stop */
    uint32_t fault;     /* 1: callback, 2: event loop, 3: main loop, 4: OS timeout, 5: queue */
    uint32_t lastEventType;
    uint64_t events;
    uint64_t suppressed;
    uint64_t actions;
    uint64_t maximumCallbackNanoseconds;
} QSDNativeStatus;

QSDNativeInput *QSDNativeInputCreate(const char *statusPath, int32_t targetPID);
void QSDNativeInputDestroy(QSDNativeInput *input);
void QSDNativeInputConfigure(QSDNativeInput *input, QSDNativeConfiguration configuration);
bool QSDNativeInputStart(QSDNativeInput *input);
void QSDNativeInputStop(QSDNativeInput *input);
void QSDNativeInputResetFault(QSDNativeInput *input);
bool QSDNativeInputIsRunning(QSDNativeInput *input);
uint32_t QSDNativeInputFault(QSDNativeInput *input);
int QSDNativeInputSignalFD(QSDNativeInput *input);
void QSDNativeInputDrainSignal(QSDNativeInput *input);
bool QSDNativeInputReadAction(QSDNativeInput *input, QSDNativeAction *action);
bool QSDNativeInputReadStatus(const char *path, QSDNativeStatus *status);

/* Constructs no tap and posts no input. Exercises the production router in memory. */
bool QSDNativeInputRouteForTesting(QSDNativeInput *input, CGEventType type, CGEventRef event);

#endif
