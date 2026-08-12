import SwiftUI

// MARK: - Refractive
//
// The fleet's shared Liquid Glass material. This file is duplicated verbatim
// into every personal app; change it here and re-copy rather than diverging.
//
// macOS draws the blur and the refraction. What it does not draw is the part
// that makes a panel read as a physical slab instead of a tinted rectangle:
//
//   1. A cut edge made of a specular core inside a bloom. A hairline that clips
//      toward white sits on the outermost edge on the side facing the light,
//      and a much wider, much dimmer halo of the same bearing spreads inward
//      from it and goes dark on the far side. A single stroke of uniform width
//      is a drawn outline: there is no thickness to it and nothing for the
//      light to sit inside. Real speculars are tiny and clip, with a bloom
//      around them; a broad even rim at half brightness reads as paint. A
//      fainter stroke inside both is the inner wall, which is what gives the
//      edge apparent thickness.
//   2. Nothing painted across the face. No specular wash, no sheen: those are
//      what make a surface read as lit-from-outside rather than as glass.
//   3. An interior that falls off, vertically: light along the top, dark
//      pooling at the bottom. Vertical and gentle — the moment a face gradient
//      follows the light instead of gravity it stops being a falloff and
//      becomes a diagonal stripe drawn across the element.
//   4. Two shadows, thrown away from the light. A tight contact shadow says the
//      slab rests above something; the wide ambient one says how far above.
//
// All four take their direction from one key light, and the pointer is where it
// hangs. Every surface solves it independently — a panel to the left of the
// cursor is lit from its right, one below is lit from its top — so the cursor
// reads as a focal point the whole window is arranged around, which is the
// closest honest analogue a Mac has to the iPhone's gyroscope.
//
// What keeps that from being a disco is not clamping the angle. It is that the
// light has a *height*, and a surface reports how obliquely it is being struck
// as well as from where. Directly under the light a surface is lit from straight
// overhead: no direction to show, so its rim goes even and its shadow drops
// straight down. Further away the light grazes, and the bright/dark split opens
// up. Both terms move together and continuously, which fixes the two things a
// clamped angle got wrong: neighbouring tiles straddling the cursor no longer
// disagree by 180° in any way you can see — they meet at zero strength, where
// there is no direction left to disagree about — and the response no longer
// saturates, so sliding the mouse a quarter of the way across moves the
// highlight a quarter of the way instead of nothing and then everything.
//
// Every highlight is paired with a shadow, so the material gains dimension
// without gaining brightness. Light appearance uses the same geometry with the
// bright face pulled down and the dark face made much softer, because a
// near-black chamfer on a white window reads as a drawn border, not an edge.

enum Refractive {
    // MARK: Core and bloom
    //
    // Picked from a five-way comparison harness rather than guessed at. The
    // measurements below are the harness's, at Market's real pane aspect ratios
    // (6.5 / 3.2 / 6.4 against Market's 6.6 / 3.2 / 6.6) and at roughly Market's
    // real pane sizes, so its pixels transfer to points about one-to-one.
    //
    // The harness draws the bloom as one wide ring under `blur(1.5px)`. A blur is
    // an offscreen filter pass, and putting one on a layer the pointer changes is
    // the whole reason this material felt heavy to move a mouse across — it is the
    // same fault as the 14pt shadow that used to sit above these overlays. What is
    // reproduced here is the blur's *result*, not the blur: a gaussian across a
    // band is separable, and the component along the arc is already available as
    // gradient stop locations while the component across the band is a radial ramp,
    // which concentric strokes give exactly. No filter, no offscreen pass, four
    // vector strokes of a shape that was being stroked once anyway.

    /// The specular core: the hairline that clips toward white. Narrow on
    /// purpose — its brightness is what makes it read as a catch rather than a
    /// border, and brightness at this alpha over any real width reads as paint.
    static let coreWidth: CGFloat = 0.9
    static let insetCoreWidth: CGFloat = 0.7

    /// How far the core's lobe runs before it is gone, as a fraction of a turn,
    /// on a shape whose `lobe` is 1. About a seventh of the rim's own lobe: the
    /// core is a glint sitting inside the halo, not a second rim.
    static let coreNear: CGFloat = 13.0 / 360
    static let coreOut: CGFloat = 33.8 / 360

    /// Depth of the bloom, in points. The tile's is shallower for the same reason
    /// its band is: it is the thin pane, and the depth of the halo is part of what
    /// says how much material the light is travelling through.
    static let bloomDepth: CGFloat = 5.1
    static let insetBloomDepth: CGFloat = 3.4

    /// What the bloom keeps of the rim's full strength. The halo is meant to be
    /// well under the core — a bloom as bright as its source is a fat rim, which
    /// is the treatment this replaces.
    static let bloomPeak: Double = 0.385

    /// The bloom's radial profile: three concentric passes, given as where each
    /// starts and how far it runs as fractions of `bloomDepth`, plus its share of
    /// the ramp. They stack to a tent — soft at the outer boundary, full through
    /// the middle, soft again where it meets the material — which is the shape a
    /// blur leaves across a band and the reason the halo has no visible edge of
    /// its own to give it away as a stroke.
    static let bloomRamp: [(start: CGFloat, run: CGFloat, weight: Double)] = [
        (0.00, 1.00, 0.30),
        (0.22, 0.57, 0.38),
        (0.39, 0.22, 0.32),
    ]

    /// Cool white. The glass separates from a neutral-charcoal ground by
    /// temperature rather than by brightness, keeping the canvas visually quiet.
    static let rimTint = Color(red: 0.894, green: 0.973, blue: 1.0)
    static let fillTint = Color(red: 0.722, green: 0.871, blue: 0.933)

    /// The shadow face of a cut edge, warm rather than neutral. Thick glass
    /// disperses: the lit face throws its light cool and what reaches the far
    /// face has lost the blue end. Two faces at the same temperature read as a
    /// drawn outline; two at different temperatures read as one solid thing.
    static let shadowTint = Color(red: 0.129, green: 0.078, blue: 0.055)

    /// The ground a slab sits on. Neutral charcoal with a single overhead glow —
    /// no colour field, because colour in the canvas fights the content.
    static let canvasDark = Color(red: 0.090, green: 0.098, blue: 0.110)
    static let canvasGlow = Color(red: 0.588, green: 0.784, blue: 0.863)

    /// Where the key hangs when the pointer is elsewhere, in window units:
    /// above the top edge and left of centre, which is where the fixed key
    /// always pointed. It sits outside the window because it is meant to be a
    /// long way off.
    static let restAnchor = UnitPoint(x: 0.28, y: -0.55)

