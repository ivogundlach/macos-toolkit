/*
 * Kinetics native engine. The CGS space inspection and augmented DockSwipe
 * mechanics are adapted from InstantSpaceSwitcher commit
 * c64e0fd09857330422084387cb98e8d1f4c3e2d1, MIT licensed. The native
 * trackpad override state machine is adapted from commit
 * fd37e7fed62ad862ec6326aa7dac9b7bc6b413e5. Kinetics uses only the validated
 * macOS 27 gesture path and does not copy that product's UI, identity, or
 * settings. See ThirdPartyNotices/InstantSpaceSwitcher-MIT.txt.
 */
#include "KineticsCore.h"
#include "event_serialize.h"

#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CGEventTypes.h>
#include <float.h>
#include <math.h>
#include <mach/mach_time.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>

static const CGEventField kKineticsEventTypeField = (CGEventField)55;
static const CGEventField kKineticsGestureHIDType = (CGEventField)110;
static const CGEventField kKineticsGestureSwipeMotion = (CGEventField)123;
static const CGEventField kKineticsGestureSwipeProgress = (CGEventField)124;
static const CGEventField kKineticsGestureSwipePositionX = (CGEventField)125;
static const CGEventField kKineticsGestureSwipeVelocityX = (CGEventField)129;
static const CGEventField kKineticsGestureSwipeVelocityY = (CGEventField)130;
static const CGEventField kKineticsGesturePhase = (CGEventField)132;
static const CGEventField kKineticsGesturePhaseAlias = (CGEventField)134;
static const CGEventField kKineticsGestureZoomDeltaY = (CGEventField)138;
static const CGEventField kKineticsSourceUnixProcessIDAlias = (CGEventField)169;

/* IOHIDEventType enum (private IOHIDFamily). */
static const uint32_t kKineticsIOHIDEventTypeDockSwipe = 23;

typedef uint32_t KineticsCGSEventType;
enum {
    kKineticsCGSEventGesture = 29,
    kKineticsCGSEventDockControl = 30
};

typedef CF_ENUM(uint8_t, KineticsGesturePhase) {
    kKineticsGesturePhaseBegan = 1,
    kKineticsGesturePhaseChanged = 2,
    kKineticsGesturePhaseEnded = 4,
    kKineticsGesturePhaseCancelled = 8
};

typedef CF_ENUM(uint16_t, KineticsGestureMotion) {
    kKineticsGestureMotionHorizontal = 1
};

typedef int32_t KineticsCGSConnectionID;
typedef uint64_t KineticsCGSSpaceID;

extern CFArrayRef CGSCopyManagedDisplaySpaces(KineticsCGSConnectionID connection, CFStringRef display)
    __attribute__((weak_import));
extern CFStringRef CGSCopyActiveMenuBarDisplayIdentifier(KineticsCGSConnectionID connection)
    __attribute__((weak_import));
extern KineticsCGSConnectionID CGSMainConnectionID(void) __attribute__((weak_import));
extern KineticsCGSSpaceID CGSGetActiveSpace(KineticsCGSConnectionID connection) __attribute__((weak_import));

static CFMachPortRef globalTap = NULL;
static CFRunLoopSourceRef globalSource = NULL;
static bool engineEnabled = false;
static bool trackpadOverrideEnabled = false;
static bool trackpadTracking = false;
static bool trackpadFired = false;
static uint64_t trackpadTrackingTimestamp = 0;
static bool snapMode = false;
static double gestureVelocity = 60.0;
static uint64_t lastAcceptedKeyTime = 0;
static KineticsSwitchCallback switchCallback = NULL;
static CFMutableDictionaryRef predictions = NULL;
static int64_t leftShortcutKeyCode = 123;
static uint64_t leftShortcutModifierMask = (uint64_t)kCGEventFlagMaskControl |
                                            (uint64_t)kCGEventFlagMaskShift;
static int64_t rightShortcutKeyCode = 124;
static uint64_t rightShortcutModifierMask = (uint64_t)kCGEventFlagMaskControl |
                                             (uint64_t)kCGEventFlagMaskShift;
static const uint64_t relevantShortcutModifierMask =
    (uint64_t)kCGEventFlagMaskCommand |
    (uint64_t)kCGEventFlagMaskAlternate |
    (uint64_t)kCGEventFlagMaskControl |
    (uint64_t)kCGEventFlagMaskShift;

/*
 * The event-tap callback and these public setters are invoked on the app's
 * main run loop. State mutation is therefore serialized by that run loop;
 * this native target does not provide a concurrent-call synchronization API.
 */
