import Foundation

@main
struct RepairUIStateChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("repair UI state check failed: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        let now = Date()
        require(shouldDisplayRepairRequest(status: "pending", updatedAt: nil, now: now), "pending hidden")
        require(shouldDisplayRepairRequest(status: "awaiting_user_auth", updatedAt: nil, now: now), "auth wait hidden")
        require(shouldDisplayRepairRequest(status: "reconsidering", updatedAt: now.addingTimeInterval(-30), now: now), "fresh reconsidering hidden")
        require(!shouldDisplayRepairRequest(status: "reconsidering", updatedAt: now.addingTimeInterval(-3601), now: now), "historical reconsidering restored")
        require(shouldDisplayRepairRequest(status: "executing", updatedAt: now.addingTimeInterval(-30), now: now), "execution claim hidden")
        require(shouldDisplayRepairRequest(status: "resolved", updatedAt: now.addingTimeInterval(-29), now: now), "fresh confirmation hidden")
        require(!shouldDisplayRepairRequest(status: "resolved", updatedAt: now.addingTimeInterval(-31), now: now), "old confirmation restored")
        require(!shouldDisplayRepairRequest(status: "resolved", updatedAt: nil, now: now), "malformed history restored")
        for phase in ["approved", "repairing", "stalled", "suspended-hard-stop"] {
            require(shouldDisplayRepairRequest(status: phase, updatedAt: nil, now: now), "(phase) card hidden")
        }

        let decoder = JSONDecoder()
        let base = #"{"schemaVersion":5,"id":"repair-1","incidentID":"incident","generation":"generation-1","revision":1,"authorityDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","authorityStatus":"pending","grantID":null,"planDigest":null,"pendingKey":"key","toolName":"Example","summary":"The check is still reporting a problem.","rootCause":"A safe fix needs review.","proposedFix":"Approve the repair authority once and let Luna verify recovery.","approvalReason":"Approval grants full local repair authority for this incident until healthy.","risk":"Hard stops remain enforced.","requestedAction":null,"proposedPlan":null,"conversation":[],"model":"gpt-5.6-luna","reasoning":"max","status":"pending","actionable":true,"createdAt":"2026-08-04T00:00:00Z","updatedAt":"2026-08-04T00:00:00Z"}"#
        let changed = #"{"schemaVersion":5,"id":"repair-1","incidentID":"incident","generation":"generation-1","revision":2,"authorityDigest":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","authorityStatus":"pending","grantID":null,"planDigest":null,"pendingKey":"key","toolName":"Example","summary":"The revised plan is ready.","rootCause":"A safe fix needs review.","proposedFix":"Apply the revised objective and verify recovery.","approvalReason":"Approval grants full local repair authority for this incident until healthy.","risk":"Hard stops remain enforced.","requestedAction":null,"proposedPlan":null,"conversation":[{"role":"user","text":"Please reconsider.","at":"2026-08-04T00:01:00Z"}],"model":"gpt-5.6-luna","reasoning":"max","status":"pending","actionable":true,"createdAt":"2026-08-04T00:00:00Z","updatedAt":"2026-08-04T00:01:00Z"}"#
        do {
            let first = try decoder.decode(RepairRequest.self, from: Data(base.utf8))
            let second = try decoder.decode(RepairRequest.self, from: Data(changed.utf8))
            require(repairRequestsNeedRefresh([first], [second]), "same-ID changed request content was not published")
            require(first != second, "RepairRequest full-content comparison missing")
            require(second.conversation.first?.text == "Please reconsider.", "conversation was not decoded")
            require(second.proposedFix == "Apply the revised objective and verify recovery.", "dedicated proposed fix was not decoded")
        } catch {
            fputs("repair UI state check failed: request decoding: \(error)\n", stderr)
            exit(1)
        }

        require(repairPhaseAllowsActions("pending"), "pending actions disabled")
        for phase in ["reconsidering", "executing", "awaiting_user_auth", "resolved"] {
            require(!repairPhaseAllowsActions(phase), "\(phase) permits duplicate actions")
            require(!repairPhaseMessage(phase).isEmpty, "\(phase) lacks visible acknowledgement")
        }
        require(repairPhaseAllowsActions("approved"), "approved grant cannot be stopped")
        require(repairPhaseAllowsActions("repairing"), "active grant cannot be stopped")
        require(repairPhaseAllowsActions("stalled"), "stalled grant controls hidden")
        require(repairPhaseAllowsActions("suspended-hard-stop"), "hard-stop grant controls hidden")
        require(repairPhaseMessage("approved").contains("full local repair authority"), "approval scope copy unclear")
        require(repairPhaseMessage("repairing").contains("Paths and commands may change"), "dynamic strategy copy unclear")
        require(repairPhaseMessage("suspended-hard-stop").contains("hard stop"), "hard-stop guidance unclear")
        require(repairPhaseMessage("reconsidering").contains("received"), "thought acknowledgement unclear")
        require(repairPhaseMessage("awaiting_user_auth").contains("Safari"), "auth wait guidance unclear")
        require(repairPhaseMessage("resolved").contains("confirmed"), "resolution confirmation unclear")
        require(repairRequestCanWriteDecision(try! decoder.decode(RepairRequest.self, from: Data(base.utf8))), "v5 request decision gate rejected valid request")
        let lifetime = try! decoder.decode(RepairAuthorityDescriptor.self, from: Data(#"{"lifetime":{"until":"trusted-health-or-revoked"}}"#.utf8))
        require(lifetime.lifetime?.until == "trusted-health-or-revoked", "health-bound authority lifetime did not decode")
        let legacy = try! decoder.decode(RepairRequest.self, from: Data(#"{"id":"legacy","summary":"old"}"#.utf8))
        require(!repairRequestCanWriteDecision(legacy), "legacy request synthesized a v4 decision authority")
        let tool: [String: Any] = ["tool": "Fixture"]
        require(
            activityPhrase(
                event: "repair-succeeded",
                obj: tool.merging(["outcome": "durable_model_repair"]) { _, new in new }
            ) == "Fixed Fixture automatically.",
            "durable model repair mislabeled"
        )
        require(
            activityPhrase(
                event: "repair-succeeded",
                obj: tool.merging(["outcome": "recovered_before_repair"]) { _, new in new }
            ) == "Recovered Fixture.",
            "spontaneous recovery mislabeled"
        )
        require(
            activityPhrase(
                event: "repair-succeeded",
                obj: tool.merging(["details": "unrecognized historical record"]) { _, new in new }
            ) == "Repair result recorded for Fixture.",
            "ambiguous historical result was guessed"
        )
        require(
            activityPhrase(
                event: "repair-succeeded",
                obj: tool.merging([
                    "details": "Trusted deterministic recipe repaired the incident: Recipe completed."
                ]) { _, new in new }
            ) == "Fixed Fixture automatically.",
            "historical deterministic repair mislabeled"
        )
        print("repair UI state checks passed (visibility, acknowledgement, action gating, history bounds)")
        print("history evidence: trusted deterministic phrase -> Fixed automatically; recovered outcome -> Recovered; ambiguous phrase -> neutral")
    }
}