    /// How far above the pointer the key actually hangs, as a fraction of the
    /// window's height. The lamp is on the wall, not lying in the glass: without
    /// this, panels above the cursor would be lit from underneath.
    ///
    /// Evening out how far each pane's highlight travels is `Lighting.rimAngle`'s
    /// job, not this one. Holding every bearing near vertical was the workaround
    /// for that, and it worked by suppressing the response it was trying to
    /// equalise.
    ///
    /// What this one sets is how *much* the highlight travels, and it is the
    /// difference between a glint that glides and one that appears to switch. The
    /// height fixes the ratio `dx/|dy|`, and the highlight's position along a
    /// pane's own top edge is `0.5 + dx/2|dy|` — so a low key lets that ratio swing
    /// far past ±1 and throws the highlight clean off the edge it was lit on.
    ///
    /// Measured on Market's Overview, sweeping the pointer across the window at
    /// 0.45: the highlight travelled 196–344% of each pane's own top edge and sat
    /// off that edge entirely in 43 of 68 sampled positions. Nothing visible, then
    /// the glint crosses the whole pane within about two hundred points of pointer
    /// travel, then nothing again — read as a threshold, which is exactly the
    /// complaint. The motion was never stepped; the samples are evenly spaced to
    /// well under a percent at every height. It was off-screen for two thirds of
    /// the range.
    ///
    /// At 1.4 the same sweep travels 54–61% per pane and leaves the edge twice out
    /// of 68, which is the ~51% the approved proof-of-concept measured. Raising it
    /// further keeps shrinking the travel — 31% at 2.4, 18% at 4.0 — back toward
    /// the inert rim this feature exists to replace.
    static let keyLift: CGFloat = 1.4

    /// Weight of the fixed up-and-left key that every surface adds to whatever
    /// the pointer contributes — in multiples of the *surface's* own diagonal, not
    /// the window's. This is what makes the panes read as one family rather than as
    /// a scatter: they all carry the same base direction and the cursor only bends
    /// it. Raising it makes the whole effect subtler; at zero the pointer is the
    /// only term and panes near it swing violently for no visible reason.
    ///
    /// It used to be a multiple of the window, and that quietly starved the small
    /// surfaces. The pointer's contribution is the same number of points for every
    /// pane, so against one fixed window-sized key it is a far smaller share of a
    /// small pane's total direction than of a large one's — the tiles were handed
    /// less leverage purely for being small. Measured against the pane instead, a
    /// KPI tile's highlight travel rose about 28% with nothing else changed.
    static let houseBias: CGFloat = 0.5

    /// The shadow offset every surface uses, taken from the house key rather than
    /// from that surface's own lighting.
    ///
    /// Shadows used to lean with the pointer. It is a real cue and it is cheap to
    /// describe and expensive to draw: making the offset depend on the light puts
    /// two gaussian blurs per pane into the per-event path, which is most of what
    /// made the window feel heavy to move a mouse across. The rim carries the
    /// direction of the key well enough on its own; the shadow only has to agree
    /// with it, and a fixed lean does agree with it, because the house key is the
    /// term every surface shares.
    static func settledShadow(_ drop: CGFloat) -> CGSize {
        Lighting.resting.shadowOffset(drop)
    }

    // MARK: What bounds the work
    //
    // One accepted pointer event repaints every surface in the window, and the
    // measured cost of that is not small. Rasterising Market's window offscreen —
    // 1800×1130 at 2×, twelve slabs each holding a tile:
    //
    //     plain rounded rectangles              2.2 ms
    //     the same panes under .glassEffect     2.7 ms
    //     the full material                     9.5 ms
    //     the canvas ground with its glow       2.8 ms
    //
    // so about 12 ms of drawing per event, of which the material's own overlays
    // are roughly 7 ms and the core and bloom about 4 ms of that. The overlays
    // are what the treatment *is*, and rasterising offscreen is not the same path
    // the compositor takes, so those are not numbers to tune the look against.
    // What they do establish is that a stream of events arriving faster than the
    // window can service them has no chance of catching up, and that the two
    // things worth bounding are how often the work runs and how much of it is
    // spent on a cue nobody can see.

    /// How far the light must actually move before the panes are asked to redraw.
    ///
    /// `onContinuousHover` fires far faster than anything here needs to change,
    /// and the damper keeps producing ever smaller steps as it converges, so the
    /// tail of every gesture is a run of callbacks that each repaint every pane in
    /// the window to move a highlight by a fraction of a pixel.
    ///
    /// The pointer travels the window's width to move a highlight ~55% of its own
    /// pane's edge, so a point of light movement is worth about 0.03% of an edge —
    /// a third of a point on a full-width panel, and less on anything smaller. Two
    /// points of light travel is therefore still under a pixel of highlight travel
    /// on the largest surface in the fleet: below what a display can show, let
    /// alone what the eye can follow. It was 0.5, which bought sub-pixel accuracy
    /// nobody can see at the price of repainting the window to get it.
    static let keyMinStep: CGFloat = 2.0

    /// How often the light is advanced, and the only clock in this file.
    ///
    /// Rate-limiting the *event stream* was the wrong lever, and measuring it is
    /// what showed that. Gating on elapsed-since-last-event assumes hover events
    /// arrive periodically; they do not. The window server coalesces and bursts
    /// them, so an event-time gate inherits that jitter and hands it straight to
    /// the compositor. Modelled against this display's 120 Hz vsync with a
    /// realistically irregular 120 Hz stream, the share of updates presented on a
    /// different frame gap than their neighbours was:
    ///
    ///     gate 1/75  ->  28% uneven      (1, 2 and 3-frame gaps)
    ///     gate 1/60  ->  31% uneven
    ///     gate 1/40  ->  50% uneven
    ///     display-locked pump -> 0%      (every update exactly 2 frames apart)
    ///
    /// No gate value fixes it, because the defect is not how many updates there
    /// are but that their timing comes from the pointer instead of the screen.
    /// Roughly a third of them landing a frame early or late is seen as motion
    /// that stutters while never actually falling behind — which is the report
    /// this replaced: jerky rather than laggy, worst on a fast lateral sweep,
    /// where the light covers the most ground per frame and an uneven gap is
    /// therefore the most visible.
    ///
    /// So the pointer no longer decides when anything is drawn. Events write a
    /// target; `TimelineView(.animation)` advances the light on the render loop's
    /// own clock, which is phase-locked to the display by construction.
    ///
    /// 60 rather than 120 because the material cannot make a 120 Hz frame: it
    /// measured about 12 ms of drawing per update at Market's window size against
    /// an 8.3 ms budget, and asking for frames that cannot be finished is another
    /// way to arrive at an uneven cadence. 60 Hz is an exact half of this
    /// display's refresh — so every update is presented exactly two vsyncs after
    /// the last — and leaves 16.7 ms for work that needs about 12.
    static let pumpInterval: Double = 1.0 / 60

    /// How far the pointer must move before the background glow is re-aimed.
    ///
    /// The glow is a window-sized elliptical gradient, and re-centring it repaints
    /// the whole window: 2.8 ms of the ~12 ms an event costs, about a quarter of
    /// the budget, for something drawn at 0.053 opacity that follows the pointer at
    /// less than a third of its speed. Quantising it to 24 points of pointer travel
    /// moves it in steps of under seven points — far below what a soft patch at
    /// that opacity can show — and takes it out of the per-event path entirely,
    /// because an unchanged centre makes the background subtree compare equal and
    /// nothing redraws it.
    static let glowStep: CGFloat = 24

