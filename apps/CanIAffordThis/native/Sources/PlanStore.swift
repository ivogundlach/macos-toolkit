import Combine
import Foundation

@MainActor
final class PlanStore: ObservableObject {
    @Published var plan: FinancePlan {
        didSet { save() }
    }

    @Published private(set) var marketPositions: [MarketPosition] = []
    @Published private(set) var marketIsLoading = false
    @Published private(set) var marketError: String?
    @Published private(set) var marketLastRefresh: Date?

    private let fileURL: URL

    init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let directory = support.appendingPathComponent(
            "CanIAffordThis",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        fileURL = directory.appendingPathComponent("plan.json")

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(FinancePlan.self, from: data) {
            plan = decoded
        } else {
            // A missing or unreadable file only affects the in-memory default. A valid
            // legacy file is decoded by FinancePlan's migration-aware initializer above.
            plan = FinancePlan()
        }

        refreshMarketPortfolio()
    }

    var results: WealthResults {
        WealthCalculator.calculate(plan, investmentPrincipal: modeledInvestmentTotal)
    }

    var actualInvestmentTotal: Double {
        var total = 0.0
        for position in marketPositions {
            guard let value = position.valuation(for: plan.currencyCode).value,
                  value.isFinite else { continue }
            let next = total + value
            guard next.isFinite else { continue }
            total = next
        }
        return total
    }

    var marketStaleCount: Int {
        marketPositions.reduce(into: 0) { count, position in
            if case .stale = position.valuation(for: plan.currencyCode).status { count += 1 }
        }
    }

    var marketRefreshIssueCount: Int {
        marketPositions.reduce(into: 0) { count, position in
            if case .refreshIssue = position.valuation(for: plan.currencyCode).status { count += 1 }
        }
    }

    var marketFallbackCount: Int {
        marketPositions.reduce(into: 0) { count, position in
            switch position.valuation(for: plan.currencyCode).status {
            case .unsupportedFallback, .retryFallback, .costBasisFallback:
                count += 1
            default:
                break
            }
        }
    }

    var marketUnavailableCount: Int {
        marketPositions.reduce(into: 0) { count, position in
            if case .unavailable = position.valuation(for: plan.currencyCode).status { count += 1 }
        }
    }

    var theoreticalInvestmentTotal: Double {
        plan.theoreticalPositions.reduce(0) { total, position in
            Self.safeAdd(total, position.modeledValue)
        }
    }

    var modeledInvestmentTotal: Double {
        Self.safeAdd(actualInvestmentTotal, theoreticalInvestmentTotal)
    }

    func refreshMarketPortfolio() {
        guard !marketIsLoading else { return }
        marketIsLoading = true
        marketError = nil

        Task { [weak self] in
            do {
                let positions = try await MarketPortfolioReader.load()
                guard !Task.isCancelled else { return }
                self?.marketPositions = positions
                self?.marketLastRefresh = Date()
                self?.marketIsLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                self?.marketError = error.localizedDescription
                self?.marketIsLoading = false
            }
        }
    }

    func addCost() {
        plan.costs.append(
            CostItem(name: "New cost", amount: 0, cadence: .monthly)
        )
    }

    func removeCosts(at offsets: IndexSet) {
        plan.costs.remove(atOffsets: offsets)
    }

    func addCreditCard() {
        plan.creditCards.append(
            CreditCard(
                name: "New card",
                outstandingBalance: 0,
                aprPercent: 0,
                plannedMonthlyPayment: 0
            )
        )
    }

    func removeCreditCards(at offsets: IndexSet) {
        plan.creditCards.remove(atOffsets: offsets)
    }

    func addTheoreticalPosition() {
        plan.theoreticalPositions.append(
            TheoreticalPosition(symbol: "Scenario", quantity: 0, costBasis: 0)
        )
    }

    func removeTheoreticalPosition(id: UUID) {
        plan.theoreticalPositions.removeAll { $0.id == id }
    }

    func reset() {
        plan = FinancePlan()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(plan) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func safeAdd(_ lhs: Double, _ rhs: Double) -> Double {
        guard lhs.isFinite, rhs.isFinite else { return 0 }
        let value = lhs + rhs
        return value.isFinite ? value : Double.greatestFiniteMagnitude
    }
}
