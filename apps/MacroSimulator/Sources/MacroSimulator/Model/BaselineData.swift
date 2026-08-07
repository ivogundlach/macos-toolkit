import Foundation

/// Actual and projected baseline fiscal data (in billions of USD) for the US Federal Government.
/// Sources: Congressional Budget Office (CBO) - February 2026 Budget and Economic Outlook (Report 61882).
public struct BaselineData {
    public struct FiscalYearData: Codable, Equatable, Sendable {
        public let year: Int
        
        // --- Revenues (in billions of USD) ---
        public let individualIncomeTax: Double
        
        // Payroll Taxes
        public let payrollTaxTotal: Double
        public let payrollSocialSecurityOASDI: Double
        public let payrollMedicareHI: Double
        public let payrollUnemploymentFUTA: Double
        
        public let corporateIncomeTax: Double
        public let exciseTaxes: Double
        public let customsDuties: Double
        public let miscellaneousReceipts: Double
        public let totalRevenues: Double
        
        // --- Outlays (in billions of USD) ---
        public let netInterest: Double
        
        // Mandatory Entitlements
        public let mandatorySocialSecurity: Double
        public let mandatoryMedicareNet: Double
        public let mandatoryMedicaidCHIP: Double
        public let mandatoryIncomeSecurity: Double
        public let mandatoryOther: Double
        public let totalMandatory: Double
        
        // Discretionary Spending
        public let discretionaryDefense: Double
        public let discretionaryNonDefense: Double
        public let totalDiscretionary: Double
        
        public let totalOutlays: Double
        
        // --- Derived Deficit (in billions of USD) ---
        public var deficit: Double {
            return totalOutlays - totalRevenues
        }
        
        public init(
            year: Int,
            individualIncomeTax: Double,
            payrollTaxTotal: Double,
            payrollSocialSecurityOASDI: Double,
            payrollMedicareHI: Double,
            payrollUnemploymentFUTA: Double,
            corporateIncomeTax: Double,
            exciseTaxes: Double,
            customsDuties: Double,
            miscellaneousReceipts: Double,
            totalRevenues: Double,
            netInterest: Double,
            mandatorySocialSecurity: Double,
            mandatoryMedicareNet: Double,
            mandatoryMedicaidCHIP: Double,
            mandatoryIncomeSecurity: Double,
            mandatoryOther: Double,
            totalMandatory: Double,
            discretionaryDefense: Double,
            discretionaryNonDefense: Double,
            totalDiscretionary: Double,
            totalOutlays: Double
        ) {
            self.year = year
            self.individualIncomeTax = individualIncomeTax
            self.payrollTaxTotal = payrollTaxTotal
            self.payrollSocialSecurityOASDI = payrollSocialSecurityOASDI
            self.payrollMedicareHI = payrollMedicareHI
            self.payrollUnemploymentFUTA = payrollUnemploymentFUTA
            self.corporateIncomeTax = corporateIncomeTax
            self.exciseTaxes = exciseTaxes
            self.customsDuties = customsDuties
            self.miscellaneousReceipts = miscellaneousReceipts
            self.totalRevenues = totalRevenues
            self.netInterest = netInterest
            self.mandatorySocialSecurity = mandatorySocialSecurity
            self.mandatoryMedicareNet = mandatoryMedicareNet
            self.mandatoryMedicaidCHIP = mandatoryMedicaidCHIP
            self.mandatoryIncomeSecurity = mandatoryIncomeSecurity
            self.mandatoryOther = mandatoryOther
            self.totalMandatory = totalMandatory
            self.discretionaryDefense = discretionaryDefense
            self.discretionaryNonDefense = discretionaryNonDefense
            self.totalDiscretionary = totalDiscretionary
            self.totalOutlays = totalOutlays
        }
    }
    
    /// The primary baseline database representing CBO's February 2026 projections
    /// (incorporating final FY 2025 actuals and updated FY 2026 projections).
    public static let baseline2026 = [
        // FY 2025 Actual figures
        FiscalYearData(
            year: 2025,
            individualIncomeTax: 2656.0,
            payrollTaxTotal: 1748.0,
            payrollSocialSecurityOASDI: 1288.0,
            payrollMedicareHI: 399.0,
            payrollUnemploymentFUTA: 61.0,
            corporateIncomeTax: 452.0,
            exciseTaxes: 106.0,
            customsDuties: 195.0,
            miscellaneousReceipts: 77.0, // Total Other Receipts ($183B) minus Excise ($106B)
            totalRevenues: 5235.0,
            netInterest: 970.0,
            mandatorySocialSecurity: 1575.0,
            mandatoryMedicareNet: 988.0,
            mandatoryMedicaidCHIP: 832.0,
            mandatoryIncomeSecurity: 397.0,
            mandatoryOther: 376.0, // Derived remainder of total mandatory ($4,168B)
            totalMandatory: 4168.0,
            discretionaryDefense: 893.0,
            discretionaryNonDefense: 980.0,
            totalDiscretionary: 1872.0,
            totalOutlays: 7010.0
        ),
        
        // FY 2026 Projected figures
        FiscalYearData(
            year: 2026,
            individualIncomeTax: 2751.0,
            payrollTaxTotal: 1826.0,
            payrollSocialSecurityOASDI: 1346.0,
            payrollMedicareHI: 416.0,
            payrollUnemploymentFUTA: 64.0,
            corporateIncomeTax: 404.0,
            exciseTaxes: 108.0,
            customsDuties: 418.0,
            miscellaneousReceipts: 89.0, // Total Other Receipts ($197B) minus Excise ($108B)
            totalRevenues: 5596.0,
            netInterest: 1039.0,
            mandatorySocialSecurity: 1666.0,
            mandatoryMedicareNet: 1063.0,
            mandatoryMedicaidCHIP: 845.0,
            mandatoryIncomeSecurity: 389.0,
            mandatoryOther: 566.0, // Derived remainder of total mandatory ($4,529B)
            totalMandatory: 4529.0,
            discretionaryDefense: 885.0,
            discretionaryNonDefense: 996.0,
            totalDiscretionary: 1880.0,
            totalOutlays: 7449.0
        )
    ]
}
