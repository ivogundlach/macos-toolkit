import SwiftUI
import Observation
import AppKit
import Foundation

/// Formats a billions value as "$1234B", showing one decimal only when it carries
/// information — a trailing ".0" is dropped (e.g. "$5596B", but "$263.8B").
func formatBillions(_ value: Double) -> String {
    let s = String(format: "%.1f", value)
    return "$" + (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + "B"
}

/// Formats a tax *rate* fraction (e.g. 0.21) as a percent, dropping a trailing
/// ".0" so it reads "21%" not "21.0%", while keeping "12.4%".
func formatPercent(_ rate: Double) -> String {
    let s = String(format: "%.1f", rate * 100)
    return (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + "%"
}

// MARK: - Tax Simulator design vocabulary

/// A compact, native policy-lab vocabulary shared by the dashboard and AGY pane.
/// Domain colors remain semantic: green is revenue, red is outlay/deficit, and
/// indigo is reserved for interaction and scenario state.
enum TaxLabTheme {
    static let accent = Color(red: 0.28, green: 0.38, blue: 0.72)
    static let revenue = Color(red: 0.18, green: 0.58, blue: 0.42)
    static let outlay = Color(red: 0.78, green: 0.28, blue: 0.30)
    static let warning = Color(red: 0.88, green: 0.55, blue: 0.16)

    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let grouped = Color.primary.opacity(0.03)
    static let panel = Color.primary.opacity(0.045)
    static let panelStrong = Color.primary.opacity(0.065)
    // Liquid Glass. Card level only — `panelStrong` and `grouped` stay flat
    // because they are insets inside those cards.
    static let cardGlass: Glass = .regular
    static let interactiveGlass: Glass = .regular.interactive()

    static let border = Color.primary.opacity(0.08)
    static let borderStrong = Color.primary.opacity(0.14)

    static func categoryAccent(_ title: String) -> Color {
        switch title {
        case "Individual Income Taxes", "Payroll Taxes", "Corporate Taxes",
             "Other Revenue Multipliers", "Estate & Inheritance": return revenue
        case "Consumption Taxes", "Wealth & Property Taxes", "Externality Taxes",
             "Financial Taxes": return accent
        case "Mandatory Entitlements", "Discretionary Spending", "Net Interest & Debt Feedback": return outlay
        case "Novel Programs": return warning
        default: return accent
        }
    }
}

struct TaxLabSectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .kerning(0.8)
            .foregroundStyle(.secondary)
    }
}

struct TaxLabSurface<Content: View>: View {
    var radius: CGFloat = 12
    /// `nil` takes Liquid Glass, which is what a card should be. An explicit fill
    /// opts out, for recessed containers that *hold* glass rather than being it —
    /// stacking glass on glass reads as neither.
    var fill: Color? = nil
    @ViewBuilder let content: Content

    var body: some View {
        // Both branches are the fleet material; a recessed container is the thin
        // pane, a raised one the thick slab. Neither wears a uniform border —
        // the lit rim is the edge.
        Group {
            if fill != nil {
                content.refractiveInset(cornerRadius: radius)
            } else {
                content.refractiveGlass(cornerRadius: radius)
            }
        }
    }
}

struct TaxLabPaneHeading: View {
    let eyebrow: String
    let title: String
    let detail: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.13))
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                TaxLabSectionLabel(text: eyebrow)
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Hover explanations
// Keyed by SummaryItemRow `id` (items) and CategorySummaryCard `title` (categories).
// Shown as a native hover tooltip on every row + category header. Sources: 2026-06-25 catalog.

let taxItemInfo: [String: String] = [
    // Individual income
    "bracket10": "The 10% bracket: the lowest marginal income-tax rate, applied to the first slice of taxable income (~$0–$11,925). Paid by virtually all filers.",
    "bracket12": "The 12% bracket, applied to income roughly $11,926–$48,475. Covers most lower-middle-income earners.",
    "bracket22": "The 22% bracket, applied to income roughly $48,476–$103,350 — the broad middle class.",
    "bracket24": "The 24% bracket, applied to income roughly $103,351–$197,300 — upper-middle earners.",
    "bracket32": "The 32% bracket, applied to income roughly $197,301–$250,525.",
    "bracket35": "The 35% bracket, applied to income roughly $250,526–$626,350.",
    "bracket37": "The top 37% bracket, applied to income over $626,350. A small number of high earners pay the bulk of income tax here.",
    "capitalGainsRate": "Tax on profits from selling assets (stocks, property) held over a year. Currently capped near 20%; heavily concentrated among wealthier households.",
    // Payroll
    "socialSecurityRate": "Social Security (OASDI) payroll tax — 12.4% split between employer and employee on wages up to a cap. Funds retirement, survivors and disability benefits.",
    "medicareRate": "Medicare Hospital Insurance (HI) payroll tax — 2.9% on all wages, uncapped. Funds Medicare Part A.",
    "futaRate": "Federal Unemployment (FUTA) payroll tax. Funds state unemployment-insurance administration and the federal loan backstop.",
    // Corporate
    "corporateStatutoryRate": "The headline corporate income-tax rate on C-corporation profits (currently 21%). Borne by shareholders, workers and customers.",
    "camtRate": "Corporate Alternative Minimum Tax — a 15% floor on the book income of very large corporations, so highly profitable firms can't pay near-zero.",
    "giltiRate": "GILTI: a tax on the foreign intangible profits of US multinationals, designed to curb offshore profit-shifting.",
    "beatRate": "BEAT (Base Erosion and Anti-abuse Tax): a minimum tax that limits deductions for payments multinationals make to foreign affiliates.",
    "stockBuybackRate": "Excise tax on corporate stock buybacks (currently 1%), discouraging firms from returning cash via repurchases over dividends/investment.",
    // Other revenue
    "exciseMultiplier": "Excise taxes — per-unit taxes on specific goods like fuel, alcohol, tobacco and air travel. Multiplier scales the whole category.",
    "customsMultiplier": "Customs duties / tariffs on imported goods, collected at the border and largely passed on to consumers.",
    "miscMultiplier": "Miscellaneous receipts — Federal Reserve remittances, fees and fines (excludes estate & gift, now its own line).",
    // Estate
    "estateGift": "Current-law estate & gift tax on large wealth transfers at death or by gift. Exemption ~$14M/person, top rate 40%; paid by under 0.1% of estates.",
    "estateExpansion": "NOVEL: lowers the estate exemption to $3.5M and applies progressive 45–65% rates on the largest estates (Sanders 'For the 99.5% Act'). Dials up on top of current law.",
    // Consumption (novel)
    "vat": "NOVEL: a Value-Added Tax on consumption, collected at each production stage on the value added. Used in 170+ countries; the US is the only OECD member without one. Borne by consumers.",
    "nationalSalesTax": "NOVEL: a single-stage federal retail sales tax on final purchases ('FairTax' style) — an alternative to a VAT. Never enacted federally.",
    "digitalServices": "NOVEL: a levy on the gross digital revenue (ads, marketplaces, data) of large tech firms. France, the UK and others run 2–3% DSTs; no US federal version.",
    // Wealth & property (novel)
    "wealthTax": "NOVEL: an annual tax on net worth above a high threshold (e.g. Warren's 2% over $50M, 3% over $1B). Levied in Norway, Spain, Switzerland; revenue is contested due to avoidance.",
    "landValueTax": "NOVEL: a tax on the unimproved value of land (not buildings). Championed by Henry George; used in parts of Pennsylvania, Estonia and Denmark. Hard to avoid.",
    // Externality (novel)
    "carbonTax": "NOVEL: a price per ton of CO₂ emitted, raising fossil-fuel costs to cut emissions. Used by Sweden, Canada and the EU. No US federal carbon tax.",
    "vmtTax": "NOVEL: a per-mile charge on driving, meant to replace the eroding gas tax as vehicles electrify. Piloted in Oregon and Utah; no national version.",
    "sodaTax": "NOVEL: a per-ounce excise on sugar-sweetened beverages to curb consumption. Run by several US cities and 50+ countries; no federal version.",
    // Financial (novel)
    "financialTransactionTax": "NOVEL: a small tax on each securities trade (stocks, bonds, derivatives). The UK levies a 0.5% stamp duty; aimed partly at high-frequency trading.",
    "bankLevy": "NOVEL: a levy on the liabilities or assets of large banks, pricing in systemic risk. The UK and several EU states run one; no US federal version.",
    // Mandatory
    "socialSecurityAllocation": "Social Security benefits to ~70M retirees, survivors and disabled workers — the single largest federal program.",
    "medicareAllocation": "Medicare: federal health insurance for those 65+ and some disabled people, net of premiums.",
    "medicaidAllocation": "Medicaid & CHIP: joint federal-state health coverage for low-income and disabled people and children.",
    "incomeSecurityAllocation": "Income security: SNAP, SSI, unemployment, refundable tax credits and other safety-net support.",
    "otherMandatoryAllocation": "Other mandatory: federal civilian and military retirement, agriculture and other mandatory programs.",
    // Discretionary
    "defenseAllocation": "Defense: military personnel, operations, procurement and R&D.",
    "veterans": "Veterans' benefits & services: healthcare, disability compensation and education for veterans.",
    "education": "Education & training: K-12 grants, Pell/Title I, student aid and workforce training.",
    "transportation": "Transportation & infrastructure: highways, transit, aviation, rail and water systems.",
    "healthNonMed": "Health (non-Medicare): NIH, CDC and public-health and community health programs.",
    "science": "Science, space & R&D: NASA, NSF and other non-defense research.",
    "international": "International affairs / foreign aid: diplomacy, development and humanitarian assistance.",
    "justice": "Justice & law enforcement: federal courts, prisons, the FBI and law-enforcement grants.",
    "environment": "Natural resources & environment: EPA, parks, public lands and conservation.",
    "housing": "Housing assistance and community development programs.",
    "energy": "Energy programs: the power grid, energy R&D and strategic reserves.",
    "commerce": "Commerce: economic development, the census, weather services and trade promotion.",
    "generalGov": "General government and all remaining non-defense discretionary spending.",
    "netInterestMultiplier": "Net interest on the federal debt. Locked by default: it adjusts automatically as deficits change borrowing (feedback at r≈4%).",
    // Novel programs (spending)
    "ubi": "NOVEL: Universal Basic Income — an unconditional cash payment (~$1,000/mo) to every adult. Alaska pays a partial dividend; no full US version. Shown as gross cost.",
    "medicareForAll": "NOVEL: single-payer national health insurance covering everyone, replacing private premiums. Canada, the UK and Taiwan run single-payer. Net new federal cost.",
    "universalChildcare": "NOVEL: subsidized childcare and universal pre-K, common across the Nordic countries.",
    "jobGuarantee": "NOVEL: a federal job guarantee — public employment for anyone willing to work, at a wage and benefit floor.",
    "freeCollege": "NOVEL: tuition-free public college for in-state students. Germany and the Nordics are tuition-free.",
    "babyBonds": "NOVEL: a birthright savings account for every child, funded more generously for poorer families (Booker plan).",
    "paidLeave": "NOVEL: a national paid family & medical leave benefit for new parents and caregivers.",
    "sovereignWealthFund": "NOVEL: an annual contribution to a national investment fund (models: Norway's GPFG, Alaska's APF). Modeled as an outlay; investment returns aren't simulated.",
]

