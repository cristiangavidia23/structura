import Foundation

/// Turns a measured distance and a known reference length into a concrete
/// error figure — without this, calling a measurement "precise" is an
/// assertion with nothing behind it. The user measures a known object
/// (a standard door width, a tape measure laid on the floor) with the same
/// tool, enters what it's actually supposed to be, and sees exactly how far
/// off the tool was.
enum MeasurementCalibration {
    struct Result: Equatable {
        var measuredMeters: Float
        var referenceMeters: Float
        var absoluteErrorMeters: Float
        /// Signed: positive means the tool measured *longer* than the
        /// reference, negative means *shorter*.
        var signedErrorMeters: Float
        /// `nil` only if `referenceMeters` is zero (percentage is undefined).
        var errorPercentage: Float?
    }

    static func evaluate(measuredMeters: Float, referenceMeters: Float) -> Result {
        let signedError = measuredMeters - referenceMeters
        let percentage: Float? = referenceMeters != 0 ? (signedError / referenceMeters) * 100 : nil
        return Result(
            measuredMeters: measuredMeters,
            referenceMeters: referenceMeters,
            absoluteErrorMeters: abs(signedError),
            signedErrorMeters: signedError,
            errorPercentage: percentage
        )
    }
}