static const int64_t kKineticsSyntheticEventMarker = INT64_C(0x4b494e4554494353);
static const double kKineticsSwipeProgressThreshold = 0.02;

typedef struct {
    unsigned int index;
    uint64_t timestamp;
} KineticsPredictionState;

static const long double kKineticsPredictionTTLNanoseconds = 750000000.0L;
static mach_timebase_info_data_t predictionTimebase = {0, 0};

static void ensure_prediction_timebase(void) {
    if (predictionTimebase.numer != 0 && predictionTimebase.denom != 0) return;
    if (mach_timebase_info(&predictionTimebase) != KERN_SUCCESS ||
        predictionTimebase.numer == 0 || predictionTimebase.denom == 0) {
        predictionTimebase.numer = 1;
        predictionTimebase.denom = 1;
    }
}

static long double elapsed_nanoseconds(uint64_t start, uint64_t end) {
    if (end <= start) return 0.0L;
    ensure_prediction_timebase();
    /* Use floating-point conversion so delta * numer cannot overflow first. */
    return ((long double)(end - start) * (long double)predictionTimebase.numer) /
           (long double)predictionTimebase.denom;
}

static void reset_trackpad_tracking(void) {
    trackpadTracking = false;
    trackpadFired = false;
    trackpadTrackingTimestamp = 0;
}

static bool trackpad_tracking_is_fresh(void) {
    if (!trackpadTracking || trackpadTrackingTimestamp == 0) return false;
    if (elapsed_nanoseconds(trackpadTrackingTimestamp, mach_absolute_time()) >=
        kKineticsPredictionTTLNanoseconds) {
        reset_trackpad_tracking();
        return false;
    }
    return true;
}

static void touch_trackpad_tracking(void) {
    trackpadTrackingTimestamp = mach_absolute_time();
}

static bool prediction_expired(uint64_t timestamp) {
    return elapsed_nanoseconds(timestamp, mach_absolute_time()) >=
           kKineticsPredictionTTLNanoseconds;
}

static bool cgs_symbols_available(void) {
    return (&CGSMainConnectionID != NULL) && (&CGSGetActiveSpace != NULL) &&
           (&CGSCopyManagedDisplaySpaces != NULL);
}

static bool get_prediction(const char *displayID, unsigned int *outIndex) {
    if (!displayID || !predictions || !outIndex) return false;
    CFStringRef key = CFStringCreateWithCString(NULL, displayID, kCFStringEncodingUTF8);
    if (!key) return false;
    const void *value = CFDictionaryGetValue(predictions, key);
    KineticsPredictionState state = {0, 0};
    bool found = value && CFGetTypeID(value) == CFDataGetTypeID() &&
                 CFDataGetLength((CFDataRef)value) == (CFIndex)sizeof(state);
    if (found) {
        memcpy(&state, CFDataGetBytePtr((CFDataRef)value), sizeof(state));
        if (prediction_expired(state.timestamp)) {
            CFDictionaryRemoveValue(predictions, key);
            found = false;
        } else {
            *outIndex = state.index;
        }
    } else if (value) {
        CFDictionaryRemoveValue(predictions, key);
    }
    CFRelease(key);
    return found;
}

static void clear_prediction(const char *displayID) {
    if (!displayID || !predictions) return;
    CFStringRef key = CFStringCreateWithCString(NULL, displayID, kCFStringEncodingUTF8);
    if (key) {
        CFDictionaryRemoveValue(predictions, key);
        CFRelease(key);
    }
}

static void set_prediction(const char *displayID, unsigned int index) {
    if (!displayID || !predictions) return;
    CFStringRef key = CFStringCreateWithCString(NULL, displayID, kCFStringEncodingUTF8);
    KineticsPredictionState state = {index, mach_absolute_time()};
    CFDataRef value = CFDataCreate(NULL, (const UInt8 *)&state, sizeof(state));
    if (key && value) CFDictionarySetValue(predictions, key, value);
    if (key) CFRelease(key);
    if (value) CFRelease(value);
}

static void reconcile_prediction(const KineticsSpaceInfo *info) {
    if (!info || !info->displayID[0]) return;
    unsigned int predicted = 0;
    if (get_prediction(info->displayID, &predicted) && predicted == info->currentIndex) {
        clear_prediction(info->displayID);
    }
}