let taxCategoryInfo: [String: String] = [
    "Individual Income Taxes": "Tax on wages, investment income and capital gains under a 7-bracket progressive schedule — the largest single federal revenue source.",
    "Payroll Taxes": "Wage-based taxes that fund Social Security, Medicare and unemployment insurance. The second-largest revenue source.",
    "Corporate Taxes": "Taxes on corporate profits: the 21% statutory rate plus the CAMT, GILTI, BEAT and stock-buyback layers.",
    "Other Revenue Multipliers": "Excise taxes, customs duties/tariffs and miscellaneous receipts.",
    "Estate & Inheritance": "Taxes on large wealth transfers — the current-law estate & gift tax plus optional expansions.",
    "Consumption Taxes": "NOVEL: broad taxes on spending (VAT, national sales tax, digital services) that the US doesn't levy federally. Default OFF.",
    "Wealth & Property Taxes": "NOVEL: annual taxes on accumulated wealth and land value. Default OFF.",
    "Externality Taxes": "NOVEL: Pigouvian taxes that price harms — carbon, road use and sugary drinks. Default OFF.",
    "Financial Taxes": "NOVEL: taxes on financial activity — securities-transaction tax and a bank levy. Default OFF.",
    "Mandatory Entitlements": "Benefit programs set by law, not annual appropriations: Social Security, Medicare, Medicaid, income security and more.",
    "Discretionary Spending": "Spending set each year by appropriations: defense plus named non-defense programs.",
    "Net Interest & Debt Feedback": "Interest paid on the federal debt, which rises with deficits via the modeled feedback loop.",
    "Novel Programs": "NOVEL: new federal programs (UBI, Medicare for All, free college and more). Default OFF; dial up to the researched full cost.",
]

@Observable
class DashboardState {
    var engine = MacroMathEngine()
    
    // Accordion: only one slider item expanded at a time (nil = all collapsed)
    var expandedSliderItem: String? = nil
    
    // Collapsed categories (empty = all expanded)
    var collapsedCategories: Set<String> = []
    
    // Popover states
    var isShowingWarningsPopover = false
    var isShowingRevenuesKPICardPopover = false
    var isShowingSpendingKPICardPopover = false
    var isShowingRevenuesCompactKPICardPopover = false
    var isShowingSpendingCompactKPICardPopover = false
    var isShowingRevenuesChartPopover = false
    var isShowingSpendingChartPopover = false
    
    // Resizing states
    var splitWidth: CGFloat = 600
    var dragStartWidth: CGFloat = 0
    var isAgyAssistantVisible = true
    var agyChat = AgyChatModel()
    
    // Window dimensions — updated only on actual window resize, NOT on slider drag
    var windowWidth: CGFloat = 1200
    var windowHeight: CGFloat = 800
}

public struct DashboardView: View {
    var state = DashboardState()
    
    public init() {}
    
    public var body: some View {
        @Bindable var state = state
        @Bindable var engine = state.engine

        GeometryReader { geometry in
            let isCompact = geometry.size.width < (state.isAgyAssistantVisible ? 1380 : 960)

            VStack(spacing: 0) {
                DashboardToolbarView(state: state, engine: engine)
                Divider()

                Group {
                    if isCompact {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                DashboardContentAreaView(state: state, engine: engine, isCompact: true)
                                ControlsSidebarView(state: state, engine: engine, showHeader: true)
                                if state.isAgyAssistantVisible {
                                    AgyChatView(model: state.agyChat, engine: engine,
                                                onClose: { state.isAgyAssistantVisible = false })
                                        .frame(height: 560)
                                        .clipShape(RoundedRectangle(cornerRadius: 14))
                                        .overlay(RoundedRectangle(cornerRadius: 14)
                                            .stroke(TaxLabTheme.border, lineWidth: 1))
                                }
                            }
                            .padding(16)
                        }
                    } else {
                        HStack(spacing: 0) {
                            DashboardContentAreaView(state: state, engine: engine, isCompact: false)
                                .padding(16)
                                .frame(width: state.splitWidth)
                                .frame(maxHeight: .infinity)

                            DividerHandle(state: state, totalWidth: state.windowWidth)

                            ScrollView {
                                ControlsSidebarView(state: state, engine: engine, showHeader: true)
                                    .padding(16)
                            }
                            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)

                            if state.isAgyAssistantVisible {
                                Divider()
                                AgyChatView(model: state.agyChat, engine: engine,
                                            onClose: { state.isAgyAssistantVisible = false })
                                    .frame(width: 460)
                            }
                        }
                    }
                }
            }
            .onAppear {
                state.windowWidth = geometry.size.width
                state.windowHeight = geometry.size.height
                if state.splitWidth == 600 {
                    state.splitWidth = state.isAgyAssistantVisible
                        ? min(max(400, geometry.size.width * 0.38), max(400, geometry.size.width - 920))
                        : geometry.size.width * 0.6
                }
            }
            .onChange(of: geometry.size) { _, newSize in
                state.windowWidth = newSize.width
                state.windowHeight = newSize.height
            }
        }
        .refractiveCanvas()
        .tint(TaxLabTheme.accent)
        .frame(minWidth: 550, minHeight: 600)
    }
}

struct DashboardToolbarView: View {
    @Bindable var state: DashboardState
    let engine: MacroMathEngine

    private var hasWarnings: Bool {
        engine.isLafferInflectionWarningActive ||
        engine.isGeopoliticalRiskWarningActive ||
        engine.isRetireePovertyAlertActive
    }

