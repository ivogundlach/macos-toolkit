import SwiftUI

// MARK: - Tokens
//
// Extends the fleet system (UsageQueue vocabulary; see DashboardTheme /
// VitalsTheme) rather than introducing a new one. The rule that governs every
// choice here: container backgrounds are ONE neutral surface, and all colour
// lives in the foreground — gradient icon tiles, coloured kickers, coloured
// values, status pills, course accents on schedule blocks.

enum SchoolTheme {
    static let page = Color(nsColor: .windowBackgroundColor)
    static let sidebar = Color(nsColor: .underPageBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let inset = Color(nsColor: .textBackgroundColor)
    static let border = Color(nsColor: .separatorColor)

    /// Flat stand-in for the glass slab on surfaces that scroll or repeat.
    /// Same measured reason as the rest of the fleet: `glassEffect` is a
    /// backdrop blur that re-renders whenever its content moves, so a card
    /// wrapping a long list pays for it on every scrolled frame.
    static let paneFill = Color.primary.opacity(0.05)

    static let controlRadius: CGFloat = 9
    static let rowRadius: CGFloat = 8
    static let cardRadius: CGFloat = 12
    static let groupRadius: CGFloat = 14

    static let accent = Color(red: 0.29, green: 0.44, blue: 0.86)
}

enum Palette {
    /// Per-course accents for the schedule grid and course tiles. These are
    /// data-viz fills keyed to a course, not surface tints — the exception the
    /// one-background rule explicitly allows. Ordered for hue separation at
    /// small sizes and checked against both appearances.
    static let course: [Color] = [
        Color(red: 0.29, green: 0.44, blue: 0.86),
        Color(red: 0.13, green: 0.58, blue: 0.52),
        Color(red: 0.80, green: 0.47, blue: 0.14),
        Color(red: 0.62, green: 0.34, blue: 0.78),
        Color(red: 0.83, green: 0.34, blue: 0.44),
        Color(red: 0.20, green: 0.55, blue: 0.78),
        Color(red: 0.45, green: 0.55, blue: 0.20),
        Color(red: 0.72, green: 0.40, blue: 0.62),
    ]

    /// Stable per-course colour: index into the term's own course list so the
    /// same course keeps its colour everywhere in the app, and a hash fallback
    /// for anything the course list does not know about.
    static func color(for code: String?, in courses: [Course]) -> Color {
        guard let code else { return Color.secondary }
        if let index = courses.firstIndex(where: { $0.code == code }) {
            return course[index % course.count]
        }
        let hash = abs(code.hashValue)
        return course[hash % course.count]
    }
}

enum HealthColor {
    static let ok = Color(red: 0.20, green: 0.62, blue: 0.35)
    static let warn = Color(red: 0.82, green: 0.60, blue: 0.11)
    static let fail = Color(red: 0.80, green: 0.28, blue: 0.28)
    static let idle = Color.secondary
}

enum Format {
    /// Minutes-from-midnight to "8:00 AM".
    static func clock(_ minutes: Int) -> String {
        var components = DateComponents()
        components.hour = minutes / 60
        components.minute = minutes % 60
        let calendar = Calendar.current
        guard let date = calendar.date(from: DateComponents(
            year: 2000, month: 1, day: 1, hour: components.hour, minute: components.minute)
        ) else { return "" }
        return time.string(from: date)
    }

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        f.amSymbol = "AM"
        f.pmSymbol = "PM"
        return f
    }()

    static let timeShort: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("h:mm a")
        return f
    }()

    static let weekdayDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d"
        return f
    }()

    static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f
    }()

    static let mediumDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    static let monthDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    /// "in 3 days", "2 hours ago" — the phrasing a person actually thinks in.
    static func relative(_ date: Date, from now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// "Due Friday at 11:59 PM" style, collapsing to today/tomorrow.
    static func due(_ date: Date, allDay: Bool) -> String {
        let cal = Calendar.current
        let day: String
        if cal.isDateInToday(date) { day = "Today" }
        else if cal.isDateInTomorrow(date) { day = "Tomorrow" }
        else if cal.isDateInYesterday(date) { day = "Yesterday" }
        else if let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()),
                                              to: cal.startOfDay(for: date)).day,
                (0...6).contains(days) {
            day = weekday.string(from: date)
        } else {
            day = mediumDate.string(from: date)
        }
        return allDay ? day : "\(day) at \(time.string(from: date))"
    }
}

// MARK: - Shared components

/// The gradient glyph tile that opens every section across the fleet.
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 27

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(LinearGradient(colors: [color.opacity(0.85), color],
                                     startPoint: .bottomLeading, endPoint: .topTrailing))
            Image(systemName: symbol)
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

/// Uppercase kerned section label — the fleet's section marker.
struct Kicker: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .kerning(0.8)
            .foregroundStyle(color)
    }
}

struct SectionHeader: View {
    let title: String
    let subtitle: String?
    let symbol: String
    let color: Color
    var trailing: AnyView?

    init(title: String, subtitle: String? = nil, symbol: String, color: Color,
         @ViewBuilder trailing: () -> some View = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.color = color
        self.trailing = AnyView(trailing())
    }

    var body: some View {
        HStack(spacing: 9) {
            IconTile(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 2)
    }
}

/// Neutral card. Glass on the container, never on the rows inside it.
struct Card<Content: View>: View {
    var padding: CGFloat = 14
    /// Long/scrolling content opts out of the material — see `paneFill`.
    var flat: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        Group {
            if flat {
                content
                    .padding(padding)
                    .background(RoundedRectangle(cornerRadius: SchoolTheme.cardRadius, style: .continuous)
                        .fill(SchoolTheme.paneFill))
                    .overlay(RoundedRectangle(cornerRadius: SchoolTheme.cardRadius, style: .continuous)
                        .stroke(SchoolTheme.border, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: SchoolTheme.cardRadius, style: .continuous))
            } else {
                content
                    .padding(padding)
                    .refractiveGlass(cornerRadius: SchoolTheme.cardRadius)
            }
        }
    }
}

/// A big number with a label — the overview's hero row.
struct StatTile: View {
    let value: String
    let label: String
    let caption: String?
    let symbol: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(color)
                Kicker(text: label, color: color)
                Spacer(minLength: 0)
            }
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let caption {
                Text(caption)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Pill: View {
    let text: String
    let color: Color
    var symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold))
            }
            Text(text).font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(Capsule().fill(color.opacity(0.14)))
        .fixedSize()
    }
}

/// Selected state is a solid tint + white text, never a tinted glass — tinted
/// glass looks right in dark mode and goes unreadable in light.
struct SegmentPill: View {
    let label: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11.5, weight: .semibold))
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Capsule().fill(isActive
                    ? AnyShapeStyle(SchoolTheme.accent)
                    : AnyShapeStyle(Color.primary.opacity(0.06))))
                .overlay(Capsule().stroke(isActive ? Color.clear : SchoolTheme.border, lineWidth: 1))
                .foregroundStyle(isActive ? Color.white : Color.secondary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

struct EmptyNote: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.tertiary)
            Text(title).font(.system(size: 12.5, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 16)
    }
}

/// Solid semantic fill, deliberately: a problem banner has to stay unambiguous
/// against the glass around it.
struct Banner: View {
    let symbol: String
    let title: String
    let detail: String
    let color: Color
    var actionLabel: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let actionLabel, let action {
                Button(actionLabel, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .focusEffectDisabled()
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: SchoolTheme.cardRadius, style: .continuous)
            .fill(color.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: SchoolTheme.cardRadius, style: .continuous)
            .stroke(color.opacity(0.32), lineWidth: 1))
    }
}
