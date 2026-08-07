import Charts
import Foundation
import SwiftUI

struct DashboardView: View {
    @StateObject private var store = PlanStore()
    @State private var showingResetConfirmation = false

    var body: some View {
        ScrollView {
            VStack(spacing: AffordTheme.spacing16) {
                header
                modeCard
                resultRow
                mainGrid
                investmentsCard
                creditCardsCard
                projectionCard
            }
            .padding(AffordTheme.spacing24)
            .frame(maxWidth: 1320)
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItemGroup {
                Picker("Currency", selection: $store.plan.currencyCode) {
                    ForEach(["USD", "EUR", "GBP", "CAD", "AUD"], id: \.self) {
                        Text($0).tag($0)
                    }
                }
                .labelsHidden()
                .frame(width: 88)

                Button("Reset", systemImage: "arrow.counterclockwise") {
                    showingResetConfirmation = true
                }
            }
        }
        .confirmationDialog(
            "Reset all wealth-planning data?",
            isPresented: $showingResetConfirmation
        ) {
            Button("Reset Everything", role: .destructive) { store.reset() }
        } message: {
            Text("This clears the values saved by Runway on this Mac.")
        }
        .frame(minWidth: 980, minHeight: 700)
        .refractiveCanvas()
    }

    private var header: some View {
        HStack(spacing: AffordTheme.spacing12) {
            ZStack {
                LinearGradient(
                    colors: [AffordTheme.accent, AffordTheme.accent.opacity(0.65)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: AffordTheme.cardRadius))

            VStack(alignment: .leading, spacing: AffordTheme.spacing4) {
                Kicker(text: "Wealth planning")
                Text("Runway")
                    .font(.title2.weight(.bold))
            }
            Spacer()
            Label("Saved locally", systemImage: "lock.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private var modeCard: some View {
        Card {
            HStack(spacing: AffordTheme.spacing16) {
                VStack(alignment: .leading, spacing: AffordTheme.spacing4) {
                    Kicker(text: "Planning mode")
                    Text(store.plan.mode == .breakEven ? "Find the return needed to hold net wealth steady" : "Set a return and see projected net wealth")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Planning mode", selection: $store.plan.mode) {
                    ForEach(PlanMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
            }
        }
    }

    private var resultRow: some View {
        HStack(alignment: .top, spacing: AffordTheme.spacing16) {
            Card {
                VStack(alignment: .leading, spacing: AffordTheme.spacing8) {
                    Kicker(text: outcomeKicker, color: outcomeColor)
                    Text(outcomeValue)
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .foregroundStyle(outcomeColor)
                    Text(outcomeDetail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Card {
                VStack(alignment: .leading, spacing: AffordTheme.spacing8) {
                    Kicker(text: "Cash-only runway")
                    Text(runwayValue)
                        .font(AffordTheme.numberFont)
                        .foregroundStyle(runwayColor)
                    Text("One-time costs and actual card payments are deducted first; investments stay invested and do not extend runway.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 360)
        }
    }

    private var mainGrid: some View {
        Grid(
            alignment: .top,
            horizontalSpacing: AffordTheme.spacing16,
            verticalSpacing: AffordTheme.spacing16
        ) {
            GridRow {
                assumptionsCard
                costsCard
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var assumptionsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: AffordTheme.spacing16) {
                sectionHeader(kicker: "Your baseline", title: "Money & assumptions")
                Divider()
                Grid(
                    alignment: .leading,
                    horizontalSpacing: AffordTheme.spacing16,
                    verticalSpacing: AffordTheme.spacing12
                ) {
                    GridRow {
                        CurrencyField(title: "Cash", value: $store.plan.cash, currencyCode: store.plan.currencyCode)
                        EmptyView()
                    }
                    GridRow {
                        CurrencyField(title: "Expected monthly income", value: $store.plan.monthlyIncome, currencyCode: store.plan.currencyCode)
                        CurrencyField(title: "Essential monthly spending", value: $store.plan.essentialSpending, currencyCode: store.plan.currencyCode)
                    }
                    if store.plan.mode == .projectWealth {
                        GridRow {
                            PercentageField(title: "Annual investment return", value: $store.plan.annualReturnPercent)
                            EmptyView()
                        }
                    }
                }

                VStack(alignment: .leading, spacing: AffordTheme.spacing8) {
                    HStack {
                        VStack(alignment: .leading, spacing: AffordTheme.spacing4) {
                            Text("Planning horizon")
                                .font(.subheadline.weight(.medium))
                            Text("Projection and break-even use whole months")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("Horizon", selection: $store.plan.horizonMonths) {
                            ForEach(HorizonOption.allCases) { option in
                                Text(option.title).tag(option.months)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 130)
                    }
                }
                .padding(AffordTheme.spacing12)
                .background(Color.primary.opacity(0.025))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var costsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: AffordTheme.spacing12) {
                HStack {
                    sectionHeader(kicker: "Costs", title: "Recurring & one-time")
                    Spacer()
                    Text(money(store.results.recurringMonthly) + "/mo")
                        .font(AffordTheme.compactNumberFont)
                        .foregroundStyle(AffordTheme.accent)
                }
                Divider()
                if store.plan.costs.isEmpty {
                    ContentUnavailableView {
                        Label("No costs yet", systemImage: "list.bullet.rectangle")
                    } description: {
                        Text("Add monthly, yearly, or one-time costs to the plan.")
                    } actions: {
                        Button("Add Cost", action: store.addCost)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: AffordTheme.spacing8) {
                        ForEach($store.plan.costs) { $cost in
                            CostRow(
                                cost: $cost,
                                currencyCode: store.plan.currencyCode,
                                onDelete: { removeCost(id: cost.id) }
                            )
                        }
                    }
                }
                HStack {
                    Button("Add Cost", systemImage: "plus", action: store.addCost)
                    Spacer()
                    Text("Delete with the row button")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var investmentsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: AffordTheme.spacing12) {
                HStack(alignment: .top) {
                    sectionHeader(kicker: "Investments", title: "Modeled portfolio")
                    Spacer()
                    VStack(alignment: .trailing, spacing: AffordTheme.spacing4) {
                        Kicker(text: "Modeled total")
                        Text(investmentMoney(store.modeledInvestmentTotal))
                            .font(AffordTheme.compactNumberFont)
                        Text("Held throughout the cash-runway projection")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Divider()
                investmentSummary
                Divider()
                marketPositionsSection
                Divider()
                theoreticalPositionsSection
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var investmentSummary: some View {
        VStack(alignment: .leading, spacing: AffordTheme.spacing8) {
            Grid(
                alignment: .leading,
                horizontalSpacing: AffordTheme.spacing24,
                verticalSpacing: AffordTheme.spacing8
            ) {
                GridRow {
                    investmentTotalMetric(
                        kicker: "Market actual",
                        value: investmentMoney(store.actualInvestmentTotal),
                        detail: "Weekly close or cost basis in " + store.plan.currencyCode
                    )
                    investmentTotalMetric(
                        kicker: "Scenario",
                        value: investmentMoney(store.theoreticalInvestmentTotal),
                        detail: "Editable theoretical positions"
                    )
                    investmentTotalMetric(
                        kicker: "Modeled total",
                        value: investmentMoney(store.modeledInvestmentTotal),
                        detail: "Actual plus scenario"
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(marketPortfolioStatusSummary)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func investmentTotalMetric(
        kicker: String,
        value: String,
        detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: AffordTheme.spacing4) {
            Kicker(text: kicker)
            Text(value)
                .font(AffordTheme.compactNumberFont)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var marketPositionsSection: some View {
        VStack(alignment: .leading, spacing: AffordTheme.spacing8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: AffordTheme.spacing4) {
                    HStack(spacing: AffordTheme.spacing8) {
                        Kicker(text: "Market actual")
                        Text("Read-only")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Text("Read-only Market positions use the latest cached weekly close when available; Market fetches the network data.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    store.refreshMarketPortfolio()
                } label: {
                    Label("Reload Market Data", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(store.marketIsLoading)
                .accessibilityLabel("Reload Market Data")
            }

            if store.marketIsLoading {
                HStack(spacing: AffordTheme.spacing8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading Market positions…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let error = store.marketError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(AffordTheme.caution)
            } else if store.marketPositions.isEmpty {
                Text("No Market positions found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                marketPositionsTable
            }

            if let lastRefresh = store.marketLastRefresh {
                Text("Last refreshed " + lastRefresh.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var marketPositionsTable: some View {
        Grid(
            alignment: .leading,
            horizontalSpacing: InvestmentLayout.spacing,
            verticalSpacing: AffordTheme.spacing8
        ) {
            GridRow {
                Text("Symbol")
                    .frame(width: InvestmentLayout.symbol, alignment: .leading)
                Text("Quantity")
                    .frame(width: InvestmentLayout.quantity, alignment: .trailing)
                Text("Cost basis / share")
                    .frame(width: InvestmentLayout.costBasis, alignment: .trailing)
                Text("Weekly close")
                    .frame(width: InvestmentLayout.weeklyClose, alignment: .trailing)
                Text("Value")
                    .frame(width: InvestmentLayout.value, alignment: .trailing)
                Text("Status")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)

            ForEach(store.marketPositions) { position in
                GridRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(position.symbol)
                            .font(.body.weight(.medium))
                        if let account = position.account,
                           !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(account)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: InvestmentLayout.symbol, alignment: .leading)

                    Text(position.quantityText.isEmpty ? "—" : position.quantityText)
                        .font(.body.monospacedDigit())
                        .frame(width: InvestmentLayout.quantity, alignment: .trailing)

                    Text(position.costBasisText?.isEmpty == false ? position.costBasisText! : "Missing")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(position.hasCostBasisText ? .primary : AffordTheme.caution)
                        .frame(width: InvestmentLayout.costBasis, alignment: .trailing)

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(marketWeeklyCloseLabel(for: position))
                            .font(.body.monospacedDigit())
                        Text(marketDateLabel(for: position))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: InvestmentLayout.weeklyClose, alignment: .trailing)

                    Text(marketValueLabel(for: position))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(marketValueColor(for: position))
                        .frame(width: InvestmentLayout.value, alignment: .trailing)

                    Text(marketStatusLabel(for: position))
                        .font(.caption)
                        .foregroundStyle(marketStatusColor(for: position))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, AffordTheme.spacing4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var theoreticalPositionsSection: some View {
        VStack(alignment: .leading, spacing: AffordTheme.spacing8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: AffordTheme.spacing4) {
                    HStack(spacing: AffordTheme.spacing8) {
                        Kicker(text: "Scenario")
                        Text("Editable")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Text("Add hypothetical positions; values use quantity × per-share cost basis in the selected currency.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add Theoretical Position", systemImage: "plus", action: store.addTheoreticalPosition)
                    .controlSize(.small)
            }

            if store.plan.theoreticalPositions.isEmpty {
                Text("No theoretical positions yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Grid(
                    alignment: .leading,
                    horizontalSpacing: InvestmentLayout.spacing,
                    verticalSpacing: AffordTheme.spacing8
                ) {
                    GridRow {
                        Text("Symbol / name")
                            .frame(width: InvestmentLayout.symbol, alignment: .leading)
                        Text("Quantity")
                            .frame(width: InvestmentLayout.quantity, alignment: .trailing)
                        Text("Cost basis / share")
                            .frame(width: InvestmentLayout.costBasis, alignment: .trailing)
                        Text("Modeled value")
                            .frame(width: InvestmentLayout.value, alignment: .trailing)
                        Color.clear.frame(width: InvestmentLayout.action)
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                    ForEach($store.plan.theoreticalPositions) { $position in
                        GridRow {
                            TextField("Scenario", text: $position.symbol)
                                .textFieldStyle(.plain)
                                .frame(width: InvestmentLayout.symbol, alignment: .leading)

                            NumericInput(
                                title: "Quantity",
                                value: $position.quantity
                            )
                            .frame(width: InvestmentLayout.quantity)

                            NumericInput(
                                title: "Cost basis per share",
                                value: $position.costBasis,
                                prefix: CurrencyAdornment.symbol(for: store.plan.currencyCode)
                            )
                            .frame(width: InvestmentLayout.costBasis)

                            Text(investmentMoney(position.modeledValue))
                                .font(.body.monospacedDigit())
                                .frame(width: InvestmentLayout.value, alignment: .trailing)

                            Button {
                                store.removeTheoreticalPosition(id: position.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .frame(width: InvestmentLayout.action)
                            .accessibilityLabel("Delete theoretical position \(position.symbol)")
                        }
                        .padding(.vertical, AffordTheme.spacing4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var creditCardsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: AffordTheme.spacing12) {
                HStack(alignment: .top) {
                    sectionHeader(kicker: "Liabilities", title: "Credit cards")
                    Spacer()
                    VStack(alignment: .trailing, spacing: AffordTheme.spacing4) {
                        Kicker(text: "Outstanding debt")
                        Text(money(store.results.startingCardDebt))
                            .font(AffordTheme.compactNumberFont)
                            .foregroundStyle(store.results.startingCardDebt > 0 ? AffordTheme.danger : .primary)
                    }
                }
                Text("APR adds monthly interest. Planned payments reduce cash and debt, then stop when a card is paid off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                if store.plan.creditCards.isEmpty {
                    ContentUnavailableView {
                        Label("No credit cards yet", systemImage: "creditcard")
                    } description: {
                        Text("Add outstanding balances to include debt in net wealth and cash runway.")
                    } actions: {
                        Button("Add Credit Card", action: store.addCreditCard)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Grid(
                        alignment: .leading,
                        horizontalSpacing: CreditCardLayout.spacing,
                        verticalSpacing: AffordTheme.spacing8
                    ) {
                        GridRow {
                            Text("Card")
                                .frame(width: CreditCardLayout.name, alignment: .leading)
                            Text("Outstanding")
                                .frame(width: CreditCardLayout.balance, alignment: .trailing)
                            Text("APR")
                                .frame(width: CreditCardLayout.apr, alignment: .trailing)
                            Text("Monthly payment")
                                .frame(width: CreditCardLayout.payment, alignment: .trailing)
                            Color.clear.frame(width: CreditCardLayout.action)
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                        ForEach($store.plan.creditCards) { $card in
                            GridRow {
                                TextField("Card name", text: $card.name)
                                    .textFieldStyle(.plain)
                                    .frame(width: CreditCardLayout.name, alignment: .leading)

                                NumericInput(
                                    title: "Outstanding balance",
                                    value: $card.outstandingBalance,
                                    prefix: CurrencyAdornment.symbol(for: store.plan.currencyCode)
                                )
                                .frame(width: CreditCardLayout.balance)

                                NumericInput(
                                    title: "APR",
                                    value: $card.aprPercent,
                                    suffix: "%"
                                )
                                .frame(width: CreditCardLayout.apr)

                                NumericInput(
                                    title: "Monthly payment",
                                    value: $card.plannedMonthlyPayment,
                                    prefix: CurrencyAdornment.symbol(for: store.plan.currencyCode)
                                )
                                .frame(width: CreditCardLayout.payment)

                                Button {
                                    removeCreditCard(id: card.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                                .frame(width: CreditCardLayout.action)
                                .accessibilityLabel("Delete \(card.name)")
                            }
                            .padding(.vertical, AffordTheme.spacing4)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !store.plan.creditCards.isEmpty {
                    HStack {
                        Button("Add Credit Card", systemImage: "plus", action: store.addCreditCard)
                        Spacer()
                        Text("Delete with the row button")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var projectionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: AffordTheme.spacing16) {
                sectionHeader(kicker: "Long-term view", title: "Net wealth projection")
                HStack(alignment: .top, spacing: AffordTheme.spacing24) {
                    Chart(store.results.projection) { point in
                        AreaMark(
                            x: .value("Month", point.month),
                            y: .value("Net wealth", point.balance)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [AffordTheme.accent.opacity(0.28), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        LineMark(
                            x: .value("Month", point.month),
                            y: .value("Net wealth", point.balance)
                        )
                        .foregroundStyle(
                            store.results.projectedEndingWealth >= 0
                                ? AffordTheme.accent : AffordTheme.danger
                        )
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    .chartXAxis {
                        AxisMarks(values: chartAxisValues) { value in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel {
                                if let month = value.as(Int.self) {
                                    Text(axisLabel(for: month))
                                }
                            }
                        }
                    }
                    .chartXAxisLabel("Months")
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let number = value.as(Double.self) {
                                    Text(moneyCompact(number))
                                }
                            }
                        }
                    }
                    .frame(minHeight: 190)

                    VStack(spacing: AffordTheme.spacing12) {
                        metric(
                            "Starting net wealth",
                            money(store.results.startingWealth),
                            "Cash plus investments less current card debt"
                        )
                        metric(
                            "Ending cash",
                            money(store.results.endingCash),
                            "Cash balance after income and costs"
                        )
                        metric(
                            "Ending investments",
                            money(store.results.endingInvestments),
                            store.plan.mode == .breakEven ? "Compounded at the required return" : "Compounded at your selected return"
                        )
                        metric(
                            "Remaining card debt",
                            money(store.results.endingCardDebt),
                            "Liability after scheduled interest and payments"
                        )
                    }
                    .frame(width: 300)
                }
                Text(projectionFootnote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var outcomeKicker: String {
        store.plan.mode == .breakEven ? store.results.breakEvenStatus.title : "Projected ending net wealth"
    }

    private var outcomeValue: String {
        switch store.plan.mode {
        case .breakEven:
            if let rate = store.results.requiredAnnualReturnPercent {
                return percent(rate)
            }
            return store.results.breakEvenStatus == .notNeeded ? "Not needed" : "—"
        case .projectWealth:
            return money(store.results.projectedEndingWealth)
        }
    }

    private var outcomeDetail: String {
        switch store.plan.mode {
        case .breakEven:
            switch store.results.breakEvenStatus {
            case .solved:
                return "Annual investment return that brings ending net wealth back to "
                    + money(store.results.startingWealth)
                    + " over " + horizonTitle + "."
            case .notNeeded:
                return "Ending net wealth already matches the starting amount without investment growth."
            case .impossible:
                return "No return can reach starting net wealth with the available investment balance."
            case .beyondSolverRange:
                return "The required return is above the bounded solver range; increase investments or adjust costs."
            }
        case .projectWealth:
            return "Ending net wealth after "
                + horizonTitle
                + " at "
                + percent(store.results.activeAnnualReturnPercent ?? 0)
                + " annual return."
        }
    }

    private var outcomeColor: Color {
        switch store.plan.mode {
        case .projectWealth: return AffordTheme.accent
        case .breakEven:
            return store.results.breakEvenStatus == .solved || store.results.breakEvenStatus == .notNeeded
                ? AffordTheme.accent
                : AffordTheme.danger
        }
    }

    private var runwayValue: String {
        switch store.results.runwayStatus {
        case .months(let value): return String(format: "%.1f months", value)
        case .selfSustaining: return "Self-sustaining"
        case .depleted: return "At zero now"
        }
    }

    private var runwayColor: Color {
        if case .months = store.results.runwayStatus { return AffordTheme.caution }
        if case .depleted = store.results.runwayStatus { return AffordTheme.danger }
        return AffordTheme.accent
    }

    private var projectionFootnote: String {
        switch store.plan.mode {
        case .breakEven:
            if store.results.activeAnnualReturnPercent == nil {
                return "No finite break-even rate is available; the chart shows a 0% reference projection. Cash runway includes actual card payments and keeps investments held."
            }
            return "Projection uses the solved break-even rate. Cash runway includes actual card payments; investments stay invested and are never liquidated."
        case .projectWealth:
            return "Projection uses your selected annual return. Cash runway includes actual card payments; investments stay invested and are never liquidated."
        }
    }

    private var horizonTitle: String {
        HorizonOption.from(months: store.plan.horizonMonths).title
    }

    private var chartStride: Int {
        let months = store.plan.horizonMonths
        if months <= 12 { return max(1, months / 4) }
        if months <= 60 { return 12 }
        return 24
    }

    private var chartAxisValues: [Int] {
        var values = Array(stride(from: 0, through: store.plan.horizonMonths, by: chartStride))
        if values.last != store.plan.horizonMonths {
            values.append(store.plan.horizonMonths)
        }
        return values
    }

    private func axisLabel(for month: Int) -> String {
        month == 0 ? "0" : String(month)
    }

    private func removeCost(id: UUID) {
        store.plan.costs.removeAll { $0.id == id }
    }

    private func removeCreditCard(id: UUID) {
        store.plan.creditCards.removeAll { $0.id == id }
    }

    private func marketValueLabel(for position: MarketPosition) -> String {
        guard let value = position.valuation(for: store.plan.currencyCode).value else {
            return position.matches(currencyCode: store.plan.currencyCode) ? "Unavailable" : "Excluded"
        }
        return investmentMoney(value)
    }

    private func marketValueColor(for position: MarketPosition) -> Color {
        switch position.valuation(for: store.plan.currencyCode).status {
        case .excluded:
            return .secondary
        case .weeklyClose:
            return .primary
        default:
            return AffordTheme.caution
        }
    }

    private func marketStatusLabel(for position: MarketPosition) -> String {
        let valuation = position.valuation(for: store.plan.currencyCode)
        guard position.matches(currencyCode: store.plan.currencyCode) else {
            let currency = position.currency.trimmingCharacters(in: .whitespacesAndNewlines)
            return currency.isEmpty ? "Excluded · currency unavailable" : "Excluded · \(currency)"
        }

        switch valuation.status {
        case .weeklyClose:
            return "Weekly close · \(valuation.marketDate ?? valuation.weekEnding ?? "date unavailable")"
        case .refreshIssue:
            return "Weekly close · refresh issue · \(valuation.marketDate ?? valuation.weekEnding ?? "date unavailable")"
        case .stale:
            return "Stale weekly close · \(valuation.marketDate ?? valuation.weekEnding ?? "date unavailable")"
        case .unsupportedFallback:
            return "Unsupported · cost-basis fallback · \(valuation.detailDate ?? "week unavailable")"
        case .retryFallback:
            return "Refresh issue · cost-basis fallback · \(valuation.detailDate ?? "week unavailable")"
        case .costBasisFallback:
            return "Cost-basis fallback"
        case .unavailable:
            if position.quantity == nil { return "Unavailable · quantity" }
            return position.hasCostBasisText ? "Unavailable · cost basis" : "Unavailable · no quote or cost basis"
        case .excluded:
            return "Excluded"
        }
    }

    private func marketStatusColor(for position: MarketPosition) -> Color {
        switch position.valuation(for: store.plan.currencyCode).status {
        case .excluded:
            return .secondary
        case .weeklyClose:
            return AffordTheme.accent
        default:
            return AffordTheme.caution
        }
    }

    private func marketWeeklyCloseLabel(for position: MarketPosition) -> String {
        guard position.matches(currencyCode: store.plan.currencyCode),
              let closePrice = position.quote?.closePrice else { return "—" }
        return investmentMoney(closePrice)
    }

    private func marketDateLabel(for position: MarketPosition) -> String {
        guard position.matches(currencyCode: store.plan.currencyCode),
              let quote = position.quote else { return "No cached close" }
        if let marketDate = quote.marketDate { return marketDate }
        if let target = quote.targetWeekEnding { return "Week of \(target)" }
        return "Date unavailable"
    }

    private var marketPortfolioStatusSummary: String {
        "Portfolio status · stale \(store.marketStaleCount) · refresh issues \(store.marketRefreshIssueCount) · cost-basis fallback \(store.marketFallbackCount) · unavailable \(store.marketUnavailableCount)"
    }

    private func sectionHeader(kicker: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: AffordTheme.spacing4) {
            Kicker(text: kicker)
            Text(title).font(.headline)
        }
    }

    private func metric(_ kicker: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: AffordTheme.spacing4) {
            Kicker(text: kicker)
            Text(value)
                .font(AffordTheme.compactNumberFont)
                .foregroundStyle(value.hasPrefix("-") ? AffordTheme.danger : .primary)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func money(_ value: Double) -> String {
        guard value.isFinite else { return "Beyond range" }
        return value.formatted(
            .currency(code: store.plan.currencyCode)
                .precision(.fractionLength(0))
        )
    }

    private func investmentMoney(_ value: Double) -> String {
        guard value.isFinite else { return "Beyond range" }
        return value.formatted(
            .currency(code: store.plan.currencyCode)
                .precision(.fractionLength(2))
        )
    }

    private func moneyCompact(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        let sign = value < 0 ? "-" : ""
        let absolute = abs(value)
        if absolute >= 1_000_000 {
            return sign + String(format: "%.1fM", absolute / 1_000_000)
        }
        if absolute >= 1_000 {
            return sign + String(format: "%.0fK", absolute / 1_000)
        }
        return sign + String(format: "%.0f", absolute)
    }

    private func percent(_ value: Double) -> String {
        guard value.isFinite else { return "Beyond range" }
        return value.formatted(.number.precision(.fractionLength(1))) + "%"
    }
}

private enum CreditCardLayout {
    static let name: CGFloat = 180
    static let balance: CGFloat = 130
    static let apr: CGFloat = 100
    static let payment: CGFloat = 145
    static let action: CGFloat = 24
    static let spacing: CGFloat = 12
}

private enum InvestmentLayout {
    static let symbol: CGFloat = 190
    static let quantity: CGFloat = 110
    static let costBasis: CGFloat = 150
    static let weeklyClose: CGFloat = 150
    static let value: CGFloat = 150
    static let action: CGFloat = 24
    static let spacing: CGFloat = 12
}

private enum CurrencyAdornment {
    static func symbol(for code: String) -> String {
        switch code.uppercased() {
        case "EUR": return "€"
        case "GBP": return "£"
        case "CAD": return "CA$"
        case "AUD": return "A$"
        default: return "$"
        }
    }
}

private struct NumericInput: View {
    let title: String
    @Binding var value: Double
    let prefix: String?
    let suffix: String?

    @State private var draft: String
    @FocusState private var isFocused: Bool

    init(
        title: String,
        value: Binding<Double>,
        prefix: String? = nil,
        suffix: String? = nil
    ) {
        self.title = title
        self._value = value
        self.prefix = prefix
        self.suffix = suffix
        self._draft = State(initialValue: Self.plainString(value.wrappedValue))
    }

    var body: some View {
        HStack(spacing: AffordTheme.spacing4) {
            if let prefix {
                Text(prefix)
                    .foregroundStyle(.secondary)
            }

            TextField(title, text: $draft)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .focused($isFocused)
                .onSubmit { commit() }
                .onChange(of: draft) { _, newValue in
                    guard isFocused, let parsed = Self.parse(newValue) else { return }
                    value = parsed
                }

            if let suffix {
                Text(suffix)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, AffordTheme.spacing8)
        .padding(.vertical, AffordTheme.spacing4)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .onChange(of: isFocused) { _, focused in
            if focused {
                draft = Self.plainString(value)
            } else {
                commit()
            }
        }
        .onChange(of: value) { _, newValue in
            guard !isFocused else { return }
            draft = Self.plainString(newValue)
        }
    }

    private func commit() {
        guard let parsed = Self.parse(draft) else {
            draft = Self.plainString(value)
            return
        }
        value = parsed
        draft = Self.plainString(parsed)
    }

    private static func parse(_ text: String) -> Double? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized != "-",
              normalized != ".",
              normalized != "-." else {
            return nil
        }
        guard let parsed = Double(normalized), parsed.isFinite else { return nil }
        return parsed
    }

    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    private static func plainString(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        return formatter.string(from: NSNumber(value: value)) ?? "0"
    }
}

private struct CurrencyField: View {
    let title: String
    @Binding var value: Double
    let currencyCode: String

    var body: some View {
        VStack(alignment: .leading, spacing: AffordTheme.spacing4) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            NumericInput(
                title: title,
                value: $value,
                prefix: CurrencyAdornment.symbol(for: currencyCode)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PercentageField: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: AffordTheme.spacing4) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            NumericInput(title: title, value: $value, suffix: "%")
        }
    }
}

private struct CostRow: View {
    @Binding var cost: CostItem
    let currencyCode: String
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: AffordTheme.spacing8) {
            TextField("Name", text: $cost.name)
                .textFieldStyle(.plain)
                .frame(minWidth: 80, maxWidth: .infinity)

            NumericInput(
                title: "Amount",
                value: $cost.amount,
                prefix: CurrencyAdornment.symbol(for: currencyCode)
            )
                .frame(width: 110)

            Picker("Cadence", selection: $cost.cadence) {
                ForEach(BillingCadence.allCases) { cadence in
                    Text(cadence.title).tag(cadence)
                }
            }
            .labelsHidden()
            .frame(width: 100)

            if cost.isRecurring {
                Text(
                    cost.monthlyEquivalent.formatted(
                        .currency(code: currencyCode)
                            .precision(.fractionLength(2))
                    ) + "/mo"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
            } else {
                Text("Charged now")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 100, alignment: .trailing)
            }

            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .accessibilityLabel("Delete \(cost.name)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, AffordTheme.spacing4)
    }
}
