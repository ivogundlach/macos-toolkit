/*
 * IOHID event serialization adapted from InstantSpaceSwitcher commit
 * c64e0fd09857330422084387cb98e8d1f4c3e2d1 (MIT). See
 * ThirdPartyNotices/InstantSpaceSwitcher-MIT.txt.
 */
#include "event_serialize.h"

#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>

#pragma pack(push, 1)
typedef struct {
    uint32_t size;
    uint32_t type;
    uint32_t options;
    uint8_t depth;
    uint8_t reserved[3];
} KineticsIOHIDEventBase;

typedef struct {
    KineticsIOHIDEventBase base;
    int32_t position_x;
    int32_t position_y;
    int32_t position_z;
    uint32_t swipe_mask;
    uint16_t gesture_motion;
    uint16_t gesture_flavor;
    int32_t swipe_progress;
} KineticsIOHIDFluidTouchGestureData;

typedef struct {
    KineticsIOHIDEventBase base;
    int32_t velocity_x;
    int32_t velocity_y;
    int32_t velocity_z;
} KineticsIOHIDVelocityEventData;

typedef struct {
    uint64_t timestamp;
    uint64_t sender_id;
    uint32_t options;
    uint32_t attribute_length;
    uint32_t event_count;
} KineticsIOHIDSystemQueueElementHeader;
#pragma pack(pop)

static const uint32_t kKineticsIOHIDEventTypeVelocity = 9;
static const uint32_t kKineticsIOHIDEventTypeFluidTouchGesture = 23;
static const uint16_t kKineticsIOHIDGestureFlavorDockPrimary = 3;

static int32_t kinetics_double_to_fixed1616(double value) {
    int32_t fixed = (int32_t)(value * 65536.0);
    /* macOS 27 rejects a zero fixed-point progress for nonzero gestures. */
    if (fixed == 0 && value != 0.0) {
        return value > 0.0 ? 1 : -1;
    }
    return fixed;
}

static uint8_t *kinetics_generate_iohid_payload(CGEventRef event, size_t *outLength) {
    int64_t phase = CGEventGetIntegerValueField(event, (CGEventField)132);
    int64_t motion = CGEventGetIntegerValueField(event, (CGEventField)123);
    double progress = CGEventGetDoubleValueField(event, (CGEventField)124);
    double posX = CGEventGetDoubleValueField(event, (CGEventField)125);
    double posY = CGEventGetDoubleValueField(event, (CGEventField)126);
    double velocityX = CGEventGetDoubleValueField(event, (CGEventField)129);
    double velocityY = CGEventGetDoubleValueField(event, (CGEventField)130);
    int64_t swipeMask = CGEventGetIntegerValueField(event, (CGEventField)115);

    bool includeVelocity = (velocityX != 0.0 || velocityY != 0.0 || phase == 4);
    uint32_t eventCount = includeVelocity ? 2 : 1;
    size_t payloadLength = sizeof(KineticsIOHIDSystemQueueElementHeader) + sizeof(KineticsIOHIDFluidTouchGestureData);
    if (includeVelocity) payloadLength += sizeof(KineticsIOHIDVelocityEventData);

    uint8_t *payload = (uint8_t *)calloc(1, payloadLength);
    if (!payload) return NULL;

    KineticsIOHIDSystemQueueElementHeader *header = (KineticsIOHIDSystemQueueElementHeader *)payload;
    uint64_t timestamp = CGEventGetTimestamp(event);
    header->timestamp = timestamp == 0 ? mach_absolute_time() : timestamp;
    header->event_count = eventCount;

    KineticsIOHIDFluidTouchGestureData *fluid =
        (KineticsIOHIDFluidTouchGestureData *)(payload + sizeof(KineticsIOHIDSystemQueueElementHeader));
    fluid->base.size = sizeof(KineticsIOHIDFluidTouchGestureData);
    fluid->base.type = kKineticsIOHIDEventTypeFluidTouchGesture;
    fluid->base.options = (uint32_t)((phase & 0xFF) << 24);
    fluid->position_x = kinetics_double_to_fixed1616(posX);
    fluid->position_y = kinetics_double_to_fixed1616(posY);
    fluid->swipe_mask = (uint32_t)swipeMask;
    fluid->gesture_motion = (uint16_t)motion;
    fluid->gesture_flavor = kKineticsIOHIDGestureFlavorDockPrimary;
    fluid->swipe_progress = kinetics_double_to_fixed1616(progress);

    if (includeVelocity) {
        KineticsIOHIDVelocityEventData *velocity =
            (KineticsIOHIDVelocityEventData *)(payload + sizeof(KineticsIOHIDSystemQueueElementHeader) +
                                               sizeof(KineticsIOHIDFluidTouchGestureData));
        velocity->base.size = sizeof(KineticsIOHIDVelocityEventData);
        velocity->base.type = kKineticsIOHIDEventTypeVelocity;
        velocity->base.depth = 1;
        velocity->velocity_x = kinetics_double_to_fixed1616(velocityX);
        velocity->velocity_y = kinetics_double_to_fixed1616(velocityY);
    }

    *outLength = payloadLength;
    return payload;
}

