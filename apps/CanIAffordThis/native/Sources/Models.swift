import Foundation

enum BillingCadence: String, Codable, CaseIterable, Identifiable {
    case oneTime = "one-time"
    case monthly
    case yearly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneTime: return "One-time"
        case .monthly: return "Monthly"
        case .yearly: return "Yearly"
        }
    }

    init(from decoder: Decoder) throws {
        let value = (try? decoder.singleValueContainer().decode(String.self))?
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch value {
        case "one-time", "one_time", "onetime", "once":
            self = .oneTime
        case "yearly", "annual", "annually", "year":
            self = .yearly
        default:
            self = .monthly
        }
    }
}

struct CostItem: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var amount: Double
    var cadence: BillingCadence

    init(
        id: UUID = UUID(),
        name: String,
        amount: Double,
        cadence: BillingCadence
    ) {
        self.id = id
        self.name = name
        self.amount = amount
        self.cadence = cadence
    }

    var monthlyEquivalent: Double {
        switch cadence {
        case .oneTime: return 0
        case .monthly: return amount
        case .yearly: return amount / 12
        }
    }

    var isRecurring: Bool { cadence != .oneTime }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case amount
        case cost
        case cadence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? container.decode(String.self, forKey: .name)) ?? "Cost"

        if let value = try? container.decode(Double.self, forKey: .amount), value.isFinite {
            amount = value
        } else if let value = try? container.decode(Double.self, forKey: .cost), value.isFinite {
            // Legacy Subscription used `cost` instead of `amount`.
            amount = value
        } else if let value = try? container.decode(String.self, forKey: .amount),
                  let parsed = Double(value), parsed.isFinite {
            amount = parsed
        } else if let value = try? container.decode(String.self, forKey: .cost),
                  let parsed = Double(value), parsed.isFinite {
            amount = parsed
        } else {
            amount = 0
        }

        cadence = (try? container.decode(BillingCadence.self, forKey: .cadence)) ?? .monthly
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(amount, forKey: .amount)
        try container.encode(cadence, forKey: .cadence)
    }
}