    /// The time constant of the damper, in seconds: how long the light takes to
    /// cover about two thirds of the distance to the cursor.
    ///
    /// It has to be a *time*, not a fraction per event. Moving a fixed share of the
    /// way on each `onContinuousHover` callback makes the light's speed a function
    /// of how many callbacks arrive, and that is a property of how busy the app is,
    /// not of anything the user did. Measured in Market: with the cursor parked at
    /// one position, reaching it by 48 small moves rather than one large one left
    /// the panels differing by up to 14 luminance levels, while moving the cursor
    /// 800 points across the window changed them by at most 5. The lighting was
    /// three times more sensitive to the event count than to the pointer. A busy
    /// window starves the stream, so the light crawls and lands wherever the stream
    /// happened to stop — which is the "it jumps at a threshold" reading, and the
    /// lag in the heavier apps. Both are the same bug.
    static let keyTau: Double = 0.06

    /// The largest step the damper may take on one callback. After a long stall the
    /// elapsed time is huge and the exponential would resolve to "jump the whole
    /// way", turning the first frame back into a snap.
    static let keyMaxStep: CGFloat = 0.5

    /// The furthest the light is allowed to fall behind the cursor, as a fraction
    /// of the window's long edge. The damper alone assumes a continuous stream of
    /// small moves; a pointer that arrives somewhere by teleport — window
    /// switching, a trackpad flick — would otherwise leave the light stranded a
    /// long way off, and the lighting would no longer be about where the cursor is.
    static let keyMaxLag: CGFloat = 0.16

    /// The much gentler pull on the background glow. The glow is a soft patch a
    /// window wide; throwing it as hard as the key would fling it off-screen and
    /// the highlights would stop having anything to be a reflection of.
    static let pointerPull: CGFloat = 0.28
}

// MARK: - The light

/// Where the light is, in root coordinates, and how big the room is. `span` is
/// zero until a canvas publishes one; surfaces fall back to a fixed top-left
/// vector in that case, so a view used outside a canvas still looks right.
struct RefractiveField: Equatable {
    var light: CGPoint = .zero
    var span: CGFloat = 0
}

private struct RefractiveFieldKey: EnvironmentKey {
    static let defaultValue = RefractiveField()
}

extension EnvironmentValues {
    var refractiveField: RefractiveField {
        get { self[RefractiveFieldKey.self] }
        set { self[RefractiveFieldKey.self] = newValue }
    }
}

/// How one surface is being lit: from which way, and how obliquely.
///
/// Each surface solves this for itself against a single shared light, so two
/// panels in the same window genuinely disagree about where the light is — which
/// is the point, since that disagreement is what makes the cursor read as a
/// focal point the window is arranged around rather than a global tilt applied
/// to everything at once.
///
/// The safeguard against that reading as a disco is `grazing`, not a clamp on
/// the angle. A clamp saturates: it does nothing across half the window and then
/// swings everything at once. Height does the job properly, because the same
/// geometry that makes two neighbours straddling the cursor point opposite ways
/// also puts both of them almost directly *under* the light, where there is no
/// obliquity left to render and the rim is even anyway. The contradiction cancels
/// itself out exactly where it would otherwise be visible.
private struct Lighting {
    /// Unit vector, in the window plane, from the surface toward the light.
    /// Y grows downward.
    var dx: CGFloat
    var dy: CGFloat

    /// How obliquely the light strikes: near its floor when the light is straight
    /// overhead, tending to 1 as it recedes across the window. Scales both the
    /// rim's bright/dark split and the shadow's throw, so a surface under the
    /// cursor is lit nearly head-on and one far from it is lit from the side.
    var grazing: CGFloat

    /// The angle the bright arc is actually drawn at on *this* shape — the
    /// light's bearing after it has been put through the shape's proportions.
    /// See `rimAngle(vx:vy:size:)`; it is not the same as `azimuth`, and the
    /// difference between the two is the whole reason some panes used to travel
    /// while others sat still.
    var rimAngle: Angle

    /// How wide to draw the bright lobe on *this* shape, as a fraction of the width
    /// it takes on a wide panel. See `lobe(for:)`.
    var lobe: CGFloat

    /// Obliquity a surface keeps even with the light directly above it. Not zero:
    /// a rim with no lit side at all stops looking like a cut edge, and the whole
    /// point of the modulation is that it never fully switches off.
    static let grazingFloor: CGFloat = 0.30

    /// What every surface falls back to when no canvas has published a light:
    /// the fixed up-and-left key, struck at the obliquity the old rest anchor
    /// used to produce, so a view outside a canvas is indistinguishable.
    ///
    /// Nearly overhead, leaning left, rather than the old hard up-and-left. The
    /// leftward component is what decides where the highlight *rests*, and at 0.6
    /// it rested on the top-left corner itself — measured at 9–12% along the top
    /// edge on every panel. A highlight already in the corner has nowhere to
    /// travel, which is the second reason panes looked inert: not that they were
    /// receiving no rotation, but that they were clamped against the corner while
    /// receiving it. Resting nearer a third of the way along leaves room to move
    /// in both directions and still reads as lit from the upper left.
    static let resting = Lighting(dx: -0.35, dy: -0.94, grazing: 0.85,
                                  rimAngle: .degrees(atan2(-0.94, -0.35) * 180 / .pi),
                                  lobe: 1)

    /// How high the key hangs above the window plane, in multiples of the
    /// window's long edge. This is the softness control: raising it widens the
    /// calm region around the cursor and gentles the whole range, lowering it
    /// makes every surface strongly directional and brings the disco back.
    ///
    /// It has to move with `Refractive.keyLift`, because both are distances to the
    /// same lamp: this one is the reference the reach is compared against, and
    /// raising the key without raising it makes every pane read as further away and
    /// therefore harder-lit. Tripling the key at 0.9 took mean grazing from 0.577 to
    /// 0.777 — the travel would have been fixed and the rim would have got harsher
    /// doing it. At 1.95 the mean lands back on 0.577, so the change is to where the
    /// highlight goes and not to how hard it looks.
    static let height: CGFloat = 1.95

    /// The light's bearing, in the convention SwiftUI's angular gradients use:
    /// zero at three o'clock, increasing clockwise, which is what `atan2` gives
    /// in a y-down space.
    var azimuth: Angle { .degrees(atan2(dy, dx) * 180 / .pi) }

    /// Where to put the bright arc so that it lands at the same place on every
    /// shape, whatever its proportions.
    ///
    /// An angular gradient's phase reaches the boundary through the shape's own
    /// geometry: on a wide, short panel the highlight sits at `x = -(h/2)·cot θ`
    /// along the top edge. That cotangent is why a rotation which walks the
    /// highlight a third of the way across a small tile moves it a few points on
    /// a panel eight times as wide — measured, both directions: with one bearing
    /// per shape the wide panels pinned their highlight near centre while the KPI
    /// tiles swung freely. Handing every shape the same bearing is therefore not
    /// one lighting condition; it only looks like one on shapes of equal aspect.
    ///
    /// Scaling the direction by the shape's own width and height cancels the
    /// cotangent exactly: the fraction along the edge falls out as
    /// `0.5 + dx / 2|dy|`, with no `w` or `h` left in it, so every surface places
    /// its highlight at the same fraction and moves it by the same fraction. The
    /// bearing differs per shape precisely so that the *result* does not — which
    /// is what "linked but different" has to mean once the panes are not all the
    /// same size.
    static func rimAngle(vx: CGFloat, vy: CGFloat, size: CGSize) -> Angle {
        .degrees(atan2(vy * size.height, vx * size.width) * 180 / .pi)
    }

