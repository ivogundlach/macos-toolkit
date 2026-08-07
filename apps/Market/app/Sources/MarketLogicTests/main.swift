import Foundation
import MarketCore

@main
struct MarketLogicTestRunner {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            Foundation.exit(1)
        }
    }

    static func unwrap<T>(_ value: T?, _ message: String) -> T {
        guard let value else {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            Foundation.exit(1)
        }
        return value
    }

    static func run(_ name: String, _ body: () async -> Void) async {
        print("CHECK: \(name)")
        await body()
    }

    static func main() async {
        await run("draft normalizes form values for appctl") {
            let normalized = PositionFormDraft(
                symbol: " nvda\n",
                quantity: " 0.1000 ",
                costBasis: " 123.45 ",
                currency: " usd ",
                account: " taxable ")
            let payload = unwrap(normalized.payload(), "normalized draft should be valid")
            expect(normalized.canSave, "normalized draft can save")
            expect(payload.symbol == "NVDA", "symbol uppercases and trims")
            expect(payload.quantity == "0.1000", "quantity trims without numeric coercion")
            expect(payload.costBasis == "123.45", "cost basis trims")
            expect(payload.currency == "USD", "currency uppercases")
            expect(payload.account == "taxable", "account trims")
        }

        await run("blank currency defaults to USD and blank optional fields are omitted") {
            let defaults = PositionFormDraft(
                symbol: "cpsh",
                quantity: "1",
                costBasis: " ",
                currency: " ",
                account: "\n")
            let payload = unwrap(defaults.payload(), "default draft should be valid")
            expect(payload.symbol == "CPSH", "default draft symbol uppercases")
            expect(payload.costBasis == nil, "blank cost basis omitted")
            expect(payload.currency == "USD", "blank currency defaults to USD")
            expect(payload.account == nil, "blank account omitted")
        }

        await run("blank symbol or quantity cannot save") {
            let missingSymbol = PositionFormDraft(symbol: " ", quantity: "1", costBasis: "", currency: "USD", account: "")
            let missingQuantity = PositionFormDraft(symbol: "NVDA", quantity: "\t", costBasis: "", currency: "USD", account: "")
            expect(!missingSymbol.canSave, "blank symbol cannot save")
            expect(missingSymbol.payload() == nil, "blank symbol produces no payload")
            expect(!missingQuantity.canSave, "blank quantity cannot save")
            expect(missingQuantity.payload() == nil, "blank quantity produces no payload")
        }

        await run("non-numeric quantity or cost basis cannot save") {
            let badQty = PositionFormDraft(symbol: "NVDA", quantity: "abc", costBasis: "", currency: "USD", account: "")
            expect(!badQty.canSave, "letters in quantity cannot save")
            expect(badQty.payload() == nil, "non-numeric quantity produces no payload")

            let malformedQty = PositionFormDraft(symbol: "NVDA", quantity: "1.2.3", costBasis: "", currency: "USD", account: "")
            expect(!malformedQty.canSave, "two decimal points cannot save")

            let badCost = PositionFormDraft(symbol: "NVDA", quantity: "1", costBasis: "x", currency: "USD", account: "")
            expect(!badCost.canSave, "non-numeric cost basis cannot save")

            let good = PositionFormDraft(symbol: "NVDA", quantity: "0.1000", costBasis: "-12.5", currency: "USD", account: "")
            expect(good.canSave, "numeric quantity and cost basis can save")
            let payload = unwrap(good.payload(), "valid numeric draft should produce a payload")
            expect(payload.quantity == "0.1000", "quantity preserved verbatim (trailing zeros kept)")
            expect(payload.costBasis == "-12.5", "cost basis preserved verbatim")
        }

        await run("add save plans set and never replace") {
            let draft = PositionFormDraft(symbol: " cpsh ", quantity: " 2 ", costBasis: "", currency: "", account: "")
            guard case .set(let payload) = planPositionSave(existingID: nil, draft: draft) else {
                expect(false, "add should plan .set"); return
            }
            expect(payload.symbol == "CPSH", "add uses normalized symbol")
            expect(payload.quantity == "2", "add uses normalized quantity")
        }

        await run("edit save plans atomic replace and never set") {
            let draft = PositionFormDraft(symbol: " cpsh ", quantity: " 2 ", costBasis: "", currency: "", account: "")
            guard case .replace(let id, let payload) = planPositionSave(existingID: 42, draft: draft) else {
                expect(false, "edit should plan .replace"); return
            }
            expect(id == 42, "replace receives original id")
            expect(payload.symbol == "CPSH", "allowed edit uses normalized symbol")
            expect(payload.quantity == "2", "allowed edit uses normalized quantity")
            expect(payload.currency == "USD", "allowed edit defaults blank currency")
        }

        await run("invalid draft plans neither set nor replace") {
            let draft = PositionFormDraft(symbol: " ", quantity: " 2 ", costBasis: "", currency: "", account: "")
            guard case .abort(let message) = planPositionSave(existingID: 42, draft: draft) else {
                expect(false, "invalid draft should plan .abort"); return
            }
            expect(message.contains("required"), "invalid draft reports requirement")
        }

        print("MarketLogicTests: all checks passed")
    }
}