static bool extract_space_info(CFDictionaryRef displayDict,
                               KineticsCGSSpaceID activeSpace,
                               bool hasActiveSpace,
                               KineticsSpaceInfo *outInfo) {
    if (!displayDict || !outInfo) return false;

    memset(outInfo, 0, sizeof(*outInfo));
    CFStringRef identifier = (CFStringRef)CFDictionaryGetValue(displayDict, CFSTR("Display Identifier"));
    if (identifier && CFGetTypeID(identifier) == CFStringGetTypeID()) {
        CFStringGetCString(identifier, outInfo->displayID, sizeof(outInfo->displayID), kCFStringEncodingUTF8);
    }

    CFArrayRef spaces = (CFArrayRef)CFDictionaryGetValue(displayDict, CFSTR("Spaces"));
    if (!spaces || CFGetTypeID(spaces) != CFArrayGetTypeID()) return false;

    /* Prefer the display-local current space; global CGSGetActiveSpace can lag on multi-display setups. */
    KineticsCGSSpaceID displayActiveSpace = 0;
    CFDictionaryRef currentSpace = (CFDictionaryRef)CFDictionaryGetValue(displayDict, CFSTR("Current Space"));
    if (currentSpace && CFGetTypeID(currentSpace) == CFDictionaryGetTypeID()) {
        CFNumberRef currentID = (CFNumberRef)CFDictionaryGetValue(currentSpace, CFSTR("id64"));
        if (currentID && CFGetTypeID(currentID) == CFNumberGetTypeID()) {
            CFNumberGetValue(currentID, kCFNumberSInt64Type, &displayActiveSpace);
        }
    }

    KineticsCGSSpaceID targetActiveSpace = displayActiveSpace != 0 ? displayActiveSpace : activeSpace;
    bool hasTarget = displayActiveSpace != 0 || hasActiveSpace;
    CFIndex count = CFArrayGetCount(spaces);
    unsigned int validCount = 0;
    unsigned int activeIndex = 0;
    bool foundActive = false;

    for (CFIndex i = 0; i < count; i++) {
        const void *value = CFArrayGetValueAtIndex(spaces, i);
        if (!value || CFGetTypeID(value) != CFDictionaryGetTypeID()) continue;
        CFNumberRef idNumber = (CFNumberRef)CFDictionaryGetValue((CFDictionaryRef)value, CFSTR("id64"));
        if (!idNumber || CFGetTypeID(idNumber) != CFNumberGetTypeID()) continue;
        KineticsCGSSpaceID candidate = 0;
        if (!CFNumberGetValue(idNumber, kCFNumberSInt64Type, &candidate)) continue;
        if (!foundActive && hasTarget && candidate == targetActiveSpace) {
            activeIndex = validCount;
            foundActive = true;
        }
        validCount++;
    }

    if (validCount == 0 || (hasTarget && !foundActive)) return false;
    outInfo->spaceCount = validCount;
    outInfo->currentIndex = foundActive ? activeIndex : 0;
    return true;
}

static bool load_space_info(KineticsSpaceInfo *info) {
    if (!info || !cgs_symbols_available()) return false;
    KineticsCGSConnectionID connection = CGSMainConnectionID();
    if (connection == 0) return false;

    KineticsCGSSpaceID activeSpace = CGSGetActiveSpace(connection);
    bool hasActiveSpace = activeSpace != 0;
    CFStringRef displayIdentifier = NULL;
    if (&CGSCopyActiveMenuBarDisplayIdentifier != NULL) {
        displayIdentifier = CGSCopyActiveMenuBarDisplayIdentifier(connection);
    }

    CFArrayRef displays = CGSCopyManagedDisplaySpaces(connection, displayIdentifier);
    if (!displays && displayIdentifier) displays = CGSCopyManagedDisplaySpaces(connection, NULL);
    if (!displays) {
        if (displayIdentifier) CFRelease(displayIdentifier);
        return false;
    }

    CFDictionaryRef target = NULL;
    CFDictionaryRef fallback = NULL;
    for (CFIndex i = 0; i < CFArrayGetCount(displays); i++) {
        const void *value = CFArrayGetValueAtIndex(displays, i);
        if (!value || CFGetTypeID(value) != CFDictionaryGetTypeID()) continue;
        CFDictionaryRef dict = (CFDictionaryRef)value;
        if (!fallback) fallback = dict;
        if (displayIdentifier &&
            CFGetTypeID(displayIdentifier) == CFStringGetTypeID()) {
            CFStringRef candidateIdentifier =
                (CFStringRef)CFDictionaryGetValue(dict, CFSTR("Display Identifier"));
            if (candidateIdentifier &&
                CFGetTypeID(candidateIdentifier) == CFStringGetTypeID() &&
                CFEqual(candidateIdentifier, displayIdentifier)) {
                target = dict;
            }
        }
    }
    if (!target) target = fallback;
    bool success = target ? extract_space_info(target, activeSpace, hasActiveSpace, info) : false;
    if (displayIdentifier) CFRelease(displayIdentifier);
    CFRelease(displays);
    return success;
}