    /// How wide the bright lobe should be on this shape, relative to a wide panel.
    ///
    /// Placing every highlight at the same fraction of its own edge is necessary but
    /// not sufficient, and on its own it produced the next complaint: the wide panels
    /// read well while the squarer cards and tiles looked like they were not moving
    /// at all. They were — by the same fraction of themselves — but a fraction of a
    /// small pane is few enough points to be invisible, and proportional equality was
    /// the wrong target.
    ///
    /// What actually decides whether a highlight reads as travelling is how its width
    /// compares to how far it can go. Differentiating `rimAngle` gives a sensitivity
    /// proportional to `w/h`, so angular sweep is governed by aspect ratio: measured
    /// across a full-width pointer sweep, a 5:1 panel turns about 118° while a 1.3:1
    /// tile turns about 60°. Against a lobe of fixed angular width — roughly 100°,
    /// baked into the gradient's stop locations — the panel's highlight is narrower
    /// than its travel and so genuinely arrives and leaves, while the tile's is wider
    /// than its entire range and can only brighten and dim in place. That is the
    /// difference between shimmering and sitting still, and no amount of extra
    /// rotation fixes it while the lobe stays wide.
    ///
    /// Scaling the lobe by the same `w/h` holds the ratio of travel to width constant,
    /// so a small pane shows a correspondingly tighter glint and reads as the same
    /// material catching the same light. The exponent is measured rather than chosen:
    /// at 0.5 the tiles overshot to a sweep-to-lobe ratio of 0.79 against the panel's
    /// 0.58 — catching harder than the panels, a new inconsistency — and 0.35 lands
    /// every shape between 0.57 and 0.65. The floor keeps a very tall pane, where
    /// `w/h` tends to zero, from losing its highlight altogether.
    static func lobe(for size: CGSize) -> CGFloat {
        guard size.height > 0 else { return 1 }
        return min(1, max(0.22, pow(size.width / size.height / 5, 0.35)))
    }

    /// A directional stop, blended toward the value the same stop takes when the
    /// light is straight overhead and the edge has no lit side. Every stop in
    /// every rim goes through here, which is what makes the transition continuous
    /// rather than a switch between two looks.
    func graze(_ full: Double, flat: Double) -> Double {
        flat + (full - flat) * Double(grazing)
    }

    /// Shadows fall away from the light, and always also downward — gravity
    /// reads even when the key does not. The lateral throw scales with obliquity
    /// for the same reason the rim does: a light overhead casts straight down.
    func shadowOffset(_ drop: CGFloat) -> CGSize {
        CGSize(width: -dx * drop * 0.5 * grazing,
               height: -dy * drop * 0.5 * grazing + drop * 0.7)
    }

    static func solve(surface: CGRect, field: RefractiveField) -> Lighting {
        guard field.span > 0, surface.width > 0 else { return resting }
        let ox = field.light.x - surface.midX
        let oy = field.light.y - surface.midY

        // The direction is the house key plus the pointer's contribution, not the
        // pointer alone. Two things follow, and both were wrong before. Panes
        // share a base direction, so they read as one lighting condition seen
        // from slightly different places rather than as independent decisions.
        // And there is no singularity: a pane the cursor sits directly on falls
        // back to the house key instead of spinning its rim through 360° for a
        // one-pixel mouse move, which is where the scattershot came from.
        let bias = hypot(surface.width, surface.height) * Refractive.houseBias
        let vx = ox + resting.dx * bias
        let vy = oy + resting.dy * bias
        let length = hypot(vx, vy)
        guard length > 0.5 else { return resting }

        // Obliquity is measured from the real light, not the biased direction:
        // how far this pane is from the cursor is the physical fact, and the bias
        // is only about which way the rim points.
        let reach = hypot(ox, oy)
        let oblique = reach / hypot(reach, field.span * height)
        return Lighting(dx: vx / length,
                        dy: vy / length,
                        grazing: grazingFloor + (1 - grazingFloor) * oblique,
                        rimAngle: rimAngle(vx: vx, vy: vy, size: surface.size),
                        lobe: lobe(for: surface.size))
    }
}

// MARK: - The rim

/// The cut edge, as an arc travelling around the shape rather than a ramp across
/// its bounding box.
///
/// This is the difference between a highlight that moves and one that pumps. A
/// `LinearGradient` is projected onto the bounding box, so the same few degrees
/// of rotation sweep the bright stop along the entire top edge of a wide panel
/// while doing almost nothing to a small tile. Measured on Market's Overview
/// while sweeping the pointer across the top of the window, that came to a 2.3×
/// swing in top-edge brightness on the full-width panels — reading as a pulse,
/// not a rotation, and saturating halfway across — against no measurable change
/// whatsoever on the KPI tiles, whose rims sat at an asymmetry of 3 out of 65 in
/// every position. How much a surface appeared to respond was decided by its
/// aspect ratio instead of by where it sat, which is what made a window full of
/// them look like independent decisions.
///
/// An angular gradient moves the bright arc by the same angle on every shape, so
/// each surface shows the same rim seen from its own bearing — different, and
/// visibly the same rule.
private func refractiveRim(light: Lighting,
                           bright: Color, carry: Color, fade: Color,
                           turn: Color, deep: Color) -> AngularGradient {
    // The stop locations *are* the lobe width, so they scale with the shape rather
    // than being fixed fractions of the ring. The shadow ramp keeps its own 50° of
    // run past the faint stop instead of scaling with it, so that a tight lobe on a
    // small tile still turns into shade gradually and does not become a hard edge.
    let carryAt = 0.10 * light.lobe
    let fadeAt = 0.28 * light.lobe
    let turnAt = fadeAt + 50.0 / 360
    return AngularGradient(
        stops: [.init(color: bright, location: 0.00),
                .init(color: carry, location: carryAt),
                .init(color: fade, location: fadeAt),
                .init(color: turn, location: turnAt),
                .init(color: deep, location: 0.50),
                .init(color: turn, location: 1 - turnAt),
                .init(color: fade, location: 1 - fadeAt),
                .init(color: carry, location: 1 - carryAt),
                .init(color: bright, location: 1.00)],
        center: .center,
        angle: light.rimAngle)
}