struct CreditCard: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var outstandingBalance: Double
    var aprPercent: Double
    var plannedMonthlyPayment: Double

    init(
        id: UUID = UUID(),
        name: String,
        outstandingBalance: Double,
        aprPercent: Double,
        plannedMonthlyPayment: Double
    ) {
        self.id = id
        self.name = name
        self.outstandingBalance = outstandingBalance
        self.aprPercent = aprPercent
        self.plannedMonthlyPayment = plannedMonthlyPayment
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case outstandingBalance
        case aprPercent
        case plannedMonthlyPayment
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? container.decode(String.self, forKey: .name)) ?? "Credit card"
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name = "Credit card"
        }
        outstandingBalance = Self.decodeFiniteDouble(container, key: .outstandingBalance)
        aprPercent = Self.decodeFiniteDouble(container, key: .aprPercent)
        plannedMonthlyPayment = Self.decodeFiniteDouble(container, key: .plannedMonthlyPayment)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(outstandingBalance, forKey: .outstandingBalance)
        try container.encode(aprPercent, forKey: .aprPercent)
        try container.encode(plannedMonthlyPayment, forKey: .plannedMonthlyPayment)
    }

    private static func decodeFiniteDouble(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Double {
        if let value = try? container.decode(Double.self, forKey: key), value.isFinite {
            return value
        }
        if let value = try? container.decode(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? container.decode(String.self, forKey: key),
           let parsed = Double(value), parsed.isFinite {
            return parsed
        }
        return 0
    }
}

struct TheoreticalPosition: Codable, Identifiable, Equatable {
    var id: UUID
    var symbol: String
    var quantity: Double
    var costBasis: Double

    init(
        id: UUID = UUID(),
        symbol: String = "Scenario",
        quantity: Double = 0,
        costBasis: Double = 0
    ) {
        self.id = id
        self.symbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Scenario"
            : symbol
        self.quantity = quantity
        self.costBasis = costBasis
    }

    // Compatibility aliases make the per-share meaning explicit at call sites.
    var name: String {
        get { symbol }
        set { symbol = newValue }
    }

    var perShareCostBasis: Double {
        get { costBasis }
        set { costBasis = newValue }
    }

    var modeledValue: Double {
        guard quantity.isFinite, costBasis.isFinite else { return 0 }
        let value = max(0, quantity) * max(0, costBasis)
        return value.isFinite ? value : 0
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case symbol
        case name
        case quantity
        case costBasis
        case perShareCostBasis
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()

        let decodedSymbol = Self.decodeString(container, key: .symbol)
            ?? Self.decodeString(container, key: .name)
            ?? "Scenario"
        symbol = decodedSymbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Scenario"
            : decodedSymbol
        quantity = Self.decodeFiniteDouble(container, key: .quantity)
        costBasis = Self.decodeOptionalFiniteDouble(container, key: .costBasis)
            ?? Self.decodeOptionalFiniteDouble(container, key: .perShareCostBasis)
            ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(symbol, forKey: .symbol)
        try container.encode(quantity, forKey: .quantity)
        try container.encode(costBasis, forKey: .costBasis)
    }

    private static func decodeString(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> String? {
        guard let value = try? container.decode(String.self, forKey: key) else { return nil }
        return value
    }

    private static func decodeOptionalFiniteDouble(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Double? {
        if let value = try? container.decode(Double.self, forKey: key), value.isFinite {
            return value
        }
        if let value = try? container.decode(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? container.decode(String.self, forKey: key),
           let parsed = Double(value), parsed.isFinite {
            return parsed
        }
        return nil
    }

    private static func decodeFiniteDouble(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Double {
        decodeOptionalFiniteDouble(container, key: key) ?? 0
    }
}

enum PlanMode: String, Codable, CaseIterable, Identifiable {
    case breakEven
    case projectWealth

    var id: String { rawValue }

    var title: String {
        switch self {
        case .breakEven: return "Break Even"
        case .projectWealth: return "Project Wealth"
        }
    }
}

enum HorizonOption: CaseIterable, Identifiable, Equatable {
    case months(Int)
    case years(Int)

    static let allCases: [HorizonOption] =
        (1...12).map(HorizonOption.months)
        + [2, 3, 4, 5, 10].map(HorizonOption.years)

    var id: Int { months }

    var months: Int {
        switch self {
        case .months(let value): return value
        case .years(let value): return value * 12
        }
    }

    var title: String {
        switch self {
        case .months(let value):
            return String(value) + " " + (value == 1 ? "month" : "months")
        case .years(let value):
            return String(value) + " " + (value == 1 ? "year" : "years")
        }
    }

    static func from(months: Int) -> HorizonOption {
        let bounded = max(1, min(120, months))
        if let exact = allCases.first(where: { $0.months == bounded }) {
            return exact
        }
        if bounded < 24 {
            return .months(bounded)
        }
        return .years(max(2, min(10, Int((Double(bounded) / 12).rounded()))))
    }
}

struct FinancePlan: Codable, Equatable {
    var currencyCode: String
    var cash: Double
    // Kept in the stored model for legacy data compatibility. Active calculations
    // use the Market portfolio plus theoreticalPositions instead.
    var investments: Double
    var theoreticalPositions: [TheoreticalPosition]
    var annualReturnPercent: Double
    var monthlyIncome: Double
    var essentialSpending: Double
    // Kept for migration and data preservation. It is not used to liquidate investments.
    var protectedReserve: Double
    var horizonMonths: Int
    var testMonthlyCost: Double
    var mode: PlanMode
    var costs: [CostItem]
    var creditCards: [CreditCard]

    init(
        currencyCode: String = "USD",
        cash: Double = 0,
        investments: Double = 0,
        theoreticalPositions: [TheoreticalPosition] = [],
        annualReturnPercent: Double = 5,
        monthlyIncome: Double = 0,
        essentialSpending: Double = 0,
        protectedReserve: Double = 0,
        horizonYears: Double = 30,
        testMonthlyCost: Double = 0,
        subscriptions: [CostItem] = [],
        mode: PlanMode = .breakEven,
        costs: [CostItem]? = nil,
        horizonMonths: Int? = nil,
        creditCards: [CreditCard] = []
    ) {
        self.currencyCode = currencyCode
        self.cash = cash
        self.investments = investments
        self.theoreticalPositions = theoreticalPositions
        self.annualReturnPercent = annualReturnPercent
        self.monthlyIncome = monthlyIncome
        self.essentialSpending = essentialSpending
        self.protectedReserve = protectedReserve
        self.horizonMonths = FinancePlan.normalizedHorizonMonths(
            horizonMonths ?? Int((horizonYears * 12).rounded())
        )
        self.testMonthlyCost = testMonthlyCost
        self.mode = mode
        self.costs = costs ?? subscriptions
        self.creditCards = creditCards
    }

    // Compatibility access for callers that used the pre-wealth planner name.
    var subscriptions: [CostItem] {
        get { costs }
        set { costs = newValue }
    }

    // Compatibility access for migrated callers; the stored representation is month-based.
    var horizonYears: Double {
        get { Double(horizonMonths) / 12 }
        set { horizonMonths = FinancePlan.normalizedHorizonMonths(Int((newValue * 12).rounded())) }
    }

    static func normalizedHorizonMonths(_ value: Int) -> Int {
        let bounded = max(1, min(120, value))
        guard bounded > 12 else { return bounded }
        return HorizonOption.allCases
            .map(\.months)
            .min { lhs, rhs in
                let leftDistance = abs(lhs - bounded)
                let rightDistance = abs(rhs - bounded)
                return leftDistance == rightDistance ? lhs < rhs : leftDistance < rightDistance
            } ?? 120
    }

    private enum CodingKeys: String, CodingKey {
        case currencyCode
        case cash
        case investments
        case theoreticalPositions
        case annualReturnPercent
        case monthlyIncome
        case essentialSpending
        case protectedReserve
        case horizonMonths
        case horizonYears
        case testMonthlyCost
        case mode
        case costs
        case subscriptions
        case creditCards
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        currencyCode = Self.decodeString(container, key: .currencyCode, default: "USD")
        cash = Self.decodeFiniteDouble(container, key: .cash)
        investments = Self.decodeFiniteDouble(container, key: .investments)
        theoreticalPositions = Self.decodeTheoreticalPositions(container, key: .theoreticalPositions)
        annualReturnPercent = Self.decodeFiniteDouble(container, key: .annualReturnPercent, default: 5)
        monthlyIncome = Self.decodeFiniteDouble(container, key: .monthlyIncome)
        essentialSpending = Self.decodeFiniteDouble(container, key: .essentialSpending)
        protectedReserve = Self.decodeFiniteDouble(container, key: .protectedReserve)
        testMonthlyCost = Self.decodeFiniteDouble(container, key: .testMonthlyCost)
        mode = (try? container.decode(PlanMode.self, forKey: .mode)) ?? .breakEven

        let migratedMonths: Int
        if let value = Self.decodeInt(container, key: .horizonMonths) {
            migratedMonths = value
        } else {
            let years = Self.decodeFiniteDouble(container, key: .horizonYears, default: 30)
            migratedMonths = Int((years * 12).rounded())
        }
        horizonMonths = Self.normalizedHorizonMonths(migratedMonths)

        let currentCosts = Self.decodeCostItems(container, key: .costs)
        costs = currentCosts.isEmpty
            ? Self.decodeCostItems(container, key: .subscriptions)
            : currentCosts
        creditCards = Self.decodeCreditCards(container, key: .creditCards)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(currencyCode, forKey: .currencyCode)
        try container.encode(cash, forKey: .cash)
        try container.encode(investments, forKey: .investments)
        try container.encode(theoreticalPositions, forKey: .theoreticalPositions)
        try container.encode(annualReturnPercent, forKey: .annualReturnPercent)
        try container.encode(monthlyIncome, forKey: .monthlyIncome)
        try container.encode(essentialSpending, forKey: .essentialSpending)
        try container.encode(protectedReserve, forKey: .protectedReserve)
        try container.encode(horizonMonths, forKey: .horizonMonths)
        // Keep the legacy value available to older readers while storing months as canonical.
        try container.encode(horizonYears, forKey: .horizonYears)
        try container.encode(testMonthlyCost, forKey: .testMonthlyCost)
        try container.encode(mode, forKey: .mode)
        try container.encode(costs, forKey: .costs)
        try container.encode(creditCards, forKey: .creditCards)
    }

    private static func decodeString(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys,
        default fallback: String
    ) -> String {
        guard let value = try? container.decode(String.self, forKey: key), !value.isEmpty else {
            return fallback
        }
        return value
    }

    private static func decodeFiniteDouble(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys,
        default fallback: Double = 0
    ) -> Double {
        if let value = try? container.decode(Double.self, forKey: key), value.isFinite {
            return value
        }
        if let value = try? container.decode(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? container.decode(String.self, forKey: key),
           let parsed = Double(value), parsed.isFinite {
            return parsed
        }
        return fallback
    }

    private static func decodeInt(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Int? {
        if let value = try? container.decode(Int.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(Double.self, forKey: key), value.isFinite {
            return Int(value.rounded())
        }
        if let value = try? container.decode(String.self, forKey: key),
           let parsed = Double(value), parsed.isFinite {
            return Int(parsed.rounded())
        }
        return nil
    }

    private static func decodeCostItems(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> [CostItem] {
        guard var values = try? container.nestedUnkeyedContainer(forKey: key) else {
            return []
        }

        var decoded: [CostItem] = []
        while !values.isAtEnd {
            if let item = try? values.decode(CostItem.self) {
                decoded.append(item)
            } else {
                // Consume malformed legacy entries individually so valid entries survive migration.
                _ = try? values.decode(IgnoredValue.self)
            }
        }
        return decoded
    }

    private static func decodeCreditCards(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> [CreditCard] {
        guard var values = try? container.nestedUnkeyedContainer(forKey: key) else {
            return []
        }

        var decoded: [CreditCard] = []
        while !values.isAtEnd {
            if let card = try? values.decode(CreditCard.self) {
                decoded.append(card)
            } else {
                // Consume malformed entries individually so valid cards survive migration.
                _ = try? values.decode(IgnoredValue.self)
            }
        }
        return decoded
    }

    private static func decodeTheoreticalPositions(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> [TheoreticalPosition] {
        guard var values = try? container.nestedUnkeyedContainer(forKey: key) else {
            return []
        }

        var decoded: [TheoreticalPosition] = []
        while !values.isAtEnd {
            if let position = try? values.decode(TheoreticalPosition.self) {
                decoded.append(position)
            } else {
                // Consume malformed entries individually so valid scenarios survive migration.
                _ = try? values.decode(IgnoredValue.self)
            }
        }
        return decoded
    }
}

private struct IgnoredValue: Decodable {
    init(from decoder: Decoder) throws {}
}

struct ProjectionPoint: Identifiable {
    let month: Int
    let balance: Double
    let cash: Double
    let investments: Double
    let remainingCardDebt: Double

    var id: Int { month }
    var year: Double { Double(month) / 12 }
    var netWealth: Double { balance }

    init(
        month: Int,
        balance: Double,
        cash: Double,
        investments: Double,
        remainingCardDebt: Double = 0
    ) {
        self.month = month
        self.balance = balance
        self.cash = cash
        self.investments = investments
        self.remainingCardDebt = remainingCardDebt
    }
}

enum BreakEvenStatus: Equatable {
    case solved
    case notNeeded
    case impossible
    case beyondSolverRange

    var title: String {
        switch self {
        case .solved: return "Required annual return"
        case .notNeeded: return "No investment return required"
        case .impossible: return "No finite break-even return"
        case .beyondSolverRange: return "Return exceeds solver range"
        }
    }
}

enum RunwayStatus: Equatable {
    case months(Double)
    case selfSustaining
    case depleted
}

struct WealthResults {
    let recurringMonthly: Double
    let oneTimeTotal: Double
    let startingWealth: Double
    let startingCardDebt: Double
    let endingCash: Double
    let endingInvestments: Double
    let endingCardDebt: Double
    let projectedEndingWealth: Double
    let activeAnnualReturnPercent: Double?
    let requiredAnnualReturnPercent: Double?
    let breakEvenStatus: BreakEvenStatus
    let monthlyCashFlow: Double
    let runwayStatus: RunwayStatus
    let projection: [ProjectionPoint]

    var startingNetWealth: Double { startingWealth }
    var projectedEndingNetWealth: Double { projectedEndingWealth }

    var runwayMonths: Double? {
        if case .months(let value) = runwayStatus { return value }
        if case .depleted = runwayStatus { return 0 }
        return nil
    }
}

enum WealthCalculator {
    private static let lowerAnnualReturnPercent = -100.0
    private static let upperAnnualReturnPercent = 1_000_000.0

    static func calculate(
        _ plan: FinancePlan,
        investmentPrincipal: Double? = nil
    ) -> WealthResults {
        let recurringMonthly = plan.costs.reduce(0) { total, cost in
            safeAdd(total, cost.isRecurring ? nonnegativeFinite(cost.monthlyEquivalent) : 0)
        }
        let oneTimeTotal = plan.costs.reduce(0) { total, cost in
            safeAdd(total, cost.cadence == .oneTime ? nonnegativeFinite(cost.amount) : 0)
        }
        let startingCash = nonnegativeFinite(plan.cash)
        // `nil` preserves the legacy call shape for older callers. Runway's active
        // PlanStore path always supplies its modeled Market + scenario principal.
        let startingInvestments = nonnegativeFinite(investmentPrincipal ?? plan.investments)
        let startingCardDebt = totalStartingCardDebt(plan.creditCards)
        let startingWealth = safeSubtract(
            safeAdd(startingCash, startingInvestments),
            startingCardDebt
        )
        let months = FinancePlan.normalizedHorizonMonths(plan.horizonMonths)
        let monthlyCashFlow = safeSubtract(
            safeSubtract(finite(plan.monthlyIncome), finite(plan.essentialSpending)),
            recurringMonthly
        )
        let debtSchedule = makeDebtSchedule(cards: plan.creditCards, months: months)
        let endingCash = cashAfterSchedule(
            startingCash: startingCash,
            oneTimeTotal: oneTimeTotal,
            monthlyCashFlow: monthlyCashFlow,
            payments: debtSchedule.payments
        )
        let endingCardDebt = debtSchedule.remainingDebt.last ?? startingCardDebt

        let breakEven = solveBreakEven(
            startingWealth: startingWealth,
            startingInvestments: startingInvestments,
            endingCash: endingCash,
            endingCardDebt: endingCardDebt,
            months: months
        )

        let activeRate: Double?
        switch plan.mode {
        case .breakEven:
            activeRate = breakEven.requiredRate
        case .projectWealth:
            activeRate = max(-100, finite(plan.annualReturnPercent))
        }

        // An impossible break-even has no honest active rate. A zero-return line keeps the
        // projection useful without presenting a made-up solved percentage.
        let projectionRate = activeRate ?? 0
        let projection = makeProjection(
            startingCash: startingCash,
            startingInvestments: startingInvestments,
            oneTimeTotal: oneTimeTotal,
            monthlyCashFlow: monthlyCashFlow,
            annualReturnPercent: projectionRate,
            debtSchedule: debtSchedule,
            months: months
        )
        let finalPoint = projection.last ?? ProjectionPoint(
            month: 0,
            balance: startingWealth - oneTimeTotal,
            cash: startingCash - oneTimeTotal,
            investments: startingInvestments,
            remainingCardDebt: startingCardDebt
        )
        let runwayStatus = calculateRunway(
            startingCash: startingCash,
            oneTimeTotal: oneTimeTotal,
            monthlyCashFlow: monthlyCashFlow,
            cards: plan.creditCards
        )

        return WealthResults(
            recurringMonthly: recurringMonthly,
            oneTimeTotal: oneTimeTotal,
            startingWealth: startingWealth,
            startingCardDebt: startingCardDebt,
            endingCash: finalPoint.cash,
            endingInvestments: finalPoint.investments,
            endingCardDebt: finalPoint.remainingCardDebt,
            projectedEndingWealth: finalPoint.balance,
            activeAnnualReturnPercent: activeRate,
            requiredAnnualReturnPercent: breakEven.requiredRate,
            breakEvenStatus: breakEven.status,
            monthlyCashFlow: monthlyCashFlow,
            runwayStatus: runwayStatus,
            projection: projection
        )
    }

    private struct BreakEvenSolve {
        let requiredRate: Double?
        let status: BreakEvenStatus
    }

    private static func solveBreakEven(
        startingWealth: Double,
        startingInvestments: Double,
        endingCash: Double,
        endingCardDebt: Double,
        months: Int
    ) -> BreakEvenSolve {
        let tolerance = max(0.01, abs(startingWealth) * 1e-9)
        guard startingInvestments > tolerance else {
            return abs(
                safeSubtract(
                    safeSubtract(endingCash, endingCardDebt),
                    startingWealth
                )
            ) <= tolerance
                ? BreakEvenSolve(requiredRate: nil, status: .notNeeded)
                : BreakEvenSolve(requiredRate: nil, status: .impossible)
        }

        let differenceAtFloor = safeSubtract(
            safeSubtract(endingCash, endingCardDebt),
            startingWealth
        )
        if abs(differenceAtFloor) <= tolerance {
            return BreakEvenSolve(requiredRate: lowerAnnualReturnPercent, status: .solved)
        }
        if differenceAtFloor > 0 {
            // Even a total investment loss cannot offset excess cash.
            return BreakEvenSolve(requiredRate: nil, status: .impossible)
        }

        let differenceAtCeiling = netWealthDifference(
            endingCash: endingCash,
            endingCardDebt: endingCardDebt,
            startingWealth: startingWealth,
            startingInvestments: compoundInvestment(
                principal: startingInvestments,
                annualReturnPercent: upperAnnualReturnPercent,
                months: months
            )
        )
        guard differenceAtCeiling.isFinite, differenceAtCeiling >= 0 else {
            return BreakEvenSolve(requiredRate: nil, status: .beyondSolverRange)
        }

        var lower = lowerAnnualReturnPercent
        var upper = upperAnnualReturnPercent
        for _ in 0..<100 {
            let middle = (lower + upper) / 2
            let difference = netWealthDifference(
                endingCash: endingCash,
                endingCardDebt: endingCardDebt,
                startingWealth: startingWealth,
                startingInvestments: compoundInvestment(
                    principal: startingInvestments,
                    annualReturnPercent: middle,
                    months: months
                )
            )
            if !difference.isFinite {
                upper = middle
            } else if difference > 0 {
                upper = middle
            } else {
                lower = middle
            }
        }

        return BreakEvenSolve(requiredRate: (lower + upper) / 2, status: .solved)
    }

    private static func makeProjection(
        startingCash: Double,
        startingInvestments: Double,
        oneTimeTotal: Double,
        monthlyCashFlow: Double,
        annualReturnPercent: Double,
        debtSchedule: DebtSchedule,
        months: Int
    ) -> [ProjectionPoint] {
        var cash = safeSubtract(startingCash, oneTimeTotal)
        var investments = startingInvestments
        let monthlyRate = effectiveMonthlyRate(annualReturnPercent)
        var points: [ProjectionPoint] = [
            ProjectionPoint(
                month: 0,
                balance: netWealth(
                    cash: cash,
                    investments: investments,
                    cardDebt: debtSchedule.remainingDebt.first ?? 0
                ),
                cash: cash,
                investments: investments,
                remainingCardDebt: debtSchedule.remainingDebt.first ?? 0
            )
        ]

        for month in 1...months {
            cash = safeAdd(cash, monthlyCashFlow)
            let payment = debtSchedule.payments[month - 1]
            cash = safeSubtract(cash, payment)
            investments = compoundMonthly(investments, monthlyRate: monthlyRate)
            let cardDebt = debtSchedule.remainingDebt[month]
            points.append(
                ProjectionPoint(
                    month: month,
                    balance: netWealth(
                        cash: cash,
                        investments: investments,
                        cardDebt: cardDebt
                    ),
                    cash: cash,
                    investments: investments,
                    remainingCardDebt: cardDebt
                )
            )
        }
        return points
    }

    private struct DebtSchedule {
        let payments: [Double]
        let interests: [Double]
        let remainingDebt: [Double]
    }

    private struct DebtState {
        var balances: [Double]
    }

    private struct DebtMonth {
        let payment: Double
        let interest: Double
        let remainingDebt: Double
        let isPaidOff: Bool
    }

    private static func makeDebtSchedule(
        cards: [CreditCard],
        months: Int
    ) -> DebtSchedule {
        var state = DebtState(
            balances: cards.map { nonnegativeFinite($0.outstandingBalance) }
        )
        var payments: [Double] = []
        var interests: [Double] = []
        var remainingDebt: [Double] = [totalDebt(state.balances)]

        for _ in 0..<months {
            let month = advanceDebt(&state, cards: cards)
            payments.append(month.payment)
            interests.append(month.interest)
            remainingDebt.append(month.remainingDebt)
        }

        return DebtSchedule(
            payments: payments,
            interests: interests,
            remainingDebt: remainingDebt
        )
    }

    private static func advanceDebt(
        _ state: inout DebtState,
        cards: [CreditCard]
    ) -> DebtMonth {
        var totalPayment = 0.0
        var totalInterest = 0.0

        for index in state.balances.indices {
            let balance = nonnegativeFinite(state.balances[index])
            guard balance > 0 else {
                state.balances[index] = 0
                continue
            }

            let card = cards[index]
            let aprPercent = nonnegativeFinite(card.aprPercent)
            let monthlyRate = nonnegativeFinite(aprPercent / 100 / 12)
            let interest = safeMultiply(balance, monthlyRate)
            let balanceAfterInterest = safeAdd(balance, interest)
            let configuredPayment = nonnegativeFinite(card.plannedMonthlyPayment)
            let payment = min(configuredPayment, balanceAfterInterest)
            let remaining = max(0, safeSubtract(balanceAfterInterest, payment))

            state.balances[index] = remaining
            totalInterest = safeAdd(totalInterest, interest)
            totalPayment = safeAdd(totalPayment, payment)
        }

        let remainingDebt = totalDebt(state.balances)
        return DebtMonth(
            payment: totalPayment,
            interest: totalInterest,
            remainingDebt: remainingDebt,
            isPaidOff: remainingDebt <= 0
        )
    }

    private static func calculateRunway(
        startingCash: Double,
        oneTimeTotal: Double,
        monthlyCashFlow: Double,
        cards: [CreditCard]
    ) -> RunwayStatus {
        // Check time-zero depletion before considering a nonnegative monthly flow.
        var cash = safeSubtract(startingCash, oneTimeTotal)
        if cash <= 0 {
            return .depleted
        }

        var state = DebtState(
            balances: cards.map { nonnegativeFinite($0.outstandingBalance) }
        )
        var month = 0

        while true {
            let previousBalances = state.balances
            let debtMonth = advanceDebt(&state, cards: cards)
            let cashChange = safeSubtract(monthlyCashFlow, debtMonth.payment)

            if cashChange < 0 {
                let monthlyOutflow = -cashChange
                if cash <= monthlyOutflow {
                    let fraction = monthlyOutflow > 0
                        ? max(0, min(1, cash / monthlyOutflow))
                        : 0
                    return .months(Double(month) + fraction)
                }
            }

            cash = safeAdd(cash, cashChange)
            month += 1

            if cash <= 0 {
                return .depleted
            }

            // Card payments never increase: once cash is not falling, it cannot begin
            // falling later because a card payment only drops when that card pays off.
            if cashChange >= 0 {
                return .selfSustaining
            }

            if debtMonth.isPaidOff {
                if monthlyCashFlow >= 0 {
                    return .selfSustaining
                }
                let monthlyOutflow = abs(monthlyCashFlow)
                guard monthlyOutflow > 0 else { return .selfSustaining }
                return .months(Double(month) + cash / monthlyOutflow)
            }

            // If every active balance is flat or growing, configured payments remain
            // constant forever; settle the runway arithmetically instead of iterating.
            let debtIsNonDecreasing = zip(previousBalances, state.balances).allSatisfy {
                oldBalance, newBalance in
                oldBalance <= 0 || newBalance >= oldBalance
            }
            if debtIsNonDecreasing {
                let monthlyOutflow = -cashChange
                guard monthlyOutflow > 0 else { return .selfSustaining }
                return .months(Double(month) + cash / monthlyOutflow)
            }
        }
    }

    private static func cashAfterSchedule(
        startingCash: Double,
        oneTimeTotal: Double,
        monthlyCashFlow: Double,
        payments: [Double]
    ) -> Double {
        var cash = safeSubtract(startingCash, oneTimeTotal)
        for payment in payments {
            cash = safeAdd(cash, monthlyCashFlow)
            cash = safeSubtract(cash, payment)
        }
        return cash
    }

    private static func netWealth(
        cash: Double,
        investments: Double,
        cardDebt: Double
    ) -> Double {
        safeSubtract(safeAdd(cash, investments), cardDebt)
    }

    private static func netWealthDifference(
        endingCash: Double,
        endingCardDebt: Double,
        startingWealth: Double,
        startingInvestments: Double
    ) -> Double {
        safeSubtract(
            netWealth(
                cash: endingCash,
                investments: startingInvestments,
                cardDebt: endingCardDebt
            ),
            startingWealth
        )
    }

    private static func totalStartingCardDebt(_ cards: [CreditCard]) -> Double {
        totalDebt(cards.map { nonnegativeFinite($0.outstandingBalance) })
    }

    private static func totalDebt(_ balances: [Double]) -> Double {
        balances.reduce(0) { safeAdd($0, nonnegativeFinite($1)) }
    }

    private static func effectiveMonthlyRate(_ annualReturnPercent: Double) -> Double {
        let annualRate = annualReturnPercent / 100
        guard annualRate > -1 else { return -1 }
        let rate = expm1(log1p(annualRate) / 12)
        return rate.isFinite ? rate : Double.greatestFiniteMagnitude
    }

    private static func compoundMonthly(_ principal: Double, monthlyRate: Double) -> Double {
        guard principal > 0 else { return 0 }
        guard monthlyRate > -1 else { return 0 }
        let value = principal * (1 + monthlyRate)
        return value.isFinite ? value : Double.greatestFiniteMagnitude
    }

    private static func compoundInvestment(
        principal: Double,
        annualReturnPercent: Double,
        months: Int
    ) -> Double {
        guard principal > 0 else { return 0 }
        let annualRate = annualReturnPercent / 100
        guard annualRate > -1 else { return 0 }
        let logarithmicGrowth = Double(months) / 12 * log1p(annualRate)
        guard logarithmicGrowth.isFinite else { return Double.greatestFiniteMagnitude }
        let maximumLog = log(Double.greatestFiniteMagnitude)
        guard logarithmicGrowth < maximumLog else { return Double.greatestFiniteMagnitude }
        let value = principal * exp(logarithmicGrowth)
        return value.isFinite ? value : Double.greatestFiniteMagnitude
    }

    private static func nonnegativeFinite(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return max(0, value)
    }

    private static func safeAdd(_ lhs: Double, _ rhs: Double) -> Double {
        guard lhs.isFinite, rhs.isFinite else { return 0 }
        let value = lhs + rhs
        if value.isFinite { return value }
        return value.sign == .minus ? -Double.greatestFiniteMagnitude : Double.greatestFiniteMagnitude
    }

    private static func safeSubtract(_ lhs: Double, _ rhs: Double) -> Double {
        guard lhs.isFinite, rhs.isFinite else { return 0 }
        return safeAdd(lhs, -rhs)
    }

    private static func safeMultiply(_ lhs: Double, _ rhs: Double) -> Double {
        guard lhs.isFinite, rhs.isFinite else { return 0 }
        guard lhs != 0, rhs != 0 else { return 0 }
        let value = lhs * rhs
        if value.isFinite { return value }
        return (lhs.sign == rhs.sign) ? Double.greatestFiniteMagnitude : -Double.greatestFiniteMagnitude
    }

    private static func finite(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }
}