    private var isAtBaseline: Bool {
        abs(engine.revenueChange) < 0.1 &&
        abs(engine.outlayChange) < 0.1 &&
        abs(engine.deficitChange) < 0.1
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.22, blue: 0.52),
                                                  Color(red: 0.36, green: 0.46, blue: 0.86)],
                                         startPoint: .bottomLeading, endPoint: .topTrailing))
                Image(systemName: "building.columns.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 1) {
                Text("Tax Simulator").font(.system(size: 15, weight: .semibold))
                Text("FY 2026 · Federal policy lab")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if state.windowWidth >= 760 {
                HStack(spacing: 5) {
                    Image(systemName: isAtBaseline ? "checkmark.circle.fill" : "slider.horizontal.3")
                    Text(isAtBaseline ? "Baseline" : "Live scenario")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isAtBaseline ? TaxLabTheme.revenue : TaxLabTheme.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill((isAtBaseline ? TaxLabTheme.revenue : TaxLabTheme.accent).opacity(0.12)))
            }

            if hasWarnings {
                Button {
                    state.isShowingWarningsPopover.toggle()
                } label: {
                    Label("Warnings", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(TaxLabTheme.warning)
                .popover(isPresented: $state.isShowingWarningsPopover, arrowEdge: .bottom) {
                    ActiveWarningsPopoverContent(engine: engine).padding(14)
                }
                .help("Show active policy warnings")
            }

            Button {
                state.isAgyAssistantVisible.toggle()
            } label: {
                if state.windowWidth >= 650 {
                    Label(state.isAgyAssistantVisible ? "Hide AGY" : "Show AGY",
                          systemImage: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                } else {
                    Image(systemName: "sparkles")
                }
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(state.isAgyAssistantVisible ? "Hide AGY assistant" : "Show AGY assistant")
            .help(state.isAgyAssistantVisible ? "Hide AGY assistant pane" : "Show AGY assistant pane")

            Button {
                engine.reset()
            } label: {
                if state.windowWidth >= 650 {
                    Label("Reset baseline", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .semibold))
                } else {
                    Image(systemName: "arrow.counterclockwise")
                }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Reset baseline")
            .help("Restore every fiscal control to the FY 2026 baseline")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .refractiveCanvas()
    }
}

struct DividerHandle: View {
    @Bindable var state: DashboardState
    let totalWidth: CGFloat
    
    var body: some View {
        ZStack {
            Color.clear
                .frame(width: 12)
                .contentShape(Rectangle())

            Rectangle()
                .fill(TaxLabTheme.border)
                .frame(width: 1)

            RoundedRectangle(cornerRadius: 3)
                .fill(TaxLabTheme.panelStrong)
                .frame(width: 6, height: 46)
                .overlay(
                    VStack(spacing: 3) {
                        Circle().fill(Color.secondary).frame(width: 2, height: 2)
                        Circle().fill(Color.secondary).frame(width: 2, height: 2)
                        Circle().fill(Color.secondary).frame(width: 2, height: 2)
                    }
                )
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(TaxLabTheme.borderStrong, lineWidth: 1))
        }
        .frame(width: 12)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { gesture in
                    if state.dragStartWidth == 0 {
                        state.dragStartWidth = state.splitWidth
                    }
                    let newWidth = state.dragStartWidth + gesture.translation.width
                    let reservedRightWidth: CGFloat = state.isAgyAssistantVisible ? 850 : 390
                    state.splitWidth = min(max(430, newWidth), max(430, totalWidth - reservedRightWidth))
                }
                .onEnded { _ in
                    state.dragStartWidth = 0
                }
        )
        .accessibilityLabel("Resize fiscal overview")
        .accessibilityHint("Drag left or right to resize the overview and policy controls")
    }
}

struct ControlsSidebarView: View {
    @Bindable var state: DashboardState
    @Bindable var engine: MacroMathEngine
    let showHeader: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showHeader {
                TaxLabSurface {
                    TaxLabPaneHeading(
                        eyebrow: "Scenario controls",
                        title: "Policy levers",
                        detail: "Open a row to adjust one assumption. Every result and warning updates immediately.",
                        symbol: "slider.horizontal.3",
                        tint: TaxLabTheme.accent
                    )
                    .padding(12)
                }
            }
            
            // --- REVENUES SECTION ---
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "dollarsign.circle.fill")
                        .foregroundStyle(TaxLabTheme.revenue)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Revenue policy").font(.system(size: 13, weight: .semibold))
                        Text("Rates, bases, and new instruments")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(formatBillions(engine.activeTotalRevenues))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                .padding(.horizontal, 4)
                
                VStack(spacing: 6) {
                    // Individual Income Taxes (Progressive Brackets)
                    CategorySummaryCard(
                        title: "Individual Income Taxes",
                        categoryTotal: engine.activeIndividualIncomeTax,
                        iconName: "person.fill",
                        collapsedCategories: $state.collapsedCategories
                    ) {
                        // 10% Bracket
                        SummaryItemRow(
                            id: "bracket10",
                            title: engine.brackets[0].label,
                            formattedValue: formatPercent(engine.bracket10Rate),
                            formattedBaseline: "10%",
                            computedAmount: engine.activeBracketRevenue(index: 0),
                            isModified: abs(engine.bracket10Rate - 0.10) > 0.0001,
                            expandedItem: $state.expandedSliderItem
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Slider(value: $engine.bracket10Rate, in: 0.0...1.0)
                                Text("Income range: \(engine.brackets[0].incomeRange)")
                                    .font(.caption).foregroundColor(.secondary).italic()
                            }
                        }
                        
                        // 12% Bracket
                        SummaryItemRow(
                            id: "bracket12",
                            title: engine.brackets[1].label,
                            formattedValue: formatPercent(engine.bracket12Rate),
                            formattedBaseline: "12%",
                            computedAmount: engine.activeBracketRevenue(index: 1),
                            isModified: abs(engine.bracket12Rate - 0.12) > 0.0001,
                            expandedItem: $state.expandedSliderItem
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Slider(value: $engine.bracket12Rate, in: 0.0...1.0)
                                Text("Income range: \(engine.brackets[1].incomeRange)")
                                    .font(.caption).foregroundColor(.secondary).italic()
                            }
                        }
                        
                        // 22% Bracket
                        SummaryItemRow(
                            id: "bracket22",
                            title: engine.brackets[2].label,
                            formattedValue: formatPercent(engine.bracket22Rate),
                            formattedBaseline: "22%",
                            computedAmount: engine.activeBracketRevenue(index: 2),
                            isModified: abs(engine.bracket22Rate - 0.22) > 0.0001,
                            expandedItem: $state.expandedSliderItem
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Slider(value: $engine.bracket22Rate, in: 0.0...1.0)
                                Text("Income range: \(engine.brackets[2].incomeRange)")
                                    .font(.caption).foregroundColor(.secondary).italic()
                            }
                        }
                        
                        // 24% Bracket
                        SummaryItemRow(
                            id: "bracket24",
                            title: engine.brackets[3].label,
                            formattedValue: formatPercent(engine.bracket24Rate),
                            formattedBaseline: "24%",
                            computedAmount: engine.activeBracketRevenue(index: 3),
                            isModified: abs(engine.bracket24Rate - 0.24) > 0.0001,
                            expandedItem: $state.expandedSliderItem
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Slider(value: $engine.bracket24Rate, in: 0.0...1.0)
                                Text("Income range: \(engine.brackets[3].incomeRange)")
                                    .font(.caption).foregroundColor(.secondary).italic()
                            }
                        }
                        
                        // 32% Bracket
                        SummaryItemRow(
                            id: "bracket32",
                            title: engine.brackets[4].label,
                            formattedValue: formatPercent(engine.bracket32Rate),
                            formattedBaseline: "32%",
                            computedAmount: engine.activeBracketRevenue(index: 4),
                            isModified: abs(engine.bracket32Rate - 0.32) > 0.0001,
                            expandedItem: $state.expandedSliderItem
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Slider(value: $engine.bracket32Rate, in: 0.0...1.0)
                                Text("Income range: \(engine.brackets[4].incomeRange)")
                                    .font(.caption).foregroundColor(.secondary).italic()
                            }
                        }
                        
                        // 35% Bracket
                        SummaryItemRow(
                            id: "bracket35",
                            title: engine.brackets[5].label,
                            formattedValue: formatPercent(engine.bracket35Rate),
                            formattedBaseline: "35%",
                            computedAmount: engine.activeBracketRevenue(index: 5),
                            isModified: abs(engine.bracket35Rate - 0.35) > 0.0001,
                            expandedItem: $state.expandedSliderItem
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Slider(value: $engine.bracket35Rate, in: 0.0...1.0)
                                Text("Income range: \(engine.brackets[5].incomeRange)")
                                    .font(.caption).foregroundColor(.secondary).italic()
                            }
                        }
                        
                        // 37% Bracket
                        SummaryItemRow(
                            id: "bracket37",
                            title: engine.brackets[6].label,
                            formattedValue: formatPercent(engine.bracket37Rate),
                            formattedBaseline: "37%",
                            computedAmount: engine.activeBracketRevenue(index: 6),
                            isModified: abs(engine.bracket37Rate - 0.37) > 0.0001,
                            expandedItem: $state.expandedSliderItem
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Slider(value: $engine.bracket37Rate, in: 0.0...1.0)
                                Text("Income range: \(engine.brackets[6].incomeRange)")
                                    .font(.caption).foregroundColor(.secondary).italic()
                            }
                        }
                        
                        // Capital Gains (separate from progressive brackets)
                        SummaryItemRow(
                            id: "capitalGainsRate",
                            title: "Capital Gains",
                            formattedValue: formatPercent(engine.capitalGainsRate),
                            formattedBaseline: "20%",
                            computedAmount: nil,
                            isModified: abs(engine.capitalGainsRate - 0.20) > 0.0001,
                            expandedItem: $state.expandedSliderItem
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Slider(value: $engine.capitalGainsRate, in: 0.0...1.0)
                                Text("Tax on profits from the sale of investments, stocks, and real estate.")
                                    .font(.caption).foregroundColor(.secondary).italic()
                            }
                        }
                    }
                    
                    // Payroll Taxes
                    CategorySummaryCard(
                        title: "Payroll Taxes",
                        categoryTotal: engine.activePayrollTaxTotal,
                        iconName: "building.columns.fill",
                        collapsedCategories: $state.collapsedCategories
                    ) {
                        SummaryItemRow(
                            id: "socialSecurityRate",
                            title: "Social Security (OASDI)",
                            formattedValue: formatPercent(engine.socialSecurityRate),
                            formattedBaseline: formatPercent(0.124),
                            computedAmount: engine.activeSocialSecurityTax,
                            isModified: abs(engine.socialSecurityRate - 0.124) > 0.0001,
                            expandedItem: $state.expandedSliderItem
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Slider(value: $engine.socialSecurityRate, in: 0.0...0.50)
                                Text("Payroll tax funding Old-Age, Survivors, and Disability Insurance.")
                                    .font(.caption).foregroundColor(.secondary).italic()
                            }
                        }
                        
                        SummaryItemRow(
                            id: "medicareRate",
                            title: "Medicare (HI)",
                            formattedValue: formatPercent(engine.medicareRate),
                            formattedBaseline: formatPercent(0.029),
                            computedAmount: engine.activeMedicareTax,
                            isModified: abs(engine.medicareRate - 0.029) > 0.0001,
                            expandedItem: $state.expandedSliderItem
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Slider(value: $engine.medicareRate, in: 0.0...0.20)
                                Text("Payroll tax funding Hospital Insurance for the elderly and disabled.")
                                    .font(.caption).foregroundColor(.secondary).italic()
                            }
                        }
                        
                        SummaryItemRow(
                            id: "futaRate",
                            title: "FUTA (Unemployment)",
                            formattedValue: formatPercent(engine.futaRate),
                            formattedBaseline: formatPercent(0.06),
                            computedAmount: engine.activeFutaTax,
                            isModified: abs(engine.futaRate - 0.06) > 0.0001,
                            expandedItem: $state.expandedSliderItem
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Slider(value: $engine.futaRate, in: 0.0...0.20)
                                Text("Federal Unemployment Tax Act rate paid by employers to fund benefits administration.")
                                    .font(.caption).foregroundColor(.secondary).italic()
                            }
                        }
                    }
                    
                    // Corporate Taxes
                    CategorySummaryCard(
                        title: "Corporate Taxes",
                        categoryTotal: engine.activeCorporateIncomeTax,
                        iconName: "briefcase.fill",
                        collapsedCategories: $state.collapsedCategories
                    ) {
                        SummaryItemRow(
                            id: "corporateStatutoryRate",
                            title: "Statutory Rate",
                            formattedValue: formatPercent(engine.corporateStatutoryRate),
                            formattedBaseline: formatPercent(0.21),
                            computedAmount: nil,
                            isModified: abs(engine.corporateStatutoryRate - 0.21) > 0.0001,
                            expandedItem: $state.expandedSliderItem
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Slider(value: $engine.corporateStatutoryRate, in: 0.0...1.0)
                                Text("Standard federal tax rate applied to corporate net profits.")
                                    .font(.caption).foregroundColor(.secondary).italic()
                            }
                        }
                        
                        SummaryItemRow(
                            id: "camtRate",
                            title: "CAMT (Minimum Tax)",
                            formattedValue: formatPercent(engine.camtRate),
                            formattedBaseline: formatPercent(0.15),
                            computedAmount: nil,
                            isModified: abs(engine.camtRate - 0.15) > 0.0001,
                            expandedItem: $state.expandedSliderItem
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Slider(value: $engine.camtRate, in: 0.0...0.50)
                                Text("Corporate Alternative Minimum Tax applied to large firms with book income over $1B.")
                                    .font(.caption).foregroundColor(.secondary).italic()
                            }
                        }
                        
                        SummaryItemRow(
                            id: "giltiRate",
                            title: "GILTI",
                            formattedValue: formatPercent(engine.giltiRate),
                            formattedBaseline: formatPercent(0.105),
                            computedAmount: nil,
                            isModified: abs(engine.giltiRate - 0.105) > 0.0001,
                            expandedItem: $state.expandedSliderItem
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Slider(value: $engine.giltiRate, in: 0.0...0.50)
                                Text("Global Intangible Low-Taxed Income tax targeting foreign earnings of multinationals.")
                                    .font(.caption).foregroundColor(.secondary).italic()
                            }
                        }
                        
                        SummaryItemRow(
                            id: "beatRate",
                            title: "BEAT",
                            formattedValue: formatPercent(engine.beatRate),
                            formattedBaseline: formatPercent(0.10),
                            computedAmount: nil,
                            isModified: abs(engine.beatRate - 0.10) > 0.0001,
                            expandedItem: $state.expandedSliderItem
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Slider(value: $engine.beatRate, in: 0.0...0.50)
                                Text("Base Erosion and Anti-Abuse Tax preventing profit-shifting to low-tax jurisdictions.")
                                    .font(.caption).foregroundColor(.secondary).italic()
                            }
                        }
                        
                        SummaryItemRow(
                            id: "stockBuybackRate",
                            title: "Stock Buyback Tax",
                            formattedValue: formatPercent(engine.stockBuybackRate),
                            formattedBaseline: formatPercent(0.01),
                            computedAmount: nil,
                            isModified: abs(engine.stockBuybackRate - 0.01) > 0.0001,
                            expandedItem: $state.expandedSliderItem
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Slider(value: $engine.stockBuybackRate, in: 0.0...0.20)
                                Text("Excise tax on corporate stock repurchases.")
                                    .font(.caption).foregroundColor(.secondary).italic()
                            }
                        }
                    }
                    
                    // Other Revenue Multipliers
                    CategorySummaryCard(
                        title: "Other Revenue Multipliers",
                        categoryTotal: engine.activeExciseTaxes + engine.activeCustomsDuties + engine.activeMiscellaneousReceipts,
                        iconName: "square.grid.2x2.fill",
                        collapsedCategories: $state.collapsedCategories
                    ) {
                        SummaryItemRow(
                            id: "exciseMultiplier",
                            title: "Excise Taxes",
                            formattedValue: String(format: "%.2fx", engine.exciseMultiplier),
                            formattedBaseline: "1.00x",
                            computedAmount: engine.activeExciseTaxes,
                            isModified: abs(engine.exciseMultiplier - 1.0) > 0.0001,
                            expandedItem: $state.expandedSliderItem
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Slider(value: $engine.exciseMultiplier, in: 0.0...5.0)
                                Text("Multiplier scaling taxes on fuel, aviation, tobacco, and alcohol.")
                                    .font(.caption).foregroundColor(.secondary).italic()
                            }
                        }
                        
                        SummaryItemRow(
                            id: "customsMultiplier",
                            title: "Customs Duties",
                            formattedValue: String(format: "%.2fx", engine.customsMultiplier),
                            formattedBaseline: "1.00x",
                            computedAmount: engine.activeCustomsDuties,
                            isModified: abs(engine.customsMultiplier - 1.0) > 0.0001,
                            expandedItem: $state.expandedSliderItem
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Slider(value: $engine.customsMultiplier, in: 0.0...5.0)
                                Text("Multiplier scaling tariffs collected on imported foreign goods.")
                                    .font(.caption).foregroundColor(.secondary).italic()
                            }
                        }
                        
                        SummaryItemRow(
                            id: "miscMultiplier",
                            title: "Misc Receipts",
                            formattedValue: String(format: "%.2fx", engine.miscMultiplier),
                            formattedBaseline: "1.00x",
                            computedAmount: engine.activeMiscellaneousReceipts,
                            isModified: abs(engine.miscMultiplier - 1.0) > 0.0001,
                            expandedItem: $state.expandedSliderItem
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Slider(value: $engine.miscMultiplier, in: 0.0...5.0)
                                Text("Multiplier scaling Reserve deposits, regulatory fees, and other revenues.")
                                    .font(.caption).foregroundColor(.secondary).italic()
                            }
                        }
                    }

                    // Estate & Inheritance
                    CategorySummaryCard(
                        title: "Estate & Inheritance",
                        categoryTotal: engine.activeEstateGiftTax + engine.activeEstateExpansion,
                        iconName: "building.columns.fill",
                        collapsedCategories: $state.collapsedCategories
                    ) {
                        SummaryItemRow(
                            id: "estateGift",
                            title: "Estate & Gift Tax",
                            formattedValue: String(format: "%.2fx", engine.estateGiftMultiplier),
                            formattedBaseline: "1.00x",
                            computedAmount: engine.activeEstateGiftTax,
                            isModified: abs(engine.estateGiftMultiplier - 1.0) > 0.0001,
                            expandedItem: $state.expandedSliderItem
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Slider(value: $engine.estateGiftMultiplier, in: 0.0...3.0)
                                Text("Current-law tax on large wealth transfers (~$30B). Multiplier scales the whole line.")
                                    .font(.caption).foregroundColor(.secondary).italic()
                            }
                        }
                        SummaryItemRow(
                            id: "estateExpansion",
                            title: "Estate Tax Expansion",
                            formattedValue: String(format: "+$%.0fB", engine.estateExpansionYield),
                            formattedBaseline: "$0B",
                            computedAmount: engine.activeEstateExpansion,
                            isModified: engine.estateExpansionYield > 0.01,
                            expandedItem: $state.expandedSliderItem
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Slider(value: $engine.estateExpansionYield, in: 0.0...60.0)
                                Text("NOVEL: lower exemption + higher rates (Sanders 99.5% Act ≈ +$43B). Adds on top of current law.")
                                    .font(.caption).foregroundColor(.secondary).italic()
                            }
                        }
                    }

                    // Consumption Taxes (NOVEL)
                    CategorySummaryCard(
                        title: "Consumption Taxes",
                        categoryTotal: engine.activeVAT + engine.activeNationalSalesTax + engine.activeDigitalServicesTax,
                        iconName: "cart.fill",
                        collapsedCategories: $state.collapsedCategories
                    ) {
                        SummaryItemRow(
                            id: "vat",
                            title: "Value-Added Tax (VAT)",
                            formattedValue: formatPercent(engine.vatRate),
                            formattedBaseline: "0%",
                            computedAmount: engine.activeVAT,
                            isModified: engine.vatRate > 0.0001,
                            expandedItem: $state.expandedSliderItem
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Slider(value: $engine.vatRate, in: 0.0...0.20)
                                Text("NOVEL: broad consumption tax. ~$68B per 1 percentage point; ~$340B at 5%.")
                                    .font(.caption).foregroundColor(.secondary).italic()
                            }
                        }
                        SummaryItemRow(
                            id: "nationalSalesTax",
                            title: "National Retail Sales Tax",
                            formattedValue: formatPercent(engine.nationalSalesTaxRate),
                            formattedBaseline: "0%",
                            computedAmount: engine.activeNationalSalesTax,
                            isModified: engine.nationalSalesTaxRate > 0.0001,
                            expandedItem: $state.expandedSliderItem
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Slider(value: $engine.nationalSalesTaxRate, in: 0.0...0.25)
                                Text("NOVEL: single-stage retail sales tax ('FairTax' style). ~$60B per 1 point.")
                                    .font(.caption).foregroundColor(.secondary).italic()
                            }
                        }
                        SummaryItemRow(
                            id: "digitalServices",
                            title: "Digital Services Tax",
                            formattedValue: formatPercent(engine.digitalServicesRate),
                            formattedBaseline: "0%",
                            computedAmount: engine.activeDigitalServicesTax,
                            isModified: engine.digitalServicesRate > 0.0001,
                            expandedItem: $state.expandedSliderItem
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Slider(value: $engine.digitalServicesRate, in: 0.0...0.10)
                                Text("NOVEL: tax on big-tech gross digital revenue. ~$15B at 3%.")
                                    .font(.caption).foregroundColor(.secondary).italic()
                            }
                        }
                    }

                    // Wealth & Property Taxes (NOVEL)
                    CategorySummaryCard(
                        title: "Wealth & Property Taxes",
                        categoryTotal: engine.activeWealthTax + engine.activeLandValueTax,
                        iconName: "building.2.fill",
                        collapsedCategories: $state.collapsedCategories
                    ) {
                        SummaryItemRow(
                            id: "wealthTax",
                            title: "Net Wealth Tax",
                            formattedValue: String(format: "$%.0fB", engine.wealthTaxYield),
                            formattedBaseline: "$0B",
                            computedAmount: engine.activeWealthTax,
                            isModified: engine.wealthTaxYield > 0.01,
                            expandedItem: $state.expandedSliderItem
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Slider(value: $engine.wealthTaxYield, in: 0.0...330.0)
                                Text("NOVEL: annual tax on net worth over a high threshold. Warren 2%/3% plan ≈ $280B (contested).")
                                    .font(.caption).foregroundColor(.secondary).italic()
                            }
                        }
                        SummaryItemRow(
                            id: "landValueTax",
                            title: "Land Value Tax",
                            formattedValue: formatPercent(engine.landValueTaxRate),
                            formattedBaseline: "0%",
                            computedAmount: engine.activeLandValueTax,
                            isModified: engine.landValueTaxRate > 0.0001,
                            expandedItem: $state.expandedSliderItem
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Slider(value: $engine.landValueTaxRate, in: 0.0...0.05)
                                Text("NOVEL: tax on unimproved land value (~$23T base). ~$230B per 1%.")
                                    .font(.caption).foregroundColor(.secondary).italic()
                            }
                        }
                    }

                    // Externality Taxes (NOVEL)
                    CategorySummaryCard(
                        title: "Externality Taxes",
                        categoryTotal: engine.activeCarbonTax + engine.activeVMTTax + engine.activeSodaTax,
                        iconName: "leaf.fill",
                        collapsedCategories: $state.collapsedCategories
                    ) {
                        SummaryItemRow(
                            id: "carbonTax",
                            title: "Carbon Tax",
                            formattedValue: String(format: "$%.0f/ton", engine.carbonPricePerTon),
                            formattedBaseline: "$0/ton",
                            computedAmount: engine.activeCarbonTax,
                            isModified: engine.carbonPricePerTon > 0.01,
                            expandedItem: $state.expandedSliderItem
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Slider(value: $engine.carbonPricePerTon, in: 0.0...150.0)
                                Text("NOVEL: price per ton of CO₂. ~$4.2B per $1/ton; ~$210B at $50/ton.")
                                    .font(.caption).foregroundColor(.secondary).italic()
                            }
                        }
                        SummaryItemRow(
                            id: "vmtTax",
                            title: "Road-Use (VMT) Tax",
                            formattedValue: String(format: "%.1f¢/mi", engine.vmtCentsPerMile),
                            formattedBaseline: "0¢/mi",
                            computedAmount: engine.activeVMTTax,
                            isModified: engine.vmtCentsPerMile > 0.001,
                            expandedItem: $state.expandedSliderItem
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Slider(value: $engine.vmtCentsPerMile, in: 0.0...10.0)
                                Text("NOVEL: per-mile driving charge to replace the gas tax. ~$32B per 1¢/mi.")
                                    .font(.caption).foregroundColor(.secondary).italic()
                            }
                        }
                        SummaryItemRow(
                            id: "sodaTax",
                            title: "Sugar-Sweetened Beverage Tax",
                            formattedValue: String(format: "$%.0fB", engine.sodaTaxYield),
                            formattedBaseline: "$0B",
                            computedAmount: engine.activeSodaTax,
                            isModified: engine.sodaTaxYield > 0.01,
                            expandedItem: $state.expandedSliderItem
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Slider(value: $engine.sodaTaxYield, in: 0.0...25.0)
                                Text("NOVEL: per-ounce excise on sugary drinks. Run by several US cities and 50+ countries.")
                                    .font(.caption).foregroundColor(.secondary).italic()
                            }
                        }
                    }

                    // Financial Taxes (NOVEL)
                    CategorySummaryCard(
                        title: "Financial Taxes",
                        categoryTotal: engine.activeFinancialTransactionTax + engine.activeBankLevy,
                        iconName: "chart.line.uptrend.xyaxis",
                        collapsedCategories: $state.collapsedCategories
                    ) {
                        SummaryItemRow(
                            id: "financialTransactionTax",
                            title: "Financial Transaction Tax",
                            formattedValue: String(format: "%.2f%%", engine.financialTransactionRate * 100),
                            formattedBaseline: "0%",
                            computedAmount: engine.activeFinancialTransactionTax,
                            isModified: engine.financialTransactionRate > 0.00001,
                            expandedItem: $state.expandedSliderItem
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Slider(value: $engine.financialTransactionRate, in: 0.0...0.005)
                                Text("NOVEL: small tax on securities trades. ~$78B at 0.1%.")
                                    .font(.caption).foregroundColor(.secondary).italic()
                            }
                        }
                        SummaryItemRow(
                            id: "bankLevy",
                            title: "Bank / Financial Levy",
                            formattedValue: String(format: "$%.0fB", engine.bankLevyYield),
                            formattedBaseline: "$0B",
                            computedAmount: engine.activeBankLevy,
                            isModified: engine.bankLevyYield > 0.01,
                            expandedItem: $state.expandedSliderItem
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Slider(value: $engine.bankLevyYield, in: 0.0...30.0)
                                Text("NOVEL: levy on large-bank liabilities/assets, pricing systemic risk (UK-style).")
                                    .font(.caption).foregroundColor(.secondary).italic()
                            }
                        }
                    }
                }
            }

            Divider()

            // --- EXPENDITURES SECTION ---
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.up.right.circle.fill")
                        .foregroundStyle(TaxLabTheme.outlay)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Spending policy").font(.system(size: 13, weight: .semibold))
                        Text("Programs, allocations, and debt service")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(formatBillions(engine.activeTotalOutlays))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                .padding(.horizontal, 4)
                
                VStack(spacing: 6) {
                    // Mandatory Entitlements
                    CategorySummaryCard(
                        title: "Mandatory Entitlements",
                        categoryTotal: engine.activeSocialSecurityOutlay + engine.activeMedicareOutlay + engine.activeMedicaidOutlay + engine.activeIncomeSecurityOutlay + engine.activeOtherMandatoryOutlay,
                        iconName: "shield.fill",
                        collapsedCategories: $state.collapsedCategories
                    ) {
                        SummaryItemRow(
                            id: "socialSecurityAllocation",
                            title: "Social Security",
                            formattedValue: String(format: "%.2fx", engine.socialSecurityAllocationMultiplier),
                            formattedBaseline: "1.00x",
                            computedAmount: engine.activeSocialSecurityOutlay,
                            isModified: abs(engine.socialSecurityAllocationMultiplier - 1.0) > 0.0001,
                            expandedItem: $state.expandedSliderItem
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Slider(value: $engine.socialSecurityAllocationMultiplier, in: 0.0...3.0)
                                Text("Multiplier scaling mandatory outlays for federal retirement and disability benefits.")
                                    .font(.caption).foregroundColor(.secondary).italic()
                            }
                        }
                        
                        SummaryItemRow(
                            id: "medicareAllocation",
                            title: "Medicare",
                            formattedValue: String(format: "%.2fx", engine.medicareAllocationMultiplier),
                            formattedBaseline: "1.00x",
                            computedAmount: engine.activeMedicareOutlay,
                            isModified: abs(engine.medicareAllocationMultiplier - 1.0) > 0.0001,
                            expandedItem: $state.expandedSliderItem
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Slider(value: $engine.medicareAllocationMultiplier, in: 0.0...3.0)
                                Text("Multiplier scaling mandatory outlays for senior healthcare coverage programs.")
                                    .font(.caption).foregroundColor(.secondary).italic()
                            }
                        }
                        
                        SummaryItemRow(
                            id: "medicaidAllocation",
                            title: "Medicaid & CHIP",
                            formattedValue: String(format: "%.2fx", engine.medicaidAllocationMultiplier),
                            formattedBaseline: "1.00x",
                            computedAmount: engine.activeMedicaidOutlay,
                            isModified: abs(engine.medicaidAllocationMultiplier - 1.0) > 0.0001,
                            expandedItem: $state.expandedSliderItem
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Slider(value: $engine.medicaidAllocationMultiplier, in: 0.0...3.0)
                                Text("Multiplier scaling outlays for low-income and children's healthcare programs.")
                                    .font(.caption).foregroundColor(.secondary).italic()
                            }
                        }
                        
                        SummaryItemRow(
                            id: "incomeSecurityAllocation",
                            title: "Income Security",
                            formattedValue: String(format: "%.2fx", engine.incomeSecurityAllocationMultiplier),
                            formattedBaseline: "1.00x",
                            computedAmount: engine.activeIncomeSecurityOutlay,
                            isModified: abs(engine.incomeSecurityAllocationMultiplier - 1.0) > 0.0001,
                            expandedItem: $state.expandedSliderItem
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Slider(value: $engine.incomeSecurityAllocationMultiplier, in: 0.0...3.0)
                                Text("Multiplier scaling outlays for SNAP food aid, housing, and family support.")
                                    .font(.caption).foregroundColor(.secondary).italic()
                            }
                        }
                        
                        SummaryItemRow(
                            id: "otherMandatoryAllocation",
                            title: "Other Mandatory",
                            formattedValue: String(format: "%.2fx", engine.otherMandatoryAllocationMultiplier),
                            formattedBaseline: "1.00x",
                            computedAmount: engine.activeOtherMandatoryOutlay,
                            isModified: abs(engine.otherMandatoryAllocationMultiplier - 1.0) > 0.0001,
                            expandedItem: $state.expandedSliderItem
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Slider(value: $engine.otherMandatoryAllocationMultiplier, in: 0.0...3.0)
                                Text("Multiplier scaling outlays for veterans' benefits and federal pensions.")
                                    .font(.caption).foregroundColor(.secondary).italic()
                            }
                        }
                    }
                    
                    // Discretionary Spending
                    CategorySummaryCard(
                        title: "Discretionary Spending",
                        categoryTotal: engine.activeDefenseOutlay + engine.activeNonDefenseOutlay,
                        iconName: "flag.fill",
                        collapsedCategories: $state.collapsedCategories
                    ) {
                        SummaryItemRow(
                            id: "defenseAllocation",
                            title: "Defense",
                            formattedValue: String(format: "%.2fx", engine.defenseAllocationMultiplier),
                            formattedBaseline: "1.00x",
                            computedAmount: engine.activeDefenseOutlay,
                            isModified: abs(engine.defenseAllocationMultiplier - 1.0) > 0.0001,
                            expandedItem: $state.expandedSliderItem
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Slider(value: $engine.defenseAllocationMultiplier, in: 0.0...3.0)
                                Text("Multiplier scaling discretionary outlays for military operations, payroll, and procurement.")
                                    .font(.caption).foregroundColor(.secondary).italic()
                            }
                        }
                        
                        Group {
                            DiscretionaryRow(engine: engine, state: state, id: "veterans", title: "Veterans' Benefits", amount: engine.activeVeteransOutlay, mult: $engine.veteransMultiplier, desc: "Healthcare, disability compensation and education for veterans (~$135B).")
                            DiscretionaryRow(engine: engine, state: state, id: "education", title: "Education & Training", amount: engine.activeEducationOutlay, mult: $engine.educationMultiplier, desc: "K-12 grants, student aid and workforce training (~$90B).")
                            DiscretionaryRow(engine: engine, state: state, id: "transportation", title: "Transportation & Infrastructure", amount: engine.activeTransportationOutlay, mult: $engine.transportationMultiplier, desc: "Highways, transit, aviation, rail and water systems (~$110B).")
                            DiscretionaryRow(engine: engine, state: state, id: "healthNonMed", title: "Health (non-Medicare)", amount: engine.activeHealthNonMedOutlay, mult: $engine.healthNonMedMultiplier, desc: "NIH, CDC and public-health programs (~$110B).")
                            DiscretionaryRow(engine: engine, state: state, id: "science", title: "Science, Space & R&D", amount: engine.activeScienceOutlay, mult: $engine.scienceMultiplier, desc: "NASA, NSF and other non-defense research (~$45B).")
                            DiscretionaryRow(engine: engine, state: state, id: "international", title: "International / Foreign Aid", amount: engine.activeInternationalOutlay, mult: $engine.internationalMultiplier, desc: "Diplomacy, development and humanitarian aid (~$70B).")
                        }
                        Group {
                            DiscretionaryRow(engine: engine, state: state, id: "justice", title: "Justice & Law Enforcement", amount: engine.activeJusticeOutlay, mult: $engine.justiceMultiplier, desc: "Federal courts, prisons, the FBI and grants (~$75B).")
                            DiscretionaryRow(engine: engine, state: state, id: "environment", title: "Natural Resources & Environment", amount: engine.activeEnvironmentOutlay, mult: $engine.environmentMultiplier, desc: "EPA, parks, public lands and conservation (~$45B).")
                            DiscretionaryRow(engine: engine, state: state, id: "housing", title: "Housing", amount: engine.activeHousingOutlay, mult: $engine.housingMultiplier, desc: "Housing assistance and community development (~$65B).")
                            DiscretionaryRow(engine: engine, state: state, id: "energy", title: "Energy", amount: engine.activeEnergyOutlay, mult: $engine.energyMultiplier, desc: "Grid, energy R&D and strategic reserves (~$30B).")
                            DiscretionaryRow(engine: engine, state: state, id: "commerce", title: "Commerce", amount: engine.activeCommerceOutlay, mult: $engine.commerceMultiplier, desc: "Economic development, census, weather and trade (~$25B).")
                            DiscretionaryRow(engine: engine, state: state, id: "generalGov", title: "General Government", amount: engine.activeGeneralGovOutlay, mult: $engine.generalGovMultiplier, desc: "General government and remaining non-defense discretionary (~$196B).")
                        }
                    }

                    // Novel Programs (NOVEL)
                    CategorySummaryCard(
                        title: "Novel Programs",
                        categoryTotal: engine.activeNovelSpending,
                        iconName: "sparkles",
                        collapsedCategories: $state.collapsedCategories
                    ) {
                        ProgramRow(state: state, id: "ubi", title: "Universal Basic Income", spend: $engine.ubiSpend, maxSpend: 4000, desc: "NOVEL: ~$1,000/mo to every adult. Gross cost ≈ $3,100B.")
                        ProgramRow(state: state, id: "medicareForAll", title: "Medicare for All", spend: $engine.medicareForAllSpend, maxSpend: 3500, desc: "NOVEL: single-payer health insurance. Net new federal cost ≈ $3,000B.")
                        ProgramRow(state: state, id: "universalChildcare", title: "Universal Childcare & Pre-K", spend: $engine.universalChildcareSpend, maxSpend: 400, desc: "NOVEL: subsidized childcare and universal pre-K ≈ $200B.")
                        ProgramRow(state: state, id: "jobGuarantee", title: "Federal Job Guarantee", spend: $engine.jobGuaranteeSpend, maxSpend: 800, desc: "NOVEL: public employment at a wage floor ≈ $500B.")
                        ProgramRow(state: state, id: "freeCollege", title: "Tuition-Free Public College", spend: $engine.freeCollegeSpend, maxSpend: 120, desc: "NOVEL: free in-state public tuition ≈ $55B.")
                        ProgramRow(state: state, id: "babyBonds", title: "Baby Bonds", spend: $engine.babyBondsSpend, maxSpend: 100, desc: "NOVEL: birthright savings accounts ≈ $60B.")
                        ProgramRow(state: state, id: "paidLeave", title: "Paid Family & Medical Leave", spend: $engine.paidLeaveSpend, maxSpend: 80, desc: "NOVEL: national paid-leave benefit ≈ $40B.")
                        ProgramRow(state: state, id: "sovereignWealthFund", title: "Sovereign Wealth Fund", spend: $engine.sovereignWealthFundSpend, maxSpend: 350, desc: "NOVEL: annual contribution to a national investment fund.")
                    }

                    // Net Interest & Debt Feedback
                    CategorySummaryCard(
                        title: "Net Interest & Debt Feedback",
                        categoryTotal: engine.activeNetInterestOutlay,
                        iconName: "percent",
                        collapsedCategories: $state.collapsedCategories
                    ) {
                        SummaryItemRow(
                            id: "netInterestMultiplier",
                            title: "Net Interest Multiplier",
                            formattedValue: engine.isNetInterestLocked ? "Auto" : String(format: "%.2fx", engine.netInterestMultiplier),
                            formattedBaseline: "1.00x",
                            computedAmount: engine.activeNetInterestOutlay,
                            isModified: !engine.isNetInterestLocked && abs(engine.netInterestMultiplier - 1.0) > 0.0001,
                            expandedItem: $state.expandedSliderItem
                        ) {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Toggle(isOn: $engine.isNetInterestLocked) {
                                        Text(engine.isNetInterestLocked ? "Dynamic Feedback Loop Enabled" : "Manual Multiplier Enabled")
                                            .fontWeight(.medium)
                                    }
                                    .toggleStyle(.checkbox)
                                }
                                
                                if !engine.isNetInterestLocked {
                                    Slider(value: $engine.netInterestMultiplier, in: 0.0...3.0)
                                }
                                
                                Text(engine.isNetInterestLocked
                                    ? "Interest outlays adjust dynamically in response to debt changes and interest rate feedback loop (r = 4.0%)."
                                    : "Multiplier scaling federal outlays for interest on outstanding debt.")
                                    .font(.caption).foregroundColor(.secondary).italic()
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Category Summary Card

struct CategorySummaryCard<Content: View>: View {
    let title: String
    let categoryTotal: Double
    let iconName: String
    @Binding var collapsedCategories: Set<String>
    @ViewBuilder let content: Content
    
    private var isCollapsed: Bool { collapsedCategories.contains(title) }
    private var accent: Color { TaxLabTheme.categoryAccent(title) }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isCollapsed {
                        collapsedCategories.remove(title)
                    } else {
                        collapsedCategories.insert(title)
                    }
                }
            }) {
                HStack(spacing: 9) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(LinearGradient(colors: [accent.opacity(0.85), accent],
                                                 startPoint: .bottomLeading, endPoint: .topTrailing))
                        Image(systemName: iconName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 28, height: 28)
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(formatBillions(categoryTotal))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            // One neutral expanded-state fill for every category: peer cards must
            // not differ in background color (the colored icon tile identifies
            // the category).
            .background(isCollapsed ? Color.clear : TaxLabTheme.panelStrong)
            .help(taxCategoryInfo[title] ?? "")
            .accessibilityLabel("\(title), \(formatBillions(categoryTotal))")
            .accessibilityHint(isCollapsed ? "Expand category" : "Collapse category")

            if !isCollapsed {
                VStack(spacing: 0) {
                    content
                }
                .transition(.opacity)
            }
        }
        .refractiveGlass(cornerRadius: 12)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Summary Item Row (Compact + Inline Slider Dropdown)

