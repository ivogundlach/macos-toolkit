import Foundation
import Observation

/// The real-time macroeconomic math engine for the interactive simulation sandbox.
/// Conforms to `@Observable` for modern SwiftUI bindings.
@Observable
public final class MacroMathEngine {
    
    // --- Model Configuration Constants ---
    public let effectiveInterestRate: Double = 0.04
    
    // --- Baseline Fractions ---
    // Since some baseline revenues are aggregated, we apportion them based on CBO/Treasury definitions.
    private let capitalGainsFraction: Double = 0.15
    private let corpStatutoryFraction: Double = 0.80
    private let giltiFraction: Double = 0.10
    private let beatFraction: Double = 0.05
    private let camtFraction: Double = 0.03
    private let buybackFraction: Double = 0.02
    
    // --- Progressive Income Tax Bracket Revenue Shares ---
    // Approximate share of ordinary income tax revenue generated per bracket.
    // Source: IRS Statistics of Income, derived from 2023–2024 tax year data.
    // These sum to ~0.85 (the remaining 0.15 is capital gains, tracked separately).
    public struct BracketInfo {
        public let label: String
        public let baselineRate: Double
        public let revenueShare: Double  // fraction of total individualIncomeTax
        public let incomeRange: String
    }
    
    public let brackets: [BracketInfo] = [
        BracketInfo(label: "10% Bracket",  baselineRate: 0.10, revenueShare: 0.01,  incomeRange: "$0 – $11,925"),
        BracketInfo(label: "12% Bracket",  baselineRate: 0.12, revenueShare: 0.04,  incomeRange: "$11,926 – $48,475"),
        BracketInfo(label: "22% Bracket",  baselineRate: 0.22, revenueShare: 0.10,  incomeRange: "$48,476 – $103,350"),
        BracketInfo(label: "24% Bracket",  baselineRate: 0.24, revenueShare: 0.14,  incomeRange: "$103,351 – $197,300"),
        BracketInfo(label: "32% Bracket",  baselineRate: 0.32, revenueShare: 0.08,  incomeRange: "$197,301 – $250,525"),
        BracketInfo(label: "35% Bracket",  baselineRate: 0.35, revenueShare: 0.12,  incomeRange: "$250,526 – $626,350"),
        BracketInfo(label: "37% Bracket",  baselineRate: 0.37, revenueShare: 0.36,  incomeRange: "Over $626,350")
    ]
    
    // --- Selected Year ---
    public var selectedYear: Int = 2026
    
    // --- Extraction Sliders (Tax Rates / Multipliers) ---
    
    // Progressive bracket rates (user-adjustable, default = statutory rate)
    public var bracket10Rate: Double = 0.10
    public var bracket12Rate: Double = 0.12
    public var bracket22Rate: Double = 0.22
    public var bracket24Rate: Double = 0.24
    public var bracket32Rate: Double = 0.32
    public var bracket35Rate: Double = 0.35
    public var bracket37Rate: Double = 0.37
    
    // Helper: array of current bracket rates (ordered to match `brackets`)
    public var bracketRates: [Double] {
        [bracket10Rate, bracket12Rate, bracket22Rate, bracket24Rate, bracket32Rate, bracket35Rate, bracket37Rate]
    }
    
    // Capital Gains (separate from ordinary income brackets)
    public var capitalGainsRate: Double = 0.20
    public var socialSecurityRate: Double = 0.124
    public var medicareRate: Double = 0.029
    public var futaRate: Double = 0.06
    public var corporateStatutoryRate: Double = 0.21
    public var camtRate: Double = 0.15
    public var giltiRate: Double = 0.105
    public var beatRate: Double = 0.10
    public var stockBuybackRate: Double = 0.01
    
    // Multipliers (1.0 = baseline rate, e.g. 100%)
    public var exciseMultiplier: Double = 1.0
    public var customsMultiplier: Double = 1.0
    public var miscMultiplier: Double = 1.0
    
    // Placeholder Taxes (additional flat revenue in billions of USD, initialized at 0.0)
    public var placeholderTax1: Double = 0.0
    public var placeholderTax2: Double = 0.0
    public var placeholderTax3: Double = 0.0

    // --- Current-law Estate & Gift tax (surfaced out of Misc receipts; ~$30B base) ---
    public var estateGiftMultiplier: Double = 1.0

