/// Pure "sustained reliable tracking" counter — decides when it's safe to
/// trust the coordinate frame again after an interruption (see
/// `ARPointCloudSession.updateCoordinateFrameRecoveryState`). Kept
/// ARKit-free and separate from that plumbing so the counting logic itself
/// has a direct unit test, not just its ARKit call site.
struct RelocalizationConfirmation {
    private var consecutiveReliableFrames = 0

    /// Feed one frame's tracking reliability. Returns `true` exactly once
    /// — on the frame that reaches `requiredConsecutiveFrames` — and resets
    /// its own count immediately after, so a caller that keeps calling
    /// `observe` past that point won't see a second `true` without a fresh
    /// unreliable-then-reliable run. Any unreliable frame resets the count
    /// to zero, discarding whatever run was in progress.
    mutating func observe(isReliable: Bool, requiredConsecutiveFrames: Int) -> Bool {
        guard isReliable else {
            consecutiveReliableFrames = 0
            return false
        }
        consecutiveReliableFrames += 1
        if consecutiveReliableFrames >= requiredConsecutiveFrames {
            consecutiveReliableFrames = 0
            return true
        }
        return false
    }

    mutating func reset() {
        consecutiveReliableFrames = 0
    }
}