/// The specular core: a very tight arc on the same bearing as the rim, at an
/// alpha high enough to clip.
///
/// It is the same lamp seen twice. The bloom is the light the material scatters,
/// which is broad and dim and carries the rim's dark far side with it; this is
/// the light the edge reflects directly, which is narrow and bright and has no
/// far side at all — past its lobe it is simply gone, rather than turning into
/// shade. Drawing both is what separates a piece of glass catching a light from
/// an outline drawn at the brightness of one.
///
/// Its width scales with the shape's `lobe` for the same reason the rim's does:
/// a core of fixed angular width on a small tile is wider than the tile's entire
/// travel, so it can only brighten and dim in place.
///
/// Deliberately not put through `graze`. Obliquity opens the bright/dark split of
/// a cut edge, but a specular is *brightest* head-on — a pane directly under the
/// cursor should have the strongest glint and the least direction, and it is the
/// bloom underneath that goes even there.
private func refractiveCore(light: Lighting, peak: Color) -> AngularGradient {
    let near = Double(Refractive.coreNear * light.lobe)
    let out = Double(Refractive.coreOut * light.lobe)
    return AngularGradient(
        stops: [.init(color: peak, location: 0.00),
                .init(color: peak.opacity(0.35), location: near),
                .init(color: peak.opacity(0), location: out),
                .init(color: peak.opacity(0), location: 1 - out),
                .init(color: peak.opacity(0.35), location: 1 - near),
                .init(color: peak, location: 1.00)],
        center: .center,
        angle: light.rimAngle)
}

/// The caustic: the bright patch light throws against the wall *opposite* the one
/// it entered by, sitting just inside the material.
///
/// This used to be one band carrying two cues — light conducted along the lit
/// edge, and the caustic on the far side. The bloom now does the first one, and
/// properly: it is the same phenomenon at the same place, so running both put two
/// concentric bright rings on the lit edge with a dark gap between them. Measured
/// on the panel's top edge, the band's ceiling came out at luminance 58 against
/// the bloom's own peak of 37, with the ramp dipping to 15 between them — the
/// dimmer of the two cues was drawing the brighter ring. The lit half is deleted
/// here rather than balanced, because balancing two layers that describe one
/// thing only hides the double-count.
///
/// What is left is the half the bloom genuinely does not provide. The bloom's far
/// side is the shadow face, which is a dark cue; this is a bright one, and glass
/// has both — that a thing is dark where the light does not reach and bright
/// again where the light comes out the other side is most of what separates a
/// solid from a pane.
///
/// Its depth is in points, not in fractions of the shape — 1.6% of the height is
/// three pixels on a tall panel and less than one on a 50-point tile, so a
/// fractional cue vanishes exactly where a small tile needs it most. Fixed depth
/// is what lets a tile and a panel read as the same material at two sizes.
private func refractiveCaustic(light: Lighting, caustic: Color) -> AngularGradient {
    // Scaled with the shape like the cut is. Left at a fixed width it would be the
    // widest bright thing on a small pane's edge once the rim's own lobe tightened,
    // and the pane would go back to washing rather than catching.
    let falloff = 0.26 * light.lobe
    let gone = caustic.opacity(0)
    return AngularGradient(
        stops: [.init(color: gone, location: 0.00),
                .init(color: gone, location: falloff),
                .init(color: caustic, location: 0.50),
                .init(color: gone, location: 1 - falloff),
                .init(color: gone, location: 1.00)],
        center: .center,
        angle: light.rimAngle)
}

// MARK: - Slab

/// Holds the newest frame a moving surface has reported, so the surface can be
/// relit once when it stops instead of on every frame it travels.
///
/// A reference type on purpose: writing the pending frame must not invalidate
/// the view. The whole point is that a moving surface does no SwiftUI work at
/// all, and a `@State` value would defeat that by re-evaluating the body sixty
/// times a second to store a rectangle nothing is allowed to draw yet.
private final class SettleClock {
    var pending: CGRect = .zero
    var scheduled = false
}

