import Foundation

struct MarketQuote: Equatable, Sendable {
    let closePriceText: String?
    let weekEnding: String?
    let marketDate: String?
    let fetchedAt: String?
    let source: String?
    let fetchOutcome: String?
    let targetWeekEnding: String?
    let lastAttemptAt: String?
    let lastErrorCode: String?
    let failureCountText: String?
    let retryAfter: String?

    var closePrice: Double? {
        guard let closePriceText else { return nil }
        return Self.finiteDouble(closePriceText, positive: true)
    }

    var failureCount: Int? {
        guard let failureCountText,
              let count = Int(failureCountText.trimmingCharacters(in: .whitespacesAndNewlines)),
              count >= 0 else { return nil }
        return count
    }

    private static func finiteDouble(_ text: String, positive: Bool = false) -> Double? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              let value = Double(normalized),
              value.isFinite,
              !positive || value > 0 else {
            return nil
        }
        return value
    }
}

enum MarketValuationStatus: Equatable, Sendable {
    case weeklyClose
    case refreshIssue
    case stale
    case unsupportedFallback
    case retryFallback
    case costBasisFallback
    case unavailable
    case excluded
}

struct MarketValuation: Equatable, Sendable {
    let value: Double?
    let status: MarketValuationStatus
    let marketDate: String?
    let weekEnding: String?
    let detailDate: String?
}

struct MarketPosition: Identifiable, Equatable, Sendable {
    let id: Int64
    let symbol: String
    let quantityText: String
    let costBasisText: String?
    let currency: String
    let account: String?
    let provenance: String?
    let openedAt: String?
    let updatedAt: String?
    let quote: MarketQuote?

    init(
        id: Int64,
        symbol: String,
        quantityText: String,
        costBasisText: String?,
        currency: String,
        account: String?,
        provenance: String?,
        openedAt: String?,
        updatedAt: String?,
        quote: MarketQuote? = nil
    ) {
        self.id = id
        self.symbol = symbol
        self.quantityText = quantityText
        self.costBasisText = costBasisText
        self.currency = currency
        self.account = account
        self.provenance = provenance
        self.openedAt = openedAt
        self.updatedAt = updatedAt
        self.quote = quote
    }

    var quantity: Double? {
        Self.finiteDouble(quantityText)
    }

    var perShareCostBasis: Double? {
        guard let costBasisText else { return nil }
        return Self.finiteDouble(costBasisText)
    }

    var costBasisValue: Double? {
        Self.checkedProduct(quantity, perShareCostBasis)
    }

    var hasCostBasisText: Bool {
        guard let costBasisText else { return false }
        return !costBasisText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func matches(currencyCode: String) -> Bool {
        let normalizedPositionCurrency = currency
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let normalizedPlanCurrency = currencyCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        return !normalizedPositionCurrency.isEmpty
            && normalizedPositionCurrency == normalizedPlanCurrency
    }

    func valuation(for currencyCode: String, now: Date = Date()) -> MarketValuation {
        guard matches(currencyCode: currencyCode) else {
            return MarketValuation(value: nil, status: .excluded, marketDate: nil, weekEnding: nil, detailDate: nil)
        }

        let basis = costBasisValue
        guard let quote else {
            return MarketValuation(value: basis, status: basis == nil ? .unavailable : .costBasisFallback,
                                    marketDate: nil, weekEnding: nil, detailDate: nil)
        }

        let quoteValue = Self.checkedProduct(quantity, quote.closePrice)
        let quoteDatesValid = Self.isISODate(quote.weekEnding) && Self.isISODate(quote.marketDate)
        if let quoteValue, quoteDatesValid, let weekEnding = quote.weekEnding,
           let marketDate = quote.marketDate {
            let age = Self.newYorkCalendarAge(of: weekEnding, now: now)
            if let age, age >= 0, age <= 8 {
                let status: MarketValuationStatus = quote.fetchOutcome == "ok" ? .weeklyClose : .refreshIssue
                return MarketValuation(value: quoteValue, status: status, marketDate: marketDate,
                                       weekEnding: weekEnding, detailDate: marketDate)
            }
            return MarketValuation(value: quoteValue, status: .stale, marketDate: marketDate,
                                   weekEnding: weekEnding, detailDate: marketDate)
        }

        let fallbackStatus: MarketValuationStatus
        if quote.fetchOutcome == "unsupported" {
            fallbackStatus = basis == nil ? .unavailable : .unsupportedFallback
        } else if quote.fetchOutcome == nil {
            fallbackStatus = basis == nil ? .unavailable : .costBasisFallback
        } else {
            fallbackStatus = basis == nil ? .unavailable : .retryFallback
        }
        return MarketValuation(value: basis, status: fallbackStatus, marketDate: quote.marketDate,
                               weekEnding: quote.weekEnding, detailDate: quote.targetWeekEnding ?? quote.weekEnding)
    }

    private static func finiteDouble(_ text: String) -> Double? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              let value = Double(normalized),
              value.isFinite else {
            return nil
        }
        return value
    }

