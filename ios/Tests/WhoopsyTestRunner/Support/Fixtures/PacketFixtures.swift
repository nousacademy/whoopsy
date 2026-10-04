import Foundation
import Whoopsy

// **Hoisted above §1's gate, deliberately.** The 5.0 hello frame is built here and read by §2 as
// well, so gating §1 alone would put it out of §2's scope. It is a pure value with no I/O, so building
// it on a run that skipped both sections costs nothing.

// The 5.0 `CLIENT_HELLO`, the one published 5.0 frame in hand: a static sixteen bytes from the
// reference, quoted byte for byte in `docs/BLE_PROTOCOL.md` §2.1. Every field below is asserted against it
// rather than against this app's own arithmetic, because a vector computed by the code under test is
// not a vector.
let hello50 = Data([
    0xAA, 0x01, 0x08, 0x00, 0x00, 0x01, 0xE6, 0x71,
    0x23, 0x01, 0x91, 0x01, 0x36, 0x3E, 0x5C, 0x8D,
])

// The decoder is hoisted with it, and for the same reason: it is stateless by construction — zero
// stored properties, which is what makes it `Sendable` without a lock — so one instance serves every
// section and there is nothing for a second to isolate. §1 reads the 5.0 hello through it and §2 reads
// the 4.0 frames; a per-section copy would be the same object twice.
let decoder = WhoopPacketDecoder()