private struct RefractiveSlab: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.refractiveField) private var field
    @State private var surface: CGRect = .zero
    @State private var clock = SettleClock()
    let radius: CGFloat

    private var light: Lighting { .solve(surface: surface, field: field) }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    /// One pass of the bloom: bright face, fade, dark face, at this pass's share
    /// of the ramp. Each stop is pulled toward the even rim it becomes when the
    /// light is overhead, by how squarely this particular panel is facing it.
    private func bloomEdge(_ weight: Double) -> AngularGradient {
        let dark = scheme == .dark
        let w = weight * Refractive.bloomPeak
        return refractiveRim(
            light: light,
            bright: dark ? Refractive.rimTint.opacity(light.graze(0.54, flat: 0.24) * w)
                         : Color.white.opacity(light.graze(0.88, flat: 0.46) * w),
            carry: dark ? Refractive.rimTint.opacity(light.graze(0.20, flat: 0.19) * w)
                        : Color.white.opacity(light.graze(0.42, flat: 0.38) * w),
            fade: Refractive.fillTint.opacity(0.04 * w),
            turn: dark ? Refractive.shadowTint.opacity(light.graze(0.30, flat: 0.10) * w)
                       : Refractive.shadowTint.opacity(light.graze(0.09, flat: 0.03) * w),
            deep: dark ? Refractive.shadowTint.opacity(light.graze(0.62, flat: 0.14) * w)
                       : Refractive.shadowTint.opacity(light.graze(0.20, flat: 0.05) * w))
    }

    /// One concentric stroke of the bloom. Three of these stack into the radial
    /// ramp described by `Refractive.bloomRamp`.
    private func bloomPass(_ index: Int) -> some View {
        let pass = Refractive.bloomRamp[index]
        return shape.inset(by: Refractive.bloomDepth * pass.start)
            .strokeBorder(bloomEdge(pass.weight),
                          lineWidth: Refractive.bloomDepth * pass.run)
            .allowsHitTesting(false)
    }

    /// The glint itself. White rather than the rim's cool white: a specular that
    /// is clipping has lost its tint by definition, and it is the bloom around it
    /// that carries the material's temperature.
    private var specularCore: AngularGradient {
        refractiveCore(light: light,
                       peak: Color.white.opacity(scheme == .dark ? 0.95 : 0.75))
    }

    // There is deliberately no specular wash on the face.
    //
    // An `EllipticalGradient` is sized to the shape's bounding box, so on a
    // wide, short panel it stretches until its falloff iso-lines are, for
    // practical purposes, straight diagonal lines drawn across the surface.
    // That is what put a hard light-shaft through every row — and it is not a
    // tuning problem, because any elliptical highlight degenerates the same way
    // once the aspect ratio gets far from square. Glass does not need it: the
    // rim carries the direction of the light, and the material behind carries
    // the refraction.

    /// Light pooling at the top, and the bottom going darker than the middle.
    ///
    /// Deliberately vertical, and *not* aligned to the key. Running this along
    /// the light axis turns a falloff you feel into a diagonal band you see —
    /// a stripe across the face of every panel. Gravity is vertical whatever
    /// the light is doing, and the direction of the key is already carried by
    /// the rim stroke, where an edge can hold it without smearing it across
    /// the surface.
    /// The far wall of the pane shading its own floor. Broad, gentle, vertical,
    /// and clear through the middle two thirds — the sharp edge cues are the
    /// bands' job, not this one's.
    private var interior: LinearGradient {
        let floor = scheme == .dark
            ? Color.black.opacity(0.22)
            : Color.black.opacity(0.05)
        return LinearGradient(
            stops: [.init(color: .clear, location: 0.00),
                    .init(color: .clear, location: 0.62),
                    .init(color: floor, location: 1.00)],
            startPoint: .top, endPoint: .bottom)
    }

    private var caustic: AngularGradient {
        let dark = scheme == .dark
        return refractiveCaustic(
            light: light,
            caustic: dark ? Refractive.rimTint.opacity(light.graze(0.09, flat: 0.06))
                          : Color.white.opacity(light.graze(0.17, flat: 0.11)))
    }

    /// Depth of that caustic, in points. Deeper than the tile's: this is the thick
    /// pane, and how far the light gets into it is what says so.
    /// Every cue the light controls, flattened into one layer.
    ///
    /// These were seven successive `.overlay`s. Same drawing, but as seven live
    /// CALayers the compositor had to blend separately on every frame the light
    /// moved — and measured on a real window rather than offscreen, that is what
    /// the material could not afford. A window holding just two glass surfaces
    /// ran at 29 Hz against a 60 Hz pump, presenting 83% of its frames two vsyncs
    /// late; the same window with the bloom removed ran at 59 Hz, 99% even. The
    /// cost scaled with the number of blended layers, not with gradient area:
    /// dropping to one bloom pass bought 41 Hz, while keeping all three and
    /// flattening them here bought 59.
    ///
    /// `drawingGroup()` renders the subtree once into an offscreen Metal texture,
    /// so the frame composites one layer instead of seven. It is deliberately
    /// wrapped around the decoration alone and not around the pane: pulling the
    /// content in too would rasterise the text with it and cost subpixel
    /// antialiasing on every label in the fleet, to flatten layers that are not
    /// the expensive ones.
    private var decoration: some View {
        ZStack {
            shape.fill(interior)
            // Both of these used to start at `Refractive.edge`, which was correct
            // while the edge was a 1.1pt stroke and wrong the moment the bloom
            // took over the outer 5.1pt: they lay across the middle of the halo
            // and flattened it. Measured on the panel's top edge, the ramp came
            // out as a plateau at luminance ~70 through 1-3.5pt and then a step
            // to 19 at 4pt - where the band ended, not where the bloom does. A
            // step inside the halo is a visible stroke boundary, which is the one
            // thing the tent exists to remove.
            shape.inset(by: Refractive.bloomDepth)
                .strokeBorder(caustic, lineWidth: causticDepth)
            shape.inset(by: Refractive.bloomDepth)
                .strokeBorder(innerWall, lineWidth: 1)
            bloomPass(0)
            bloomPass(1)
            bloomPass(2)
            shape.strokeBorder(specularCore, lineWidth: Refractive.coreWidth)
        }
        .drawingGroup()
        .allowsHitTesting(false)
    }

    private let causticDepth: CGFloat = 3

    /// Inner wall — the second face of the chamfer, one pixel in from the cut.
    /// It is the whole reason the edge has apparent thickness, so it carries a
    /// little more weight than a hairline, but it must stay well under the cut
    /// edge itself or it reads as a second border.
    private var innerWall: Color {
        scheme == .dark
            ? Refractive.rimTint.opacity(0.085)
            : Color.white.opacity(0.34)
    }

    private var contactShadow: Color {
        scheme == .dark ? Color.black.opacity(0.50) : Color.black.opacity(0.13)
    }

    private var ambientShadow: Color {
        scheme == .dark ? Color.black.opacity(0.42) : Color.black.opacity(0.10)
    }

    func body(content: Content) -> some View {
        content
            .glassEffect(.regular, in: .rect(cornerRadius: radius))
            // The slab's own silhouette casts the shadow, and every decoration
            // below is drawn inside that silhouette, so casting it here rather
            // than after the overlays produces the identical shadow — while
            // keeping the blur out of the path of anything the pointer changes.
            // Left where it was, a pointer move re-rasterised each pane and
            // re-blurred it at 14pt, once per hover callback.
            .compositingGroup()
            .shadow(color: contactShadow, radius: 3,
                    x: Refractive.settledShadow(3).width,
                    y: Refractive.settledShadow(3).height)
            .shadow(color: ambientShadow, radius: 14,
                    x: Refractive.settledShadow(9).width,
                    y: Refractive.settledShadow(9).height)
            .overlay(decoration)
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .global)
            } action: { rect in
                // A resize is always a relight, and immediately: `lobe` and
                // `rimAngle` are both functions of the shape, so a stale one is
                // wrong about the surface itself rather than merely about where
                // it is. The first layout arrives here too, as a size change
                // from zero.
                guard rect.size == surface.size, surface != .zero else {
                    surface = rect
                    return
                }

                // A move is held until it stops. Relighting a surface while it
                // travels is the single most expensive thing this file does —
                // measured on Market's positions screen, six seconds of
                // scrolling spent 3.1 s of main-thread time with the relight in
                // and 1.5 s with it out, because each of the ~14 panels on
                // screen re-solved its lighting and re-rasterised its seven
                // decoration layers on every frame it moved.
                //
                // Quantising the move was tried first and does not work. The
                // cost is not dominated by the number of relights: raising the
                // bar until the highlight visibly stepped, 32 px of travel per
                // update, still only fell from 2.9 s to 2.2 s. Holding is the
                // only lever with the whole 1.5 s behind it.
                //
                // Holding is also the better-looking of the two. A held surface
                // keeps the lighting it had, which means the highlight travels
                // *with* the panel — perfectly smoothly, since a panel whose
                // drawing has not changed is a translation for the compositor —
                // and is corrected once when the scroll comes to rest. Stepping
                // the light instead puts a stutter on the one thing that is
                // moving smoothly, which is the defect `pumpInterval` exists to
                // avoid.
                clock.pending = rect
                guard !clock.scheduled else { return }
                clock.scheduled = true
                Task { @MainActor in
                    // Poll rather than restart a timer per frame: the settle is
                    // a property of when the frames *stop*, and re-arming on
                    // every one of them puts an allocation back in the path this
                    // exists to empty.
                    var last: CGRect
                    repeat {
                        last = clock.pending
                        try? await Task.sleep(for: .milliseconds(90))
                    } while clock.pending != last
                    clock.scheduled = false
                    surface = clock.pending
                }
            }
    }
}

// MARK: - Inset