    // --- Novel / Proposed Revenue (default 0 = OFF; dial up to researched full-implementation yield) ---
    // Each is a single closed-form term: yield = control * yieldPerUnit (compute-light).
    public var vatRate: Double = 0.0                  // 0–0.20 ; ~$68B per 1 percentage point
    public var nationalSalesTaxRate: Double = 0.0     // 0–0.25 ; ~$60B per 1 percentage point
    public var digitalServicesRate: Double = 0.0      // 0–0.10 ; ~$15B at 3%
    public var wealthTaxYield: Double = 0.0           // 0–330 ($B) ; Warren 2%/3% plan ≈ $280B (contested)
    public var landValueTaxRate: Double = 0.0         // 0–0.05 ; ~$230B per 1% of ~$23T land base
    public var carbonPricePerTon: Double = 0.0        // 0–150 ($/ton) ; ~$4.2B per $1/ton
    public var vmtCentsPerMile: Double = 0.0          // 0–10 (¢/mi) ; ~$32B per 1¢/mi
    public var sodaTaxYield: Double = 0.0             // 0–25 ($B)
    public var financialTransactionRate: Double = 0.0 // 0–0.005 ; ~$78B at 0.1% (0.001)
    public var bankLevyYield: Double = 0.0            // 0–30 ($B)
    public var estateExpansionYield: Double = 0.0     // 0–60 ($B added, Sanders 99.5% Act ≈ +$43B)

    // Researched per-unit yields (billions). Sources in wiki/sources.md & the 2026-06-25 catalog.
    private let estateGiftBaseline: Double = 30.0
    private let vatYieldPerPoint: Double = 6800.0          // $68B at rate 0.01
    private let salesYieldPerPoint: Double = 6000.0        // $60B at rate 0.01
    private let digitalYieldPerPoint: Double = 500.0       // $15B at rate 0.03
    private let landValueYieldPerPoint: Double = 23000.0   // $230B at rate 0.01
    private let carbonYieldPerDollarTon: Double = 4.2      // $210B at $50/ton
    private let vmtYieldPerCent: Double = 32.0             // $32B at 1¢/mi
    private let fttYieldPerPoint: Double = 78000.0         // $78B at rate 0.001 (0.1%)

    // --- Allocation Sliders (Outlays Multipliers / Placeholders) ---
    public var netInterestMultiplier: Double = 1.0
    public var socialSecurityAllocationMultiplier: Double = 1.0
    public var medicareAllocationMultiplier: Double = 1.0
    public var medicaidAllocationMultiplier: Double = 1.0
    public var incomeSecurityAllocationMultiplier: Double = 1.0
    public var otherMandatoryAllocationMultiplier: Double = 1.0
    public var defenseAllocationMultiplier: Double = 1.0
    public var nonDefenseAllocationMultiplier: Double = 1.0
    
    // Placeholder Expenditures (additional flat outlays in billions of USD, initialized at 0.0)
    public var placeholderExpenditure1: Double = 0.0
    public var placeholderExpenditure2: Double = 0.0
    public var placeholderExpenditure3: Double = 0.0

    // --- Non-Defense Discretionary, split into named programs (multipliers, 1.0 = baseline) ---
    // Baselines sum to $996B (FY26 non-defense discretionary).
    public var veteransMultiplier: Double = 1.0
    public var educationMultiplier: Double = 1.0
    public var transportationMultiplier: Double = 1.0
    public var healthNonMedMultiplier: Double = 1.0
    public var scienceMultiplier: Double = 1.0
    public var internationalMultiplier: Double = 1.0
    public var justiceMultiplier: Double = 1.0
    public var environmentMultiplier: Double = 1.0
    public var housingMultiplier: Double = 1.0
    public var energyMultiplier: Double = 1.0
    public var commerceMultiplier: Double = 1.0
    public var generalGovMultiplier: Double = 1.0

    private let baseVeterans: Double = 135.0
    private let baseEducation: Double = 90.0
    private let baseTransportation: Double = 110.0
    private let baseHealthNonMed: Double = 110.0
    private let baseScience: Double = 45.0
    private let baseInternational: Double = 70.0
    private let baseJustice: Double = 75.0
    private let baseEnvironment: Double = 45.0
    private let baseHousing: Double = 65.0
    private let baseEnergy: Double = 30.0
    private let baseCommerce: Double = 25.0
    private let baseGeneralGov: Double = 196.0

