// Adapted from NotProton; GPL-3.0. See PROVENANCE.md.
import Foundation

struct StepFailure: LocalizedError {
    let step: String
    let detail: String

    var errorDescription: String? { "\(step): \(detail)" }
}