/// A tile living *inside* a slab. Real glass, not a painted rectangle: the tile
/// runs its own `.glassEffect` so macOS refracts what is behind it, exactly as
/// the slab does. What separates the two is depth of material, not medium — the
/// tile is `.clear` (a thin pane, ~8px of blur in the comparator) against the
/// slab's `.regular` (a thick one, ~46px). A tile that only paints a fill and a
/// border reads as fake glass because its sides and floor have nothing behind
/// them to bend.
private struct RefractiveInset: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.refractiveField) private var field
    @State private var surface: CGRect = .zero
    @State private var clock = SettleClock()
    let radius: CGFloat

    private var light: Lighting { .solve(surface: surface, field: field) }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    /// The same core and bloom as the slab, at tile scale: lit on the side facing
    /// the light, turning dark on the far side. A single uniform border is what
    /// made the sides read flat — an edge has to say which way the light came
    /// from, and it has to have somewhere for the light to sit.
    private func bloomEdge(_ weight: Double) -> AngularGradient {
        let dark = scheme == .dark
        let w = weight * Refractive.bloomPeak
        return refractiveRim(
            light: light,
            bright: dark ? Refractive.rimTint.opacity(light.graze(0.34, flat: 0.17) * w)
                         : Color.white.opacity(light.graze(0.80, flat: 0.42) * w),
            carry: dark ? Refractive.rimTint.opacity(light.graze(0.14, flat: 0.13) * w)
                        : Color.white.opacity(light.graze(0.38, flat: 0.34) * w),
            fade: Refractive.fillTint.opacity(0.03 * w),
            turn: dark ? Refractive.shadowTint.opacity(light.graze(0.24, flat: 0.08) * w)
                       : Refractive.shadowTint.opacity(light.graze(0.07, flat: 0.025) * w),
            deep: dark ? Refractive.shadowTint.opacity(light.graze(0.52, flat: 0.12) * w)
                       : Refractive.shadowTint.opacity(light.graze(0.17, flat: 0.04) * w))
    }

    private func bloomPass(_ index: Int) -> some View {
        let pass = Refractive.bloomRamp[index]
        return shape.inset(by: Refractive.insetBloomDepth * pass.start)
            .strokeBorder(bloomEdge(pass.weight),
                          lineWidth: Refractive.insetBloomDepth * pass.run)
            .allowsHitTesting(false)
    }

    /// Dimmer than the slab's for the same reason every other cue here is: this
    /// is the thin pane. Still bright enough to clip, because a specular that
    /// does not clip is just a highlight.
    private var specularCore: AngularGradient {
        refractiveCore(light: light,
                       peak: Color.white.opacity(scheme == .dark ? 0.72 : 0.60))
    }

    /// The far wall shading the tile's own floor, and all the painting a tile
    /// gets across its face. The side walls, the second specular and the rest of
    /// it were an attempt to draw glass on top of glass; `.clear` already refracts
    /// what is behind it, and every extra layer over that made it look more
    /// painted, not more real.
    private var interior: LinearGradient {
        let floor = scheme == .dark
            ? Color.black.opacity(0.18)
            : Color.black.opacity(0.04)
        return LinearGradient(
            stops: [.init(color: .clear, location: 0.00),
                    .init(color: .clear, location: 0.60),
                    .init(color: floor, location: 1.00)],
            startPoint: .top, endPoint: .bottom)
    }

    /// Shallower than the slab's, because this is the thin pane. Same cue, same
    /// fixed scale, same bearing, so a tile inside a card reads as the same glass
    /// under the same light — and now responds to the light as much as the card
    /// does. Measured before this, the tiles' rims varied by 4 luminance levels
    /// across the whole sweep against the panels' 105: they were inert, and being
    /// inert next to something that moves is what made the window look scattered.
    private var caustic: AngularGradient {
        let dark = scheme == .dark
        return refractiveCaustic(
            light: light,
            caustic: dark ? Refractive.rimTint.opacity(light.graze(0.085, flat: 0.055))
                          : Color.white.opacity(light.graze(0.15, flat: 0.10)))
    }

    /// The inset's own flattened decoration — see the slab's for why. Tiles are
    /// the numerous surface in every app in the fleet, so the layer count that
    /// matters most is this one's.
    private var decoration: some View {
        ZStack {
            shape.fill(interior)
            shape.inset(by: Refractive.insetBloomDepth)
                .strokeBorder(caustic, lineWidth: causticDepth)
            shape.inset(by: Refractive.insetBloomDepth)
                .strokeBorder(innerWall, lineWidth: 0.5)
            bloomPass(0)
            bloomPass(1)
            bloomPass(2)
            shape.strokeBorder(specularCore, lineWidth: Refractive.insetCoreWidth)
        }
        .drawingGroup()
        .allowsHitTesting(false)
    }

    private let causticDepth: CGFloat = 2

    /// One point in from the border: the far side of the chamfer. A single
    /// stroke reads as a drawn outline; a stroke with a wall behind it reads as
    /// an edge that has depth to it.
    private var innerWall: Color {
        scheme == .dark ? Refractive.rimTint.opacity(0.055) : Color.white.opacity(0.26)
    }

    func body(content: Content) -> some View {
        content
            .glassEffect(.clear, in: .rect(cornerRadius: radius))
            .compositingGroup()
            .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.09), radius: 2,
                    x: Refractive.settledShadow(1.5).width,
                    y: Refractive.settledShadow(1.5).height)
            .overlay(decoration)
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .global)
            } action: { rect in
                // A resize is always a relight, and immediately: `lobe` and
                // `rimAngle` are both functions of the shape, so a stale one is
                // wrong about the surface itself rather than merely about where
                // it is. The first layout arrives here too, as a size change
                // from zero.
                guard rect.size == surface.size, surface != .zero else {
                    surface = rect
                    return
                }

                // A move is held until it stops. Relighting a surface while it
                // travels is the single most expensive thing this file does —
                // measured on Market's positions screen, six seconds of
                // scrolling spent 3.1 s of main-thread time with the relight in
                // and 1.5 s with it out, because each of the ~14 panels on
                // screen re-solved its lighting and re-rasterised its seven
                // decoration layers on every frame it moved.
                //
                // Quantising the move was tried first and does not work. The
                // cost is not dominated by the number of relights: raising the
                // bar until the highlight visibly stepped, 32 px of travel per
                // update, still only fell from 2.9 s to 2.2 s. Holding is the
                // only lever with the whole 1.5 s behind it.
                //
                // Holding is also the better-looking of the two. A held surface
                // keeps the lighting it had, which means the highlight travels
                // *with* the panel — perfectly smoothly, since a panel whose
                // drawing has not changed is a translation for the compositor —
                // and is corrected once when the scroll comes to rest. Stepping
                // the light instead puts a stutter on the one thing that is
                // moving smoothly, which is the defect `pumpInterval` exists to
                // avoid.
                clock.pending = rect
                guard !clock.scheduled else { return }
                clock.scheduled = true
                Task { @MainActor in
                    // Poll rather than restart a timer per frame: the settle is
                    // a property of when the frames *stop*, and re-arming on
                    // every one of them puts an allocation back in the path this
                    // exists to empty.
                    var last: CGRect
                    repeat {
                        last = clock.pending
                        try? await Task.sleep(for: .milliseconds(90))
                    } while clock.pending != last
                    clock.scheduled = false
                    surface = clock.pending
                }
            }
    }
}

// MARK: - Canvas