static bool should_block(const KineticsSpaceInfo *info, KineticsDirection direction) {
    if (!info || info->spaceCount == 0) return true;
    unsigned int current = info->currentIndex;
    unsigned int predicted = 0;
    if (get_prediction(info->displayID, &predicted)) current = predicted;
    if (direction == KineticsDirectionLeft) return current == 0;
    return current + 1 >= info->spaceCount;
}

bool kinetics_get_space_info(KineticsSpaceInfo *info) {
    if (!info) return false;
    memset(info, 0, sizeof(*info));
    bool success = load_space_info(info);
    if (success) reconcile_prediction(info);
    return success;
}

bool kinetics_can_move(KineticsSpaceInfo info, KineticsDirection direction) {
    return !should_block(&info, direction);
}

static bool post_dock_swipe(KineticsGesturePhase phase, KineticsDirection direction, double velocity) {
    bool right = direction == KineticsDirectionRight;
    bool augmented = kinetics_requires_event_augmentation();
    /* macOS 27 Dock interprets modern payload signs opposite the app model. */
    double progress = augmented ? (right ? -0.000016 : 0.000016)
                                : (right ? (double)FLT_TRUE_MIN : -(double)FLT_TRUE_MIN);
    double legacyVelocity = right ? velocity : -velocity;
    double modernVelocity = right ? -velocity : velocity;

    CGEventRef event = CGEventCreate(NULL);
    if (!event) return false;
    CGEventSetIntegerValueField(event, kKineticsEventTypeField, kKineticsCGSEventDockControl);
    CGEventSetIntegerValueField(event, kKineticsGestureHIDType, kKineticsIOHIDEventTypeDockSwipe);
    CGEventSetIntegerValueField(event, kKineticsGesturePhase, phase);
    CGEventSetDoubleValueField(event, kKineticsGestureSwipeProgress, progress);
    CGEventSetIntegerValueField(event, kKineticsGestureSwipeMotion, kKineticsGestureMotionHorizontal);
    CGEventSetIntegerValueField(event, kCGEventSourceUserData, kKineticsSyntheticEventMarker);

    if (augmented) {
        CGEventSetIntegerValueField(event, kKineticsGesturePhaseAlias, phase);
        CGEventSetDoubleValueField(event, kKineticsGestureZoomDeltaY, 3.0);
        CGEventSetDoubleValueField(event, kKineticsSourceUnixProcessIDAlias, (double)mach_absolute_time());
        CGEventSetDoubleValueField(event, kKineticsGestureSwipePositionX, 0.1);
        if (phase == kKineticsGesturePhaseEnded) {
            /* Only Ended carries velocity, matching the validated macOS 27 trace. */
            CGEventSetDoubleValueField(event, kKineticsGestureSwipeVelocityX, modernVelocity);
        }
        CGEventRef augmentedEvent = kinetics_augment_dock_swipe_event(event);
        CFRelease(event);
        if (!augmentedEvent) return false;
        /* Reapply the marker after serialization so the tap always recognizes
         * this generated event before its PID defense-in-depth check. */
        CGEventSetIntegerValueField(augmentedEvent, kCGEventSourceUserData,
                                    kKineticsSyntheticEventMarker);
        CGEventPost(kCGSessionEventTap, augmentedEvent);
        CFRelease(augmentedEvent);
        return true;
    }

    CGEventSetDoubleValueField(event, kKineticsGestureSwipeVelocityX, legacyVelocity);
    CGEventSetDoubleValueField(event, kKineticsGestureSwipeVelocityY, legacyVelocity);
    CGEventPost(kCGSessionEventTap, event);
    CFRelease(event);
    return true;
}

static bool perform_switch_gesture(KineticsDirection direction) {
    double velocity = snapMode ? 5000.0 : gestureVelocity;
    useconds_t phaseDelay = kinetics_requires_event_augmentation() ? 10000 : 0;
    if (!post_dock_swipe(kKineticsGesturePhaseBegan, direction, velocity)) return false;
    if (phaseDelay) usleep(phaseDelay);
    if (!post_dock_swipe(kKineticsGesturePhaseChanged, direction, velocity)) return false;
    if (phaseDelay) usleep(phaseDelay);
    return post_dock_swipe(kKineticsGesturePhaseEnded, direction, velocity);
}