    // --- Novel / Proposed Spending Programs (default 0 = OFF; dial up to researched full cost, $B) ---
    public var ubiSpend: Double = 0.0                 // 0–4000 ; ~$3,100B at $1k/mo/adult
    public var medicareForAllSpend: Double = 0.0      // 0–3500 ; ~$3,000B net new federal
    public var universalChildcareSpend: Double = 0.0  // 0–400  ; ~$200B
    public var jobGuaranteeSpend: Double = 0.0        // 0–800  ; ~$500B
    public var freeCollegeSpend: Double = 0.0         // 0–120  ; ~$55B
    public var babyBondsSpend: Double = 0.0           // 0–100  ; ~$60B
    public var paidLeaveSpend: Double = 0.0           // 0–80   ; ~$40B
    public var sovereignWealthFundSpend: Double = 0.0 // 0–350  ; annual contribution

    // --- Net Interest Lock ---
    public var isNetInterestLocked: Bool = true
    
    // --- Initializer ---
    public init() {}
    
    // --- Active Baseline Reference ---
    public var currentBaseline: BaselineData.FiscalYearData {
        return BaselineData.baseline2026.first(where: { $0.year == selectedYear })
            ?? BaselineData.baseline2026.last!
    }
    
    // --- Real-time Calculations: Active Revenues ---
    
    public var activeIndividualIncomeTax: Double {
        let baseTotal = currentBaseline.individualIncomeTax
        
        // Sum revenue from each progressive bracket
        var ordinaryTotal = 0.0
        let rates = bracketRates
        for i in 0..<brackets.count {
            let info = brackets[i]
            let baseBracketRevenue = baseTotal * info.revenueShare
            let userRate = rates[i]
            let baseRate = info.baselineRate
            
            // Scale: proportional to rate change from baseline
            let scale = userRate / baseRate
            // Elasticity 0.25: behavioral response reduces base as rate rises
            let elasticityFactor = max(0.0, 1.0 - 0.25 * (userRate - baseRate) / baseRate)
            ordinaryTotal += baseBracketRevenue * scale * elasticityFactor
        }
        
        // Capital gains (separate, not part of progressive brackets)
        let baseCapGains = baseTotal * capitalGainsFraction
        let capScale = capitalGainsRate / 0.20
        let capElasticity = max(0.0, 1.0 - 0.25 * (capitalGainsRate - 0.20) / 0.20)
        let activeCapGains = baseCapGains * capScale * capElasticity
        
        return ordinaryTotal + activeCapGains
    }
    
    /// Revenue generated by a single bracket at current user rate.
    public func activeBracketRevenue(index: Int) -> Double {
        let baseTotal = currentBaseline.individualIncomeTax
        let info = brackets[index]
        let userRate = bracketRates[index]
        let baseRate = info.baselineRate
        let baseBracketRevenue = baseTotal * info.revenueShare
        let scale = userRate / baseRate
        let elasticityFactor = max(0.0, 1.0 - 0.25 * (userRate - baseRate) / baseRate)
        return baseBracketRevenue * scale * elasticityFactor
    }
    
    public var activeSocialSecurityTax: Double {
        let ssScale = socialSecurityRate / 0.124
        let ssBaseFactor = max(0.0, 1.0 - 0.10 * (socialSecurityRate - 0.124) / 0.124)
        return currentBaseline.payrollSocialSecurityOASDI * ssScale * ssBaseFactor
    }
    
    public var activeMedicareTax: Double {
        let medScale = medicareRate / 0.029
        let medBaseFactor = max(0.0, 1.0 - 0.10 * (medicareRate - 0.029) / 0.029)
        return currentBaseline.payrollMedicareHI * medScale * medBaseFactor
    }
    
    public var activeFutaTax: Double {
        let futaScale = futaRate / 0.06
        let futaBaseFactor = max(0.0, 1.0 - 0.10 * (futaRate - 0.06) / 0.06)
        return currentBaseline.payrollUnemploymentFUTA * futaScale * futaBaseFactor
    }
    
    public var activePayrollTaxTotal: Double {
        return activeSocialSecurityTax + activeMedicareTax + activeFutaTax
    }
    
