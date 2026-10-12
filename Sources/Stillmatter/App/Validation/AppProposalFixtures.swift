#if DEBUG || STILLMATTER_NATIVE_PROBES
import AppKit
import Darwin
import StillmatterCore
import StillmatterPresentation

extension AppDelegate {
    func seedProposalReviewValidationFixtureIfRequested() {
        guard ProcessInfo.processInfo.environment["STILLMATTER_PROPOSAL_REVIEW_FIXTURE"] == "1",
              let inbox = tasksInbox else { return }
        let proposals = [
            ("validation:accept", "Send the launch recap #ai-proposed", "[[Meetings/validation-launch/summary#My action items|source]]"),
            ("validation:reference", "Alex owns the deployment checklist #ai-proposed", "[[Meetings/validation-launch/summary#Other action items|source]]"),
            ("validation:dismiss", "Duplicate reminder that should be dismissed #ai-proposed", "[[Meetings/validation-launch/summary#My action items|source]]"),
            ("validation:merge-a", "Ask the vendor for revised pricing #ai-proposed", "[[Meetings/validation-vendor/summary#Pricing|source]]"),
            ("validation:merge-b", "Confirm the vendor security review #ai-proposed", "[[Meetings/validation-vendor/summary#Security review|source]]"),
            ("validation:retry", "Exercise the failed review retry path #ai-proposed", "[[Meetings/2026/Quarterly Planning/Extremely Long Durable Source Path/summary#My action items|source]]")
        ]
        do {
            for proposal in proposals {
                _ = try inbox.queueProposal(id: proposal.0, title: proposal.1, sourceRef: proposal.2)
            }
        } catch {
            NSLog("Could not seed proposal review validation fixture: \(error)")
        }
    }

}
#endif