bool kinetics_switch(KineticsDirection direction) {
    KineticsSpaceInfo info;
    if (!kinetics_get_space_info(&info) || should_block(&info, direction)) return false;
    unsigned int current = info.currentIndex;
    unsigned int predicted = 0;
    if (get_prediction(info.displayID, &predicted)) current = predicted;
    unsigned int target = direction == KineticsDirectionLeft ? current - 1 : current + 1;
    if (!perform_switch_gesture(direction)) return false;
    set_prediction(info.displayID, target);
    if (switchCallback) switchCallback(target);
    return true;
}

static bool key_debounce_elapsed(void) {
    uint64_t now = mach_absolute_time();
    if (lastAcceptedKeyTime == 0) {
        lastAcceptedKeyTime = now;
        return true;
    }
    mach_timebase_info_data_t timebase = {0};
    mach_timebase_info(&timebase);
    uint64_t elapsedNs = (now - lastAcceptedKeyTime) * timebase.numer / timebase.denom;
    if (elapsedNs < 120000000ULL) return false;
    lastAcceptedKeyTime = now;
    return true;
}

static CGEventRef event_tap_callback(CGEventTapProxy proxy,
                                     CGEventType type,
                                     CGEventRef event,
                                     void *refcon) {
    (void)proxy;
    (void)refcon;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        reset_trackpad_tracking();
        if (globalTap) CGEventTapEnable(globalTap, true);
        return event;
    }
    if (!engineEnabled || !globalTap || !kinetics_is_accessibility_trusted()) {
        reset_trackpad_tracking();
        return event;
    }

    /* Preserve the established Control-arrow matcher exactly. */
    if (type == kCGEventKeyDown) {
        if (CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat) != 0) return event;
        CGEventFlags flags = CGEventGetFlags(event);
        uint64_t relevantFlags = (uint64_t)flags & relevantShortcutModifierMask;
        int64_t keyCode = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        KineticsDirection direction;
        if (keyCode == leftShortcutKeyCode && relevantFlags == leftShortcutModifierMask) {
            direction = KineticsDirectionLeft;
        } else if (keyCode == rightShortcutKeyCode && relevantFlags == rightShortcutModifierMask) {
            direction = KineticsDirectionRight;
        }
        else return event;
        if (!key_debounce_elapsed()) return event;
        /* Swallow only a bounded switch that was actually posted. */
        return kinetics_switch(direction) ? NULL : event;
    }

    if (!trackpadOverrideEnabled) return event;

    KineticsCGSEventType eventType =
        (KineticsCGSEventType)CGEventGetIntegerValueField(event, kKineticsEventTypeField);
    if (eventType != kKineticsCGSEventGesture && eventType != kKineticsCGSEventDockControl) {
        return event;
    }

    /* Kinetics' own synthetic events are never native swipe input. */
    if (CGEventGetIntegerValueField(event, kCGEventSourceUserData) ==
        kKineticsSyntheticEventMarker) {
        return event;
    }

    /* Real trackpad events originate from the HID kernel (source PID zero). */
    pid_t sourcePID = (pid_t)CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID);
    if (sourcePID != 0) return event;

    if (eventType == kKineticsCGSEventDockControl) {
        uint32_t hidType =
            (uint32_t)CGEventGetIntegerValueField(event, kKineticsGestureHIDType);
        if (hidType != kKineticsIOHIDEventTypeDockSwipe) return event;

        uint16_t motion =
            (uint16_t)CGEventGetIntegerValueField(event, kKineticsGestureSwipeMotion);
        if (motion != kKineticsGestureMotionHorizontal) return event;

        KineticsGesturePhase phase =
            (KineticsGesturePhase)CGEventGetIntegerValueField(event, kKineticsGesturePhase);
        switch (phase) {
        case kKineticsGesturePhaseBegan:
            /* A new real swipe always starts a clean native tracking sequence. */
            reset_trackpad_tracking();
            trackpadTracking = true;
            touch_trackpad_tracking();
            return NULL;

        case kKineticsGesturePhaseChanged: {
            if (!trackpad_tracking_is_fresh()) return event;
            touch_trackpad_tracking();
            if (!trackpadFired) {
                double progress =
                    CGEventGetDoubleValueField(event, kKineticsGestureSwipeProgress);
                if (fabs(progress) >= kKineticsSwipeProgressThreshold) {
                    KineticsDirection direction =
                        progress > 0.0 ? KineticsDirectionRight : KineticsDirectionLeft;
                    trackpadFired = true;
                    kinetics_switch(direction);
                }
            }
            return NULL;
        }

        case kKineticsGesturePhaseEnded: {
            if (!trackpad_tracking_is_fresh()) return event;
            touch_trackpad_tracking();
            if (!trackpadFired) {
                double velocity =
                    CGEventGetDoubleValueField(event, kKineticsGestureSwipeVelocityX);
                if (velocity != 0.0) {
                    KineticsDirection direction =
                        velocity > 0.0 ? KineticsDirectionRight : KineticsDirectionLeft;
                    trackpadFired = true;
                    kinetics_switch(direction);
                }
            }
            reset_trackpad_tracking();
            return NULL;
        }

        case kKineticsGesturePhaseCancelled:
            if (!trackpad_tracking_is_fresh()) return event;
            reset_trackpad_tracking();
            return NULL;

        default:
            return trackpad_tracking_is_fresh() ? NULL : event;
        }
    }

    /* Suppress only real companion gesture events during a fresh swipe. */
    if (trackpad_tracking_is_fresh()) {
        touch_trackpad_tracking();
        return NULL;
    }
    return event;
}

