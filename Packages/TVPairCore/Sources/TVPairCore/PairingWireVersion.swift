import Foundation

enum PairingWireVersion {
    static func validatePeer(maximum: Int, minimum: Int, requested: Int = 19) throws {
        // A peer's maximum version is not the negotiated version. The initiating
        // host already requested 19; current peers can advertise a maximum of 26.
        guard minimum >= 0, maximum >= minimum, minimum <= requested, requested <= maximum else {
            throw TVPairError.unsupported("no compatible RPPairing wire version; peer range \(minimum)...\(maximum), requested \(requested)")
        }
    }
}