    private static func checkedProduct(_ lhs: Double?, _ rhs: Double?) -> Double? {
        guard let lhs, let rhs, lhs.isFinite, rhs.isFinite else { return nil }
        let value = lhs * rhs
        return value.isFinite ? value : nil
    }

    private static func isISODate(_ text: String?) -> Bool {
        guard let text, text.count == 10 else { return false }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: text) else { return false }
        return formatter.string(from: date) == text
    }

    private static func newYorkCalendarAge(of weekEnding: String, now: Date) -> Int? {
        guard isISODate(weekEnding) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let parts = weekEnding.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let weekDate = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else {
            return nil
        }
        let current = calendar.startOfDay(for: now)
        let start = calendar.startOfDay(for: weekDate)
        return calendar.dateComponents([.day], from: start, to: current).day
    }
}

enum MarketPortfolioError: LocalizedError, Sendable {
    case databaseUnavailable(String)
    case queryFailed(String)
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .databaseUnavailable(let detail):
            return detail
        case .queryFailed(let detail):
            return detail
        case .invalidOutput(let detail):
            return detail
        }
    }
}

struct MarketPortfolioReader: Sendable {
    private static let sqliteExecutable = "/usr/bin/sqlite3"
    private static let tableProbe = "SELECT 1 AS present FROM sqlite_master WHERE type='table' AND name='position_quotes' LIMIT 1;"
    private static let positionsOnlyQuery = """
        SELECT id, symbol, quantity, cost_basis, currency, account, provenance, opened_at, updated_at
        FROM positions
        ORDER BY id;
        """
    private static let positionsWithQuotesQuery = """
        SELECT p.id, p.symbol, p.quantity, p.cost_basis, p.currency, p.account, p.provenance, p.opened_at, p.updated_at,
               q.close_price AS quote_close_price, q.week_ending AS quote_week_ending,
               q.market_date AS quote_market_date, q.fetched_at AS quote_fetched_at,
               q.source AS quote_source, q.fetch_outcome AS quote_fetch_outcome,
               q.target_week_ending AS quote_target_week_ending, q.last_attempt_at AS quote_last_attempt_at,
               q.last_error_code AS quote_last_error_code, q.failure_count AS quote_failure_count,
               q.retry_after AS quote_retry_after
        FROM positions AS p
        LEFT JOIN position_quotes AS q
          ON upper(trim(p.symbol)) = q.symbol AND upper(trim(p.currency)) = q.currency
        ORDER BY p.id;
        """