/// The ground every slab sits on, and the thing that owns the light. In dark
/// appearance this is neutral charcoal with a single overhead glow — the cool
/// separation lives in the material, not in the background, which is why the
/// canvas can afford to carry no additional colour field. In light appearance the
/// system window background already does that job, but the light still hangs here.
/// Everything the light is currently doing.
///
/// A plain class, deliberately: the hover stream writes to it and those writes
/// must invalidate nothing. Arrival time no longer decides when anything is
/// drawn — the display clock is the only thing that reads this into the view
/// tree, so a pointer event costs one property store and stops there.
private final class Lamp {
    /// The damped light — what the panes are actually lit by.
    var current: CGPoint?
    /// The raw cursor, the thing `current` is chasing.
    var target: CGPoint?
    /// When `current` last actually moved. Not when the last tick happened: a
    /// tick that declines to move the light must leave the interval unspent, or
    /// the damper converges to a step under `keyMinStep` and the light freezes
    /// short of the cursor forever.
    var tick: Date?
    /// Where the background glow is aimed — quantised, see `glowStep`.
    var glow: CGPoint?
}

private struct RefractiveCanvas: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Dark-only apps keep the charcoal ground regardless of system appearance.
    let forceDark: Bool

    @State private var bounds: CGRect = .zero
    @State private var lamp = Lamp()
    /// Whether the pump is running. Written only when the pointer enters or
    /// leaves, so it is two state changes per visit rather than one per event.
    @State private var live = false

    private var isDark: Bool { forceDark || scheme == .dark }

    private var anchor: CGPoint {
        CGPoint(x: bounds.minX + bounds.width * Refractive.restAnchor.x,
                y: bounds.minY + bounds.height * Refractive.restAnchor.y)
    }

    /// Where the key hangs: with no pointer at its rest anchor, otherwise on the
    /// wall directly above the cursor. One-to-one with the pointer on purpose —
    /// amplifying it was what made a quarter of the screen do nothing and the
    /// next quarter do everything.
    private var lightPoint: CGPoint {
        guard let current = lamp.current else { return anchor }
        return CGPoint(x: current.x, y: current.y - bounds.height * Refractive.keyLift)
    }

    private var field: RefractiveField {
        RefractiveField(light: lightPoint,
                        span: max(bounds.width, bounds.height))
    }

    /// The glow that explains the highlights. It tracks the pointer far more
    /// softly than the key does, because it has to stay inside the window to be
    /// visible at all — the key may leave, its glow may not.
    private var glowPoint: CGPoint {
        guard let glow = lamp.glow else { return anchor }
        return CGPoint(x: anchor.x + (glow.x - anchor.x) * Refractive.pointerPull,
                       y: anchor.y + (glow.y - anchor.y) * Refractive.pointerPull)
    }

    private var glowCenter: UnitPoint {
        guard bounds.width > 0, bounds.height > 0 else { return UnitPoint(x: 0.5, y: -0.14) }
        return UnitPoint(x: (glowPoint.x - bounds.minX) / bounds.width,
                         y: (glowPoint.y - bounds.minY) / bounds.height - 0.42)
    }

    /// Advance the light to where it should be at `now`.
    ///
    /// Called once per tick of the display clock and nowhere else, which is the
    /// entire point: the damper integrates over a regular interval, so equal
    /// slices of time produce equal slices of motion and the presented cadence
    /// is even by construction rather than by whatever the event stream happened
    /// to do. It mutates `lamp` during body evaluation, which is safe precisely
    /// because `Lamp` is not observable — the tick already scheduled this pass,
    /// and nothing here asks for another one.
    private func advance(to now: Date) {
        guard let target = lamp.target else { return }
        guard let current = lamp.current else {
            lamp.current = target
            lamp.glow = target
            lamp.tick = now
            return
        }
        let dt = lamp.tick.map { now.timeIntervalSince($0) } ?? Refractive.pumpInterval
        let ease = min(Refractive.keyMaxStep,
                       CGFloat(1 - exp(-dt / Refractive.keyTau)))
        var next = CGPoint(x: current.x + (target.x - current.x) * ease,
                           y: current.y + (target.y - current.y) * ease)
        let lag = hypot(target.x - next.x, target.y - next.y)
        let limit = max(bounds.width, bounds.height) * Refractive.keyMaxLag
        if lag > limit, lag > 0 {
            let keep = limit / lag
            next = CGPoint(x: target.x + (next.x - target.x) * keep,
                           y: target.y + (next.y - target.y) * keep)
        }
        // Drop the sub-pixel tail rather than repainting the window for it — see
        // `keyMinStep`. Leaving the clock alone means the interval carries into
        // the next tick, so this converges by taking one larger step later
        // instead of stalling on a run of steps too small to bother with. It is
        // also what makes a stationary cursor free: once the light is inside
        // `keyMinStep` of the target the field stops changing, and an equal
        // `RefractiveField` invalidates nothing downstream.
        guard hypot(next.x - current.x, next.y - current.y)
                >= Refractive.keyMinStep else { return }
        lamp.tick = now
        lamp.current = next
        // Re-aim the glow only once the light has travelled far enough to be
        // worth repainting the whole window for — see `glowStep`.
        if let held = lamp.glow,
           hypot(next.x - held.x, next.y - held.y) < Refractive.glowStep { return }
        lamp.glow = next
    }

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: Refractive.pumpInterval,
                                paused: !live)) { context in
            let _ = advance(to: context.date)
            content
                .background {
                    if isDark {
                        ZStack {
                            Refractive.canvasDark
                            EllipticalGradient(
                                stops: [.init(color: Refractive.canvasGlow.opacity(0.053), location: 0.0),
                                        .init(color: .clear, location: 0.68)],
                                center: glowCenter,
                                startRadiusFraction: 0, endRadiusFraction: 0.78)
                        }
                        .ignoresSafeArea()
                    }
                }
                .environment(\.refractiveField, field)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { bounds = $0 }
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                guard !reduceMotion else {
                    lamp.target = nil
                    lamp.current = nil
                    if live { live = false }
                    return
                }
                // The whole cost of a pointer event. No damping, no geometry, no
                // redraw — just the newest answer to the question the pump asks.
                lamp.target = CGPoint(x: bounds.minX + point.x,
                                      y: bounds.minY + point.y)
                if !live { live = true }
            case .ended:
                // The lamp stays where it was. Sending it home would be the one
                // motion in here that nothing the user did accounts for.
                if live { live = false }
            }
        }
    }
}

// MARK: - Entry points

extension View {
    /// A slab: cards, regions, sidebars, popovers. Anything that holds content.
    func refractiveGlass(cornerRadius: CGFloat) -> some View {
        modifier(RefractiveSlab(radius: cornerRadius))
    }

    /// A tile inside a slab: stat cells, chips, inline wells.
    func refractiveInset(cornerRadius: CGFloat) -> some View {
        modifier(RefractiveInset(radius: cornerRadius))
    }

    /// The window ground, and the light every surface reads. Apply once, at the
    /// window root — surfaces outside a canvas fall back to a fixed key light.
    func refractiveCanvas(forceDark: Bool = false) -> some View {
        modifier(RefractiveCanvas(forceDark: forceDark))
    }
}