    public var activeCorporateIncomeTax: Double {
        let baseCorpTotal = currentBaseline.corporateIncomeTax
        
        // Elasticity for corporate income tax is 0.40
        let corpStatScale = corporateStatutoryRate / 0.21
        let corpStatBaseFactor = max(0.0, 1.0 - 0.40 * (corporateStatutoryRate - 0.21) / 0.21)
        let activeCorpStat = baseCorpTotal * corpStatutoryFraction * corpStatScale * corpStatBaseFactor
        
        let giltiScale = giltiRate / 0.105
        let giltiBaseFactor = max(0.0, 1.0 - 0.40 * (giltiRate - 0.105) / 0.105)
        let activeGILTI = baseCorpTotal * giltiFraction * giltiScale * giltiBaseFactor
        
        let beatScale = beatRate / 0.10
        let beatBaseFactor = max(0.0, 1.0 - 0.40 * (beatRate - 0.10) / 0.10)
        let activeBEAT = baseCorpTotal * beatFraction * beatScale * beatBaseFactor
        
        let camtScale = camtRate / 0.15
        let camtBaseFactor = max(0.0, 1.0 - 0.40 * (camtRate - 0.15) / 0.15)
        let activeCAMT = baseCorpTotal * camtFraction * camtScale * camtBaseFactor
        
        let buybackScale = stockBuybackRate / 0.01
        let buybackBaseFactor = max(0.0, 1.0 - 0.40 * (stockBuybackRate - 0.01) / 0.01)
        let activeBuyback = baseCorpTotal * buybackFraction * buybackScale * buybackBaseFactor
        
        return activeCorpStat + activeGILTI + activeBEAT + activeCAMT + activeBuyback
    }
    
    public var activeExciseTaxes: Double {
        // Assume elasticity of 0.25 (standard consumer response)
        let exciseBaseFactor = max(0.0, 1.0 - 0.25 * (exciseMultiplier - 1.0))
        return currentBaseline.exciseTaxes * exciseMultiplier * exciseBaseFactor
    }
    
    public var activeCustomsDuties: Double {
        // Elasticity for tariffs/customs is 0.60
        let customsBaseFactor = max(0.0, 1.0 - 0.60 * (customsMultiplier - 1.0))
        return currentBaseline.customsDuties * customsMultiplier * customsBaseFactor
    }
    
    public var activeMiscellaneousReceipts: Double {
        // Elasticity for miscellaneous is 0.0. Estate & gift ($30B) is surfaced as its own line.
        return max(0.0, currentBaseline.miscellaneousReceipts - estateGiftBaseline) * miscMultiplier
    }

    /// Current-law estate & gift tax, surfaced from Misc receipts (~$30B base).
    public var activeEstateGiftTax: Double {
        return estateGiftBaseline * estateGiftMultiplier
    }

    public var activePlaceholderTaxes: Double {
        return placeholderTax1 + placeholderTax2 + placeholderTax3
    }

    // --- Novel / proposed revenue (closed-form; $0 until dialed up) ---
    public var activeVAT: Double { vatRate * vatYieldPerPoint }
    public var activeNationalSalesTax: Double { nationalSalesTaxRate * salesYieldPerPoint }
    public var activeDigitalServicesTax: Double { digitalServicesRate * digitalYieldPerPoint }
    public var activeWealthTax: Double { wealthTaxYield }
    public var activeLandValueTax: Double { landValueTaxRate * landValueYieldPerPoint }
    public var activeCarbonTax: Double { carbonPricePerTon * carbonYieldPerDollarTon }
    public var activeVMTTax: Double { vmtCentsPerMile * vmtYieldPerCent }
    public var activeSodaTax: Double { sodaTaxYield }
    public var activeFinancialTransactionTax: Double { financialTransactionRate * fttYieldPerPoint }
    public var activeBankLevy: Double { bankLevyYield }
    public var activeEstateExpansion: Double { estateExpansionYield }

    /// Sum of all novel/proposed revenue (excludes current-law estate & gift).
    public var activeNovelRevenue: Double {
        return activeVAT + activeNationalSalesTax + activeDigitalServicesTax +
               activeWealthTax + activeLandValueTax + activeCarbonTax +
               activeVMTTax + activeSodaTax + activeFinancialTransactionTax +
               activeBankLevy + activeEstateExpansion
    }

    public var activeTotalRevenues: Double {
        return activeIndividualIncomeTax +
               activePayrollTaxTotal +
               activeCorporateIncomeTax +
               activeExciseTaxes +
               activeCustomsDuties +
               activeMiscellaneousReceipts +
               activeEstateGiftTax +
               activePlaceholderTaxes +
               activeNovelRevenue
    }
    