struct SummaryItemRow<SliderContent: View>: View {
    let id: String
    let title: String
    let formattedValue: String
    let formattedBaseline: String
    let computedAmount: Double?
    let isModified: Bool
    @Binding var expandedItem: String?
    @ViewBuilder let sliderContent: SliderContent
    
    private var isExpanded: Bool { expandedItem == id }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedItem = isExpanded ? nil : id
                }
            }) {
                HStack(spacing: 8) {
                    ZStack {
                        Circle().stroke(TaxLabTheme.borderStrong, lineWidth: 1)
                        if isModified {
                            Circle().fill(TaxLabTheme.accent).padding(2)
                        }
                    }
                    .frame(width: 9, height: 9)
                    
                    Text(title)
                        .font(.system(size: 12, weight: isModified ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    
                    Spacer()
                    
                    if let amount = computedAmount {
                        Text(formatBillions(amount))
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(TaxLabTheme.grouped))
                    }
                    
                    Text(formattedValue)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(isModified ? TaxLabTheme.accent : Color.primary)
                        .frame(minWidth: 50, alignment: .trailing)
                    
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 9)
            .padding(.horizontal, 10)
            .background(isExpanded ? TaxLabTheme.panelStrong : Color.clear)
            .help(taxItemInfo[id] ?? "")
            .accessibilityLabel("\(title), \(formattedValue)\(isModified ? ", modified" : "")")
            .accessibilityHint(isExpanded ? "Close editor" : "Open editor")

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Baseline \(formattedBaseline)", systemImage: "scope")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if isModified {
                            Text("Modified")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(TaxLabTheme.accent)
                        }
                    }
                    
                    sliderContent
                }
                .padding(10)
                .background(TaxLabTheme.accent.opacity(0.035))
                .overlay(alignment: .leading) {
                    Rectangle().fill(TaxLabTheme.accent.opacity(0.55)).frame(width: 2)
                }
                .transition(.opacity)
            }

            Divider()
                .padding(.leading, 27)
        }
    }
}
// MARK: - Discretionary program row (compact wrapper around SummaryItemRow)

