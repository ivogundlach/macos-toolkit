#ifndef KINETICS_CORE_H
#define KINETICS_CORE_H

#include <stdbool.h>
#include <stdint.h>

/**
 * Kinetics' native desktop-switch engine.
 *
 * The private CoreGraphics Services calls and the serialized IOHID payload in
 * this target are derived from InstantSpaceSwitcher commit
 * c64e0fd09857330422084387cb98e8d1f4c3e2d1 (MIT licensed). The native
 * trackpad override state machine is adapted from commit
 * fd37e7fed62ad862ec6326aa7dac9b7bc6b413e5. See
 * ThirdPartyNotices/InstantSpaceSwitcher-MIT.txt for the complete notice.
 */

typedef enum {
    KineticsDirectionLeft = 0,
    KineticsDirectionRight = 1
} KineticsDirection;

typedef struct {
    unsigned int currentIndex;
    unsigned int spaceCount;
    char displayID[128];
} KineticsSpaceInfo;

/** Returns true when macOS requires the serialized macOS 27 payload. */
bool kinetics_requires_event_augmentation(void);

/** Returns whether this process currently has Accessibility trust. */
bool kinetics_is_accessibility_trusted(void);

/** Returns true when the event tap is installed and enabled. */
bool kinetics_is_event_tap_active(void);

/** Installs the key/gesture event tap. Fails truthfully when TCC denies it. */
bool kinetics_start_event_tap(void);

/** Removes the event tap and releases its run-loop source. */
void kinetics_stop_event_tap(void);

/** Enables or disables engine interception without recreating the tap. */
void kinetics_set_enabled(bool enabled);

/**
 * Enables or disables replacement of real HID horizontal Spaces swipes with
 * one bounded Crisp switch. Synthetic/non-HID events pass through; disabling
 * also resets any in-flight native swipe tracking.
 */
void kinetics_set_trackpad_override(bool enabled);

/** Updates the ending velocity used by the Crisp gesture path. */
void kinetics_set_gesture_velocity(double velocity);

/** Enables the high-velocity snap path used for reduced/minimized travel. */
void kinetics_set_snap_mode(bool enabled);

/**
 * Updates the symbolic-hotkey key codes and relevant modifier masks used by
 * the event-tap matcher. Bits outside Command/Option/Control/Shift are ignored
 * by the matcher so Fn and numeric-pad flags do not cause false mismatches.
 */
void kinetics_set_shortcuts(int64_t leftKeyCode,
                            uint64_t leftModifierMask,
                            int64_t rightKeyCode,
                            uint64_t rightModifierMask);

/** Reads the active menu-bar display's current space and bounds. */
bool kinetics_get_space_info(KineticsSpaceInfo *info);

/** Returns whether a directional move is in bounds for a snapshot. */
bool kinetics_can_move(KineticsSpaceInfo info, KineticsDirection direction);

/** Posts one bounded desktop switch using the configured Crisp/snap path. */
bool kinetics_switch(KineticsDirection direction);

/** Sets a callback invoked after a switch accepted by the engine. */
typedef void (*KineticsSwitchCallback)(unsigned int newSpaceIndex);
void kinetics_set_switch_callback(KineticsSwitchCallback callback);

#endif /* KINETICS_CORE_H */