    // --- Real-time Calculations: Active Outlays ---
    
    public var activeSocialSecurityOutlay: Double {
        return currentBaseline.mandatorySocialSecurity * socialSecurityAllocationMultiplier
    }
    
    public var activeMedicareOutlay: Double {
        return currentBaseline.mandatoryMedicareNet * medicareAllocationMultiplier
    }
    
    public var activeMedicaidOutlay: Double {
        return currentBaseline.mandatoryMedicaidCHIP * medicaidAllocationMultiplier
    }
    
    public var activeIncomeSecurityOutlay: Double {
        return currentBaseline.mandatoryIncomeSecurity * incomeSecurityAllocationMultiplier
    }
    
    public var activeOtherMandatoryOutlay: Double {
        return currentBaseline.mandatoryOther * otherMandatoryAllocationMultiplier
    }
    
    public var activeDefenseOutlay: Double {
        return currentBaseline.discretionaryDefense * defenseAllocationMultiplier
    }
    
    // --- Non-Defense Discretionary, split into named programs ---
    public var activeVeteransOutlay: Double { baseVeterans * veteransMultiplier }
    public var activeEducationOutlay: Double { baseEducation * educationMultiplier }
    public var activeTransportationOutlay: Double { baseTransportation * transportationMultiplier }
    public var activeHealthNonMedOutlay: Double { baseHealthNonMed * healthNonMedMultiplier }
    public var activeScienceOutlay: Double { baseScience * scienceMultiplier }
    public var activeInternationalOutlay: Double { baseInternational * internationalMultiplier }
    public var activeJusticeOutlay: Double { baseJustice * justiceMultiplier }
    public var activeEnvironmentOutlay: Double { baseEnvironment * environmentMultiplier }
    public var activeHousingOutlay: Double { baseHousing * housingMultiplier }
    public var activeEnergyOutlay: Double { baseEnergy * energyMultiplier }
    public var activeCommerceOutlay: Double { baseCommerce * commerceMultiplier }
    public var activeGeneralGovOutlay: Double { baseGeneralGov * generalGovMultiplier }

    /// Aggregate of all named non-defense discretionary lines (keeps chart/popovers consistent).
    public var activeNonDefenseOutlay: Double {
        return activeVeteransOutlay + activeEducationOutlay + activeTransportationOutlay +
               activeHealthNonMedOutlay + activeScienceOutlay + activeInternationalOutlay +
               activeJusticeOutlay + activeEnvironmentOutlay + activeHousingOutlay +
               activeEnergyOutlay + activeCommerceOutlay + activeGeneralGovOutlay
    }

    public var activePlaceholderExpenditures: Double {
        return placeholderExpenditure1 + placeholderExpenditure2 + placeholderExpenditure3
    }

    /// Sum of all novel/proposed spending programs ($0 until dialed up).
    public var activeNovelSpending: Double {
        return ubiSpend + medicareForAllSpend + universalChildcareSpend + jobGuaranteeSpend +
               freeCollegeSpend + babyBondsSpend + paidLeaveSpend + sovereignWealthFundSpend
    }

    public var otherActiveOutlaysTotal: Double {
        return activeSocialSecurityOutlay +
               activeMedicareOutlay +
               activeMedicaidOutlay +
               activeIncomeSecurityOutlay +
               activeOtherMandatoryOutlay +
               activeDefenseOutlay +
               activeNonDefenseOutlay +
               activePlaceholderExpenditures +
               activeNovelSpending
    }
    
    public var activeNetInterestOutlay: Double {
        if isNetInterestLocked {
            let otherBaselineOutlays = currentBaseline.totalOutlays - currentBaseline.netInterest
            let deltaOtherOutlays = otherActiveOutlaysTotal - otherBaselineOutlays
            let deltaRevenues = activeTotalRevenues - currentBaseline.totalRevenues
            
            // Analytical solution of interest rate feedback loop:
            // DeltaInterest = (deltaOtherOutlays - deltaRevenues) * r / (1 - r)
            let interestAdjustment = (deltaOtherOutlays - deltaRevenues) * (effectiveInterestRate / (1.0 - effectiveInterestRate))
            return max(0.0, currentBaseline.netInterest + interestAdjustment)
        } else {
            return currentBaseline.netInterest * netInterestMultiplier
        }
    }
    