struct DiscretionaryRow: View {
    let engine: MacroMathEngine
    @Bindable var state: DashboardState
    let id: String
    let title: String
    let amount: Double
    @Binding var mult: Double
    let desc: String

    var body: some View {
        SummaryItemRow(
            id: id,
            title: title,
            formattedValue: String(format: "%.2fx", mult),
            formattedBaseline: "1.00x",
            computedAmount: amount,
            isModified: abs(mult - 1.0) > 0.0001,
            expandedItem: $state.expandedSliderItem
        ) {
            VStack(alignment: .leading, spacing: 4) {
                Slider(value: $mult, in: 0.0...3.0)
                Text(desc)
                    .font(.caption).foregroundColor(.secondary).italic()
            }
        }
    }
}

// MARK: - Novel program row ($B-level spending wrapper around SummaryItemRow)

struct ProgramRow: View {
    @Bindable var state: DashboardState
    let id: String
    let title: String
    @Binding var spend: Double
    let maxSpend: Double
    let desc: String

    var body: some View {
        SummaryItemRow(
            id: id,
            title: title,
            formattedValue: String(format: "$%.0fB", spend),
            formattedBaseline: "$0B",
            computedAmount: spend > 0.01 ? spend : nil,
            isModified: spend > 0.01,
            expandedItem: $state.expandedSliderItem
        ) {
            VStack(alignment: .leading, spacing: 4) {
                Slider(value: $spend, in: 0.0...maxSpend)
                Text(desc)
                    .font(.caption).foregroundColor(.secondary).italic()
            }
        }
    }
}

