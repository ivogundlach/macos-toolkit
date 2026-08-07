import Foundation

public struct PositionFormPayload: Equatable {
    public let symbol: String
    public let quantity: String
    public let costBasis: String?
    public let currency: String
    public let account: String?

    public init(symbol: String, quantity: String, costBasis: String?, currency: String, account: String?) {
        self.symbol = symbol
        self.quantity = quantity
        self.costBasis = costBasis
        self.currency = currency
        self.account = account
    }
}

public enum PositionSavePlan {
    case abort(message: String)
    case set(PositionFormPayload)
    case replace(id: Int64, payload: PositionFormPayload)
}

public struct PositionFormDraft {
    public let symbol: String
    public let quantity: String
    public let costBasis: String
    public let currency: String
    public let account: String

    public init(symbol: String, quantity: String, costBasis: String, currency: String, account: String) {
        self.symbol = symbol
        self.quantity = quantity
        self.costBasis = costBasis
        self.currency = currency
        self.account = account
    }

    public var cleanSymbol: String {
        symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    public var cleanQuantity: String {
        quantity.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var cleanCostBasis: String {
        costBasis.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True if `s` is a plain decimal: optional leading "-", ASCII digits, at most
    /// one ".". Rejects "", "abc", "1.2.3", "1e9", "NaN". A trust-boundary check —
    /// the value is still stored verbatim as a string (Swift never computes on it),
    /// so quantity/money precision and trailing zeros are preserved.
    public static func isDecimal(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        var seenDot = false
        var seenDigit = false
        for (i, ch) in t.enumerated() {
            if ch == "-" {
                if i != 0 { return false }
            } else if ch == "." {
                if seenDot { return false }
                seenDot = true
            } else if ch >= "0" && ch <= "9" {
                seenDigit = true
            } else {
                return false
            }
        }
        return seenDigit
    }

    public var canSave: Bool {
        !cleanSymbol.isEmpty
            && Self.isDecimal(cleanQuantity)
            && (cleanCostBasis.isEmpty || Self.isDecimal(cleanCostBasis))
    }

    public func payload() -> PositionFormPayload? {
        guard canSave else { return nil }
        let cleanCurrency = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let cleanAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        return PositionFormPayload(
            symbol: cleanSymbol,
            quantity: cleanQuantity,
            costBasis: cleanCostBasis.isEmpty ? nil : cleanCostBasis,
            currency: cleanCurrency.isEmpty ? "USD" : cleanCurrency,
            account: cleanAccount.isEmpty ? nil : cleanAccount)
    }
}

public func planPositionSave(existingID: Int64?, draft: PositionFormDraft) -> PositionSavePlan {
    guard let payload = draft.payload() else {
        return .abort(message: "Symbol and a numeric quantity are required (cost basis, if set, must be numeric).")
    }
    if let existingID {
        return .replace(id: existingID, payload: payload)
    }
    return .set(payload)
}