bool kinetics_is_accessibility_trusted(void) {
    return AXIsProcessTrusted();
}

bool kinetics_is_event_tap_active(void) {
    return globalTap != NULL;
}

bool kinetics_start_event_tap(void) {
    if (globalTap) return true;
    if (!kinetics_is_accessibility_trusted()) return false;
    if (!predictions) {
        predictions = CFDictionaryCreateMutable(NULL, 0, &kCFCopyStringDictionaryKeyCallBacks,
                                                 &kCFTypeDictionaryValueCallBacks);
    }
    globalTap = CGEventTapCreate(kCGSessionEventTap,
                                 kCGHeadInsertEventTap,
                                 kCGEventTapOptionDefault,
                                 CGEventMaskBit(kCGEventKeyDown) |
                                     CGEventMaskBit((CGEventType)kKineticsCGSEventGesture) |
                                     CGEventMaskBit((CGEventType)kKineticsCGSEventDockControl),
                                 event_tap_callback,
                                 NULL);
    if (!globalTap) return false;
    globalSource = CFMachPortCreateRunLoopSource(NULL, globalTap, 0);
    if (!globalSource) {
        CFRelease(globalTap);
        globalTap = NULL;
        return false;
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), globalSource, kCFRunLoopCommonModes);
    CGEventTapEnable(globalTap, true);
    return true;
}

void kinetics_stop_event_tap(void) {
    engineEnabled = false;
    reset_trackpad_tracking();
    if (globalSource) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), globalSource, kCFRunLoopCommonModes);
        CFRelease(globalSource);
        globalSource = NULL;
    }
    if (globalTap) {
        CGEventTapEnable(globalTap, false);
        CFRelease(globalTap);
        globalTap = NULL;
    }
    if (predictions) {
        CFDictionaryRemoveAllValues(predictions);
        CFRelease(predictions);
        predictions = NULL;
    }
}

void kinetics_set_enabled(bool enabled) {
    engineEnabled = enabled;
    if (!enabled) {
        lastAcceptedKeyTime = 0;
        reset_trackpad_tracking();
    }
}

void kinetics_set_trackpad_override(bool enabled) {
    trackpadOverrideEnabled = enabled;
    if (!enabled) reset_trackpad_tracking();
}

void kinetics_set_gesture_velocity(double velocity) {
    if (velocity > 0.0) gestureVelocity = velocity;
}

void kinetics_set_snap_mode(bool enabled) {
    snapMode = enabled;
}

void kinetics_set_shortcuts(int64_t leftKeyCode,
                            uint64_t leftModifierMask,
                            int64_t rightKeyCode,
                            uint64_t rightModifierMask) {
    if (leftKeyCode >= 0) leftShortcutKeyCode = leftKeyCode;
    if (rightKeyCode >= 0) rightShortcutKeyCode = rightKeyCode;
    leftShortcutModifierMask = leftModifierMask & relevantShortcutModifierMask;
    rightShortcutModifierMask = rightModifierMask & relevantShortcutModifierMask;
}

void kinetics_set_switch_callback(KineticsSwitchCallback callback) {
    switchCallback = callback;
}