struct DashboardContentAreaView: View {
    @Bindable var state: DashboardState
    @Bindable var engine: MacroMathEngine
    let isCompact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TaxLabPaneHeading(
                eyebrow: "Fiscal snapshot",
                title: "Active policy scenario",
                detail: "Compare the current revenue mix, federal outlays, and resulting budget balance.",
                symbol: "chart.bar.xaxis",
                tint: TaxLabTheme.accent
            )

            KPISectionView(state: state, engine: engine, isCompact: isCompact)

            TaxLabSurface(radius: 14, fill: TaxLabTheme.grouped) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Revenue and outlays")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Active composition, scaled to the larger total")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        let isDeficit = engine.activeDeficit >= 0
                        Label(
                            "\(formatBillions(abs(engine.activeDeficit))) \(isDeficit ? "deficit" : "surplus")",
                            systemImage: isDeficit ? "arrow.down.right" : "arrow.up.right"
                        )
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isDeficit ? TaxLabTheme.outlay : TaxLabTheme.revenue)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill((isDeficit ? TaxLabTheme.outlay : TaxLabTheme.revenue).opacity(0.12)))
                    }

                    ComparisonChart(state: state, engine: engine)
                }
                .padding(14)
            }

            SystemWarningsPanel(engine: engine)
        }
        .frame(maxWidth: .infinity, maxHeight: isCompact ? nil : .infinity, alignment: .top)
    }
}

