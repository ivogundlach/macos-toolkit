# SwiftUI Layout Forensics

Read this when a macOS surface is described as *cheap*, *blocky*, *off*, *misaligned*, or *laggy* —
words that name a symptom, not a cause. Every entry below was a real defect with a real cause; none
of them were taste calls, and none would have been found by looking harder.

## 1. Measure the surface, do not eyeball it

Adjectives do not survive contact with a pixel measurement. "Off centre" was 7.5pt. "Columns don't
line up" was 13pt by the fourth column. "More space below the title" was 12.5pt above versus 18pt
below. All three had different causes; all three read identically on screen.

Recipe for a macOS app, no focus stolen:

```bash
screencapture -o -x -l<windowID> shot.png   # -l captures an occluded window
```

Then scan the bitmap for glyph bands instead of guessing coordinates: sweep rows for where the
row-wise max brightness rises, which gives the header band and the first row band; inside a band,
group the columns that contain ink into runs. Report left and right edges in **points** (retina
bitmaps are 2×). Compare the header's right edges against the values' right edges column by column.

Two traps in the capture itself:

- `sips -c H W` crops from the **centre**. For a top crop use PIL.
- An occluded window returns **stale frames** if the app pauses redraw when not visible. If every
  frame is byte-identical, the app is not idle — the capture is. Do not measure timing this way.

## 2. One geometry source of truth

If a header and its rows each compute the same column layout, they will disagree. Compute the width
array **once** and pass it to every consumer — header, rows, and any divider drawn between them.

Why they disagree is worth knowing, because it generalises:

- An `NSViewRepresentable` with no `intrinsicContentSize` reports **flexible** and fills whatever it
  is proposed.
- A `Text` reports its **ideal** width.
- An `HStack` divides slack in proportion to what each child asks for.

So the same `.frame(maxWidth:)` on both sides resolves to two different widths. This is not a bug in
either view; it is what asking twice means.

## 3. AppKit defaults that silently break SwiftUI layout

Every one of these is a default that is reasonable in AppKit and wrong inside a SwiftUI table:

| Default | Effect | Fix |
|---|---|---|
| `attributedStringValue` overrides the field's `alignment` and `lineBreakMode` | right-aligned headers render flush **left** over right-aligned numbers | put an `NSMutableParagraphStyle` **inside** the attributed string |
| `NSTextFieldCell` insets text ~2pt from the field's bounds | right-aligned text sits ~2pt off its column | inset the label's frame by `-2` |
| A label taller than its text draws that text at the **top** | visibly more air below a header than above it | frame the label at its `fittingSize.height`, centred on `bounds.midY` |
| Kerning is **trailing** | the last character's kern pushes right-aligned text off its column | apply kern to `length - 1` |

## 4. Overflow is centred, not clipped

An `HStack` whose fixed children exceed the proposal shifts everything by **half** the overflow. On
screen that reads as a mysterious *uniform* offset — which is the tell: a proportional error grows
across columns, a constant one means a shift.

The usual source on macOS is the scroller. **Legacy (always-visible) scrollers take width out of a
`ScrollView`'s content; overlay scrollers do not**, and the setting changes under a running app. Do
not hardcode a gutter. Measure the resolved content width and give the difference back to whatever
sits outside the scroll view:

```swift
@State private var scrollContentWidth: CGFloat = 0
private var scrollerWidth: CGFloat { max(0, paneWidth - scrollContentWidth) }
```

## 5. Padding, and why a dense table reads as a cramped one

- **One scale, in the tokens enum.** Mixing 4, 6, 7, 8, 9, 10 and 12 on one screen is the defect.
- **A container's margin must not be smaller than the padding inside it.** That inversion, more than
  any single value, is what makes a layout look cheap.
- **Density comes from row height, not from starving the edges.** An 18pt row can carry a 20pt inset.
- **Content must clear a lit rim, not just the frame.** Glass and material panes draw a bright stroke
  at their edge; ~8pt of clearance from it reads as *pressed against the container*.
- **Keep a block's air in one number.** Splitting a header's air between a height and a separate top
  inset guarantees the two halves stop matching under any later change; fold it into the height.
- **Small type set tight against a rule** is the single clearest cheap tell in a table.

## 6. Where the slack goes is a decision, not a default

Spare width in a table can be shared between the columns or parked after the last one. They look
completely different and both are defensible: sharing fills the pane but pushes every number further
from the name it belongs to; parking keeps the numbers close and leaves the right of the pane empty.

This is a taste call — surface it rather than picking silently. Related: a column that absorbs *all*
slack puts hundreds of points of nothing between a label and its data.

## 7. Interaction latency is a layout problem too

**Gesture disambiguation.** A `TapGesture(count: 2)` anywhere in a subtree forces SwiftUI to hold
**every** single tap until the double-click window expires before it can know which gesture fired.
Measured on a real row: 366ms, 1076ms, once 2.9s — and worse when a periodic model refresh lands
inside that window. `simultaneousGesture` does **not** avoid it.

The fix is to take discrete-click semantics out of SwiftUI's gesture system. AppKit reports
`clickCount` on the event itself, so the second click is recognisable without the first having to
wait:

```swift
.onTapGesture { selected = row.id }          // the only gesture on the row
// … and, scoped to the surface's frame:
NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
    if event.clickCount == 2, /* inside frame */ { inspect(selected) }
    return event
}
```

Note the coordinate flip: `NSEvent.locationInWindow` is bottom-left, SwiftUI's `.global` space is
top-left.

**Selection must not animate.** Rows re-sort on every refresh; animating that is visible jank.

## 8. Measuring a running app without stealing focus

Pixels cannot measure latency (§1). Logs can.

1. Add a temporary `os.Logger` line to the handler under test.
2. Gate a synthetic-input probe behind an environment variable, and send the events **from inside
   the app** with `NSEvent.mouseEvent(...)` + `window.sendEvent(_:)`.
3. `log stream --style compact --predicate 'subsystem == "…"'` and read the deltas.
4. Strip the probe and the logger before reporting done.

What does **not** work, and why it matters:

- `CGEvent.postToPid` from another process does not reach SwiftUI's gesture recognisers at all. It
  looks like the fix failed when the harness failed.
- `screencapture` on an occluded window returns stale frames.

**A fix you cannot measure loses to one you can.** `DragGesture(minimumDistance: 0)` would also have
made selection immediate, but it does not fire for synthetic events, so it could not be verified —
the verifiable equivalent shipped instead.

## 9. Material cost is layer count

Covered in full by the `refractive-glass-layer-count-cost` memory; the parts that belong to design
judgement:

- Cost scales with the number of separately blended surfaces, **not** gradient area. One pane is one
  surface however many rows it holds; per-row material is never worth it in a dense view.
- Flatten **decoration** with `drawingGroup()`, never content — rasterising labels costs subpixel
  antialiasing to flatten layers that were never the expensive ones.
- Decoration keeps `.allowsHitTesting(false)` or the pane swallows every click.
- A window-root canvas belongs at the window root only. Nested, it repaints its ground *over* the
  content and adds a redundant display-linked pump.
- Measure presented frame cadence in a real window. `ImageRenderer` is blind to compositing cost.