    static var databaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Projects/Market/state/market.sqlite")
    }

    static func load() async throws -> [MarketPosition] {
        try await Task.detached(priority: .utility) {
            try readSynchronously()
        }.value
    }

    private static func readSynchronously() throws -> [MarketPosition] {
        let databaseURL = Self.databaseURL
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw MarketPortfolioError.databaseUnavailable(
                "Market portfolio unavailable: the Market database was not found."
            )
        }

        let hasQuotes = try tableExists(at: databaseURL)
        let query = hasQuotes ? positionsWithQuotesQuery : positionsOnlyQuery
        let output: Data
        do {
            output = try runSQLite(databaseURL: databaseURL, query: query)
        } catch {
            // A partially restored v5 database can advertise the table while it is not
            // queryable yet.  Positions-only remains a safe read-only fallback.
            if hasQuotes {
                output = try runSQLite(databaseURL: databaseURL, query: positionsOnlyQuery)
            } else {
                throw error
            }
        }

        guard let json = try? JSONSerialization.jsonObject(with: output),
              let rows = json as? [[String: Any]] else {
            throw MarketPortfolioError.invalidOutput(
                "Market portfolio returned invalid position data."
            )
        }

        return rows.enumerated().compactMap { index, row in
            makePosition(row: row, fallbackID: Int64(index + 1), includesQuoteColumns: hasQuotes)
        }
    }

    private static func tableExists(at databaseURL: URL) throws -> Bool {
        let output = try runSQLite(databaseURL: databaseURL, query: tableProbe)
        guard let text = String(data: output, encoding: .utf8) else {
            throw MarketPortfolioError.invalidOutput("Market schema probe returned invalid data.")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let rows = json as? [[String: Any]] else {
            throw MarketPortfolioError.invalidOutput("Market schema probe returned invalid data.")
        }
        return rows.first.flatMap { int64Value($0["present"]) } == 1
    }

    private static func runSQLite(databaseURL: URL, query: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sqliteExecutable)
        process.arguments = ["-readonly", "-json", databaseURL.path, query]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw MarketPortfolioError.databaseUnavailable(
                "Market portfolio unavailable: could not start the read-only database reader."
            )
        }

        process.waitUntilExit()
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            let detail = String(data: errorOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw MarketPortfolioError.queryFailed(
                detail?.isEmpty == false
                    ? "Market portfolio could not be read: \(detail!)."
                    : "Market portfolio could not be read from the Market database."
            )
        }
        return output
    }

    private static func makePosition(
        row: [String: Any],
        fallbackID: Int64,
        includesQuoteColumns: Bool
    ) -> MarketPosition? {
        let id = int64Value(row["id"]) ?? fallbackID
        let symbol = textValue(row["symbol"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        let quantity = textValue(row["quantity"]) ?? ""
        let currency = textValue(row["currency"]) ?? ""

        guard let symbol, !symbol.isEmpty else { return nil }

        let quote: MarketQuote?
        if includesQuoteColumns,
           row["quote_close_price"] != nil || row["quote_fetch_outcome"] != nil || row["quote_week_ending"] != nil {
            quote = MarketQuote(
                closePriceText: textValue(row["quote_close_price"]),
                weekEnding: textValue(row["quote_week_ending"]),
                marketDate: textValue(row["quote_market_date"]),
                fetchedAt: textValue(row["quote_fetched_at"]),
                source: textValue(row["quote_source"]),
                fetchOutcome: textValue(row["quote_fetch_outcome"]),
                targetWeekEnding: textValue(row["quote_target_week_ending"]),
                lastAttemptAt: textValue(row["quote_last_attempt_at"]),
                lastErrorCode: textValue(row["quote_last_error_code"]),
                failureCountText: textValue(row["quote_failure_count"]),
                retryAfter: textValue(row["quote_retry_after"])
            )
        } else {
            quote = nil
        }

        return MarketPosition(
            id: id,
            symbol: symbol,
            quantityText: quantity,
            costBasisText: textValue(row["cost_basis"]),
            currency: currency,
            account: textValue(row["account"]),
            provenance: textValue(row["provenance"]),
            openedAt: textValue(row["opened_at"]),
            updatedAt: textValue(row["updated_at"]),
            quote: quote
        )
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber {
            return number.int64Value
        }
        if let text = value as? String {
            return Int64(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func textValue(_ value: Any?) -> String? {
        if value is NSNull || value == nil { return nil }
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}