// MARK: - KPI cards

struct KPISectionView: View {
    @Bindable var state: DashboardState
    let engine: MacroMathEngine
    let isCompact: Bool

    var body: some View {
        HStack(spacing: 10) {
            KPICard(
                title: "Revenue",
                value: engine.activeTotalRevenues,
                change: engine.revenueChange,
                isGoodChange: engine.revenueChange >= 0,
                iconName: "dollarsign.circle.fill",
                color: TaxLabTheme.revenue,
                popoverContent: AnyView(RevenuesPopoverContent(engine: engine).frame(width: 320)),
                isPresented: $state.isShowingRevenuesKPICardPopover
            )

            KPICard(
                title: "Outlays",
                value: engine.activeTotalOutlays,
                change: engine.outlayChange,
                isGoodChange: engine.outlayChange <= 0,
                iconName: "arrow.up.right.circle.fill",
                color: TaxLabTheme.outlay,
                popoverContent: AnyView(SpendingPopoverContent(engine: engine).frame(width: 340)),
                isPresented: $state.isShowingSpendingKPICardPopover
            )

            let isDeficit = engine.activeDeficit >= 0
            KPICard(
                title: isDeficit ? "Deficit" : "Surplus",
                value: abs(engine.activeDeficit),
                change: engine.deficitChange,
                isGoodChange: engine.deficitChange <= 0,
                iconName: isDeficit ? "chart.line.downtrend.xyaxis" : "chart.line.uptrend.xyaxis",
                color: isDeficit ? TaxLabTheme.outlay : TaxLabTheme.revenue,
                isPresented: .constant(false)
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Fiscal key performance indicators")
    }
}

struct KPICard: View {
    let title: String
    let value: Double
    let change: Double
    let isGoodChange: Bool
    let iconName: String
    let color: Color

    var popoverContent: AnyView? = nil
    @Binding var isPresented: Bool

    private var changeLabel: String {
        guard abs(change) >= 0.1 else { return "At baseline" }
        return "\(formatBillions(abs(change))) \(change > 0 ? "above" : "below") baseline"
    }

    private var changeColor: Color {
        abs(change) < 0.1 ? .secondary : (isGoodChange ? TaxLabTheme.revenue : TaxLabTheme.outlay)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(LinearGradient(colors: [color.opacity(0.85), color],
                                             startPoint: .bottomLeading, endPoint: .topTrailing))
                    Image(systemName: iconName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 24, height: 24)

                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            Text(formatBillions(value))
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.65)

            HStack(spacing: 4) {
                Image(systemName: abs(change) < 0.1 ? "equal.circle.fill" : (change > 0 ? "arrow.up" : "arrow.down"))
                    .font(.system(size: 9, weight: .semibold))
                Text(changeLabel)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(changeColor)
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .onHover { hovering in
            if popoverContent != nil { isPresented = hovering }
        }
        .refractiveGlass(cornerRadius: 11)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.75))
                .frame(width: 3)
                .padding(.vertical, 10)
        }
        .overlay {
            if let content = popoverContent {
                Color.clear
                    .allowsHitTesting(false)
                    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                        content.padding(14)
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(formatBillions(value)), \(changeLabel)")
        .accessibilityAction(named: "Show breakdown") {
            if popoverContent != nil { isPresented.toggle() }
        }
    }
}

// MARK: - Fiscal comparison chart

struct ComparisonChart: View {
    @Bindable var state: DashboardState
    let engine: MacroMathEngine

    struct SegmentData {
        let label: String
        let value: Double
        let color: Color
    }

    var revenueSegments: [SegmentData] {
        [
            SegmentData(label: "Individual income", value: engine.activeIndividualIncomeTax, color: Color(red: 0.19, green: 0.48, blue: 0.72)),
            SegmentData(label: "Payroll", value: engine.activePayrollTaxTotal, color: Color(red: 0.19, green: 0.62, blue: 0.58)),
            SegmentData(label: "Corporate", value: engine.activeCorporateIncomeTax, color: Color(red: 0.37, green: 0.39, blue: 0.72)),
            SegmentData(label: "Excise", value: engine.activeExciseTaxes, color: Color(red: 0.52, green: 0.38, blue: 0.68)),
            SegmentData(label: "Customs", value: engine.activeCustomsDuties, color: Color(red: 0.84, green: 0.50, blue: 0.20)),
            SegmentData(label: "Miscellaneous", value: engine.activeMiscellaneousReceipts, color: .secondary),
            SegmentData(label: "Estate & gift", value: engine.activeEstateGiftTax, color: Color(red: 0.30, green: 0.66, blue: 0.51)),
            SegmentData(label: "Novel taxes", value: engine.activeNovelRevenue, color: TaxLabTheme.revenue)
        ].filter { $0.value > 0.01 }
    }