CGEventRef kinetics_augment_dock_swipe_event(CGEventRef event) {
    if (!event) return NULL;

    CFDataRef data = CGEventCreateData(kCFAllocatorDefault, event);
    if (!data) return NULL;
    const uint8_t *bytes = CFDataGetBytePtr(data);
    CFIndex length = CFDataGetLength(data);
    if (length < 4 || bytes[0] != 0 || bytes[1] != 0 || bytes[2] != 0 || bytes[3] != 2) {
        CFRelease(data);
        return NULL;
    }

    size_t payloadLength = 0;
    uint8_t *payload = kinetics_generate_iohid_payload(event, &payloadLength);
    if (!payload) {
        CFRelease(data);
        return NULL;
    }

    size_t newLength = (size_t)length + 4 + payloadLength;
    uint8_t *newBytes = (uint8_t *)malloc(newLength);
    if (!newBytes) {
        free(payload);
        CFRelease(data);
        return NULL;
    }
    memcpy(newBytes, bytes, length);
    /* Serialized event tag: payload size (big-endian), then IOHID field 4205. */
    newBytes[length] = (uint8_t)((payloadLength >> 8) & 0xFF);
    newBytes[length + 1] = (uint8_t)(payloadLength & 0xFF);
    newBytes[length + 2] = (uint8_t)((4205 >> 8) & 0xFF);
    newBytes[length + 3] = (uint8_t)(4205 & 0xFF);
    memcpy(newBytes + length + 4, payload, payloadLength);

    free(payload);
    CFRelease(data);
    CFDataRef newData = CFDataCreate(kCFAllocatorDefault, newBytes, (CFIndex)newLength);
    free(newBytes);
    if (!newData) return NULL;
    CGEventRef result = CGEventCreateFromData(kCFAllocatorDefault, newData);
    CFRelease(newData);
    return result;
}

bool kinetics_requires_event_augmentation(void) {
    static int cachedResult = -1;
    if (cachedResult != -1) return cachedResult != 0;

    const char *override = getenv("KINETICS_FORCE_EVENT_AUGMENTATION");
    if (override) {
        cachedResult = strcmp(override, "1") == 0 ? 1 : 0;
        return cachedResult != 0;
    }

    char version[32] = {0};
    size_t size = sizeof(version);
    if (sysctlbyname("kern.osproductversion", version, &size, NULL, 0) != 0) {
        cachedResult = 0;
        return false;
    }
    int major = 0;
    if (sscanf(version, "%d", &major) != 1) {
        cachedResult = 0;
        return false;
    }
    cachedResult = major >= 27 ? 1 : 0;
    return cachedResult != 0;
}
