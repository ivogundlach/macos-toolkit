#ifndef KINETICS_EVENT_SERIALIZE_H
#define KINETICS_EVENT_SERIALIZE_H

#include <ApplicationServices/ApplicationServices.h>
#include <stdbool.h>

/**
 * Augments a synthetic Dock-swipe CGEvent with the raw IOHID payload required
 * by macOS 27. The returned event is retained; callers release it.
 */
CGEventRef kinetics_augment_dock_swipe_event(CGEventRef event);

/** Returns true on macOS 27+, with KINETICS_FORCE_EVENT_AUGMENTATION overrides. */
bool kinetics_requires_event_augmentation(void);

#endif /* KINETICS_EVENT_SERIALIZE_H */