    var spendingSegments: [SegmentData] {
        [
            SegmentData(label: "Net interest", value: engine.activeNetInterestOutlay, color: Color(red: 0.74, green: 0.27, blue: 0.29)),
            SegmentData(label: "Social Security", value: engine.activeSocialSecurityOutlay, color: Color(red: 0.56, green: 0.36, blue: 0.29)),
            SegmentData(label: "Medicare", value: engine.activeMedicareOutlay, color: Color(red: 0.77, green: 0.37, blue: 0.55)),
            SegmentData(label: "Medicaid & CHIP", value: engine.activeMedicaidOutlay, color: Color(red: 0.50, green: 0.38, blue: 0.68)),
            SegmentData(label: "Income security", value: engine.activeIncomeSecurityOutlay, color: Color(red: 0.82, green: 0.61, blue: 0.20)),
            SegmentData(label: "Other mandatory", value: engine.activeOtherMandatoryOutlay, color: Color(red: 0.84, green: 0.50, blue: 0.20)),
            SegmentData(label: "Defense", value: engine.activeDefenseOutlay, color: Color(red: 0.35, green: 0.38, blue: 0.43)),
            SegmentData(label: "Non-defense", value: engine.activeNonDefenseOutlay, color: Color(red: 0.35, green: 0.59, blue: 0.42)),
            SegmentData(label: "Novel programs", value: engine.activeNovelSpending, color: Color(red: 0.18, green: 0.58, blue: 0.66))
        ].filter { $0.value > 0.01 }
    }

    var body: some View {
        let maxTotal = max(engine.activeTotalRevenues, engine.activeTotalOutlays, 1)
        VStack(spacing: 10) {
            FiscalBarRow(
                title: "Revenue",
                symbol: "dollarsign.circle.fill",
                total: engine.activeTotalRevenues,
                baseline: engine.currentBaseline.totalRevenues,
                maxTotal: maxTotal,
                segments: revenueSegments,
                tint: TaxLabTheme.revenue,
                popoverContent: AnyView(RevenuesPopoverContent(engine: engine).frame(width: 320)),
                isPresented: $state.isShowingRevenuesChartPopover
            )
            FiscalBarRow(
                title: "Outlays",
                symbol: "arrow.up.right.circle.fill",
                total: engine.activeTotalOutlays,
                baseline: engine.currentBaseline.totalOutlays,
                maxTotal: maxTotal,
                segments: spendingSegments,
                tint: TaxLabTheme.outlay,
                popoverContent: AnyView(SpendingPopoverContent(engine: engine).frame(width: 340)),
                isPresented: $state.isShowingSpendingChartPopover
            )
        }
    }
}

struct FiscalBarRow: View {
    let title: String
    let symbol: String
    let total: Double
    let baseline: Double
    let maxTotal: Double
    let segments: [ComparisonChart.SegmentData]
    let tint: Color
    let popoverContent: AnyView
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title).font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("Baseline \(formatBillions(baseline))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(formatBillions(total))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5).fill(TaxLabTheme.panelStrong)
                    HStack(spacing: 0) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                            Rectangle()
                                .fill(segment.color)
                                .frame(width: max(0, geometry.size.width * CGFloat(segment.value / maxTotal)))
                                .accessibilityHidden(true)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
            }
            .frame(height: 16)

            HStack {
                Text("\(segments.count) active categories")
                Spacer()
                Label("Hover for breakdown", systemImage: "info.circle")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .refractiveGlass(cornerRadius: 10)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { isPresented = $0 }
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            popoverContent.padding(14)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(formatBillions(total)), baseline \(formatBillions(baseline)), \(segments.count) active categories")
        .accessibilityAction(named: "Show breakdown") { isPresented.toggle() }
    }
}

struct SystemWarningsPanel: View {
    let engine: MacroMathEngine

    private var warningNames: [String] {
        var names: [String] = []
        if engine.isLafferInflectionWarningActive { names.append("Marginal-rate inflection") }
        if engine.isGeopoliticalRiskWarningActive { names.append("Defense readiness") }
        if engine.isRetireePovertyAlertActive { names.append("Retiree welfare") }
        return names
    }

    var body: some View {
        let hasWarnings = !warningNames.isEmpty
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill((hasWarnings ? TaxLabTheme.warning : TaxLabTheme.revenue).opacity(0.12))
                Image(systemName: hasWarnings ? "exclamationmark.triangle.fill" : "checkmark.shield.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hasWarnings ? TaxLabTheme.warning : TaxLabTheme.revenue)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(hasWarnings ? "\(warningNames.count) active scenario warning\(warningNames.count == 1 ? "" : "s")" : "Scenario checks clear")
                    .font(.system(size: 11, weight: .semibold))
                Text(hasWarnings
                     ? warningNames.joined(separator: " · ")
                     : "Tax, defense, and retiree thresholds remain within baseline guardrails.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .refractiveGlass(cornerRadius: 10)
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke((hasWarnings ? TaxLabTheme.warning : TaxLabTheme.revenue).opacity(0.22), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Popover Hover Content Views

struct RevenuesPopoverContent: View {
    let engine: MacroMathEngine
    
    struct PopoverItem: Identifiable {
        var id: String { label }
        let label: String
        let value: Double
        let color: Color
    }
    
    var items: [PopoverItem] {
        return [
            PopoverItem(label: "Individual Income", value: engine.activeIndividualIncomeTax, color: .blue),
            PopoverItem(label: "Payroll Taxes", value: engine.activePayrollTaxTotal, color: .teal),
            PopoverItem(label: "Corporate Taxes", value: engine.activeCorporateIncomeTax, color: .indigo),
            PopoverItem(label: "Excise Taxes", value: engine.activeExciseTaxes, color: .purple),
            PopoverItem(label: "Customs Duties", value: engine.activeCustomsDuties, color: .orange),
            PopoverItem(label: "Misc Receipts", value: engine.activeMiscellaneousReceipts, color: .gray),
            PopoverItem(label: "Estate & Gift", value: engine.activeEstateGiftTax, color: .mint),
            PopoverItem(label: "Novel Taxes", value: engine.activeNovelRevenue, color: .green)
        ].filter { $0.value > 0.01 }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "dollarsign.circle.fill").foregroundStyle(TaxLabTheme.revenue)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Revenue mix").font(.system(size: 13, weight: .semibold))
                    Text("Active scenario").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(formatBillions(engine.activeTotalRevenues))
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            Divider()

            let total = max(1.0, engine.activeTotalRevenues)
            ForEach(items) { item in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(item.color)
                        .frame(width: 10, height: 10)
                    
                    Text(item.label).font(.system(size: 11))
                    
                    Spacer()
                    
                    Text(formatBillions(item.value))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    
                    Text(String(format: "(%.1f%%)", (item.value / total) * 100))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }
                .padding(.vertical, 2)
            }
        }
    }
}

struct SpendingPopoverContent: View {
    let engine: MacroMathEngine
    
    struct PopoverItem: Identifiable {
        var id: String { label }
        let label: String
        let value: Double
        let color: Color
    }
    
    var items: [PopoverItem] {
        return [
            PopoverItem(label: "Net Interest", value: engine.activeNetInterestOutlay, color: .red),
            PopoverItem(label: "Social Security", value: engine.activeSocialSecurityOutlay, color: .brown),
            PopoverItem(label: "Medicare", value: engine.activeMedicareOutlay, color: .pink),
            PopoverItem(label: "Medicaid & CHIP", value: engine.activeMedicaidOutlay, color: Color.purple.opacity(0.6)),
            PopoverItem(label: "Income Security", value: engine.activeIncomeSecurityOutlay, color: .yellow),
            PopoverItem(label: "Other Mandatory", value: engine.activeOtherMandatoryOutlay, color: .orange.opacity(0.6)),
            PopoverItem(label: "Defense", value: engine.activeDefenseOutlay, color: Color(nsColor: .darkGray)),
            PopoverItem(label: "Non-Defense", value: engine.activeNonDefenseOutlay, color: .green),
            PopoverItem(label: "Novel Programs", value: engine.activeNovelSpending, color: .cyan)
        ].filter { $0.value > 0.01 }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.right.circle.fill").foregroundStyle(TaxLabTheme.outlay)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Outlay mix").font(.system(size: 13, weight: .semibold))
                    Text("Active scenario").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(formatBillions(engine.activeTotalOutlays))
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            Divider()

            let total = max(1.0, engine.activeTotalOutlays)
            ForEach(items) { item in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(item.color)
                        .frame(width: 10, height: 10)
                    
                    Text(item.label).font(.system(size: 11))
                    
                    Spacer()
                    
                    Text(formatBillions(item.value))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    
                    Text(String(format: "(%.1f%%)", (item.value / total) * 100))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }
                .padding(.vertical, 2)
            }
        }
    }
}

struct ActiveWarningsPopoverContent: View {
    let engine: MacroMathEngine
    
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(TaxLabTheme.warning.opacity(0.13))
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TaxLabTheme.warning)
                }
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Scenario warnings").font(.system(size: 13, weight: .semibold))
                    Text("Thresholds requiring review").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Divider()

            if engine.isLafferInflectionWarningActive {
                WarningPopoverRow(
                    title: "Marginal-rate inflection",
                    detail: "Individual income exceeds 70% or the corporate statutory rate exceeds 35%; modeled base erosion can reduce returns.",
                    symbol: "percent"
                )
            }

            if engine.isGeopoliticalRiskWarningActive {
                WarningPopoverRow(
                    title: "Defense readiness",
                    detail: "Defense spending is below 80% of baseline, signaling elevated operational and deterrence risk.",
                    symbol: "shield.slash.fill"
                )
            }

            if engine.isRetireePovertyAlertActive {
                WarningPopoverRow(
                    title: "Retiree welfare",
                    detail: "Social Security or Medicare is below 90% of baseline, increasing poverty and coverage risk.",
                    symbol: "heart.slash.fill"
                )
            }
        }
        .frame(width: 310)
    }
}

struct WarningPopoverRow: View {
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(TaxLabTheme.warning)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(TaxLabTheme.warning.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(TaxLabTheme.warning.opacity(0.18), lineWidth: 1))
    }
}