    public var activeTotalOutlays: Double {
        return otherActiveOutlaysTotal + activeNetInterestOutlay
    }
    
    // --- Net Deficit / Surplus ---
    
    public var activeDeficit: Double {
        return activeTotalOutlays - activeTotalRevenues
    }
    
    // --- Change from Baseline properties for charts/readouts ---
    
    public var deficitChange: Double {
        return activeDeficit - currentBaseline.deficit
    }
    
    public var revenueChange: Double {
        return activeTotalRevenues - currentBaseline.totalRevenues
    }
    
    public var outlayChange: Double {
        return activeTotalOutlays - currentBaseline.totalOutlays
    }
    
    // --- Statutory Threshold Alert Detectors ---
    
    /// Laffer inflection warning: true if any bracket rate > 70% or corporate tax rate > 35%.
    public var isLafferInflectionWarningActive: Bool {
        return bracketRates.contains(where: { $0 > 0.70 }) || corporateStatutoryRate > 0.35
    }
    
    /// Geopolitical risk warning: true if Defense is cut below 80% of baseline.
    public var isGeopoliticalRiskWarningActive: Bool {
        return defenseAllocationMultiplier < 0.80
    }
    
    /// Retiree poverty alert: true if Social Security/Medicare entitlements are cut below 90% of baseline.
    public var isRetireePovertyAlertActive: Bool {
        return socialSecurityAllocationMultiplier < 0.90 || medicareAllocationMultiplier < 0.90
    }
    
    // --- Reset method ---
    public func reset() {
        resetToBaseline()
    }
    
    public func resetToBaseline() {
        bracket10Rate = 0.10
        bracket12Rate = 0.12
        bracket22Rate = 0.22
        bracket24Rate = 0.24
        bracket32Rate = 0.32
        bracket35Rate = 0.35
        bracket37Rate = 0.37
        capitalGainsRate = 0.20
        socialSecurityRate = 0.124
        medicareRate = 0.029
        futaRate = 0.06
        corporateStatutoryRate = 0.21
        camtRate = 0.15
        giltiRate = 0.105
        beatRate = 0.10
        stockBuybackRate = 0.01
        
        exciseMultiplier = 1.0
        customsMultiplier = 1.0
        miscMultiplier = 1.0
        
        placeholderTax1 = 0.0
        placeholderTax2 = 0.0
        placeholderTax3 = 0.0
        
        netInterestMultiplier = 1.0
        socialSecurityAllocationMultiplier = 1.0
        medicareAllocationMultiplier = 1.0
        medicaidAllocationMultiplier = 1.0
        incomeSecurityAllocationMultiplier = 1.0
        otherMandatoryAllocationMultiplier = 1.0
        defenseAllocationMultiplier = 1.0
        nonDefenseAllocationMultiplier = 1.0
        
        placeholderExpenditure1 = 0.0
        placeholderExpenditure2 = 0.0
        placeholderExpenditure3 = 0.0

        // Current-law estate & gift + named non-defense discretionary
        estateGiftMultiplier = 1.0
        veteransMultiplier = 1.0
        educationMultiplier = 1.0
        transportationMultiplier = 1.0
        healthNonMedMultiplier = 1.0
        scienceMultiplier = 1.0
        internationalMultiplier = 1.0
        justiceMultiplier = 1.0
        environmentMultiplier = 1.0
        housingMultiplier = 1.0
        energyMultiplier = 1.0
        commerceMultiplier = 1.0
        generalGovMultiplier = 1.0

        // Novel revenue (all OFF)
        vatRate = 0.0
        nationalSalesTaxRate = 0.0
        digitalServicesRate = 0.0
        wealthTaxYield = 0.0
        landValueTaxRate = 0.0
        carbonPricePerTon = 0.0
        vmtCentsPerMile = 0.0
        sodaTaxYield = 0.0
        financialTransactionRate = 0.0
        bankLevyYield = 0.0
        estateExpansionYield = 0.0

        // Novel spending (all OFF)
        ubiSpend = 0.0
        medicareForAllSpend = 0.0
        universalChildcareSpend = 0.0
        jobGuaranteeSpend = 0.0
        freeCollegeSpend = 0.0
        babyBondsSpend = 0.0
        paidLeaveSpend = 0.0
        sovereignWealthFundSpend = 0.0

        isNetInterestLocked = true
    }
}
