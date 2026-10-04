import Foundation
import SwiftUI
import Whoopsy

// MARK: - 14. The device page, the strap's mark, and Home's badge

/// A file of §14's body, cut at the section's own `// ---- Title ----` boundary and
/// moved verbatim. `HomeSourceTests.run()` calls it, in the order the section ran it in.

enum HomeDeviceSettingsTests {
    static func run() async throws {
        // ---- The battery trap, and why the readout is gated on connection state ----

        let disconnected = WhoopDevice(id: "no-strap", connectionState: .disconnected)
        assertTest(
            disconnected.batteryPercentage == 100,
            "A disconnected strap reports battery 100% — the default this app writes, not a measurement "
                + "it took (WhoopBLEManager sets the same literal at discovery). This is why both battery "
                + "readouts gate on `WhoopDevice.batteryReading` rather than printing this value.")

        // ---- The device page: one screen, and the readings it refuses to invent ----

        // The two tabs, in the order they are drawn. `allCases` is the enum's own order, so this is the
        // assertion that fails if a case is renamed or the two are swapped.
        assertTest(
            DeviceSettingsView.Tab.allCases.map(\.title) == ["STATUS", "ADVANCED"],
            "The device page's tabs are STATUS then ADVANCED in that order — the order the tab row draws "
                + "them in, which is the reference's own layout. `allCases` is the enum's own order, so "
                + "this is the assertion that fails if the two are swapped.")

        // ---- The strap's mark, which is now one definition for two screens ----
        //
        // It was a *comment* asserting a rule and enforcing none: this page's connector drew
        // `sensor.tag.radiowaves.forward.fill` while its own doc claimed it drew "the same glyph Home's
        // badge draws", and Home draws `capsule.portrait`. Nothing caught it and nothing could — a wrong
        // symbol draws a different picture rather than an error, and the runner has no renderer. The user
        // asking for the capsule here is what turned the claim into `StrapGlyph`.
        assertTest(
            StrapMark.symbol == "capsule.portrait",
            "The strap's mark is `capsule.portrait` — pinned as a literal, because this is the one string "
                + "both Home's status badge and the device page's connector resolve through. A typo in it "
                + "draws an empty box on both screens and fails nothing else.")
        assertTest(
            StrapMark.ringWidth == 1.5,
            "The badge's knockout ring is 1.5 pt — the value Home's dot was measured at, now shared. The "
                + "ring is what stops a badge merging into the outline it crosses, so it is a reading "
                + "constant and not a style: at 12 pt a dot drawn straight onto the stroke is a blob.")

        // `WhoopConnectionState` is not `CaseIterable`, so the six are listed here rather than derived.
        // A seventh case is a compile error inside `hero(for:)` — its `switch` is exhaustive — and that
        // is the guarantee this list cannot give; what the list covers is that no case draws a blank.
        let connectionStates: [WhoopConnectionState] = [
            .disconnected, .scanning, .connecting, .connected, .syncing, .error,
        ]
        let deviceHeroes = connectionStates.map { DeviceSettingsView.hero(for: $0) }
        assertTest(
            deviceHeroes.allSatisfy { !$0.lead.isEmpty && !$0.stateWord.isEmpty && !$0.sentence.isEmpty },
            "Every one of the six connection states draws a non-empty lead line, state word and sentence. "
                + "A case that fell through would draw three empty strings, which reads on screen as a "
                + "layout bug rather than as a missing case.")
        assertTest(
            Set(deviceHeroes.map(\.stateWord)).count == connectionStates.count,
            "All six state words are distinct. A copy-paste that left two cases saying `WHOOP CONNECTED` "
                + "satisfies every non-empty check above and puts one state's words on another's screen.")
        assertTest(
            DeviceSettingsView.hero(for: .disconnected).sentence.contains("Pair a Device"),
            "The disconnected header names the button below it — `Tap 'Pair a Device' below to continue.` "
                + "It is the reference's own copy, and it is the only instruction a reader in that state "
                + "can act on.")

        // ---- The header says the relation, the caption says the state, and neither says both ----
        //
        // The header draws `lead` beside `subject` and the caption below the tabs draws `stateWord`. That
        // split is what fixes a defect the old arrangement had: with `lead` and `stateWord` both in the
        // header, `.disconnected` drew `NOT CONNECTED TO / WHOOP DISCONNECTED` — one fact in two type
        // sizes. The pair below is what fails if the subject is ever retyped as a state word, which is the
        // one edit that would restore it.
        assertTest(
            DeviceSettingsView.subject == "WHOOP DEVICE",
            "The header's subject is `WHOOP DEVICE` — the reference's own word for the hardware, and the "
                + "half of the sentence `lead` completes. It is a constant on the view rather than a sixth "
                + "field on `Hero`, because it is one value in all six arms and six copies are six places "
                + "to drift.")
        assertTest(
            deviceHeroes.allSatisfy {
                $0.stateWord != DeviceSettingsView.subject && $0.sentence != DeviceSettingsView.subject
            },
            "No state's `stateWord` or `sentence` equals the header's subject. **This is the assertion "
                + "that fails if the header starts saying the state twice**: the header reads "
                + "`NOT CONNECTED TO / WHOOP DEVICE` and the caption under the mark reads "
                + "`WHOOP DISCONNECTED`, so a subject typed as a state word would put one fact on the page "
                + "in two sizes — which is the arrangement this replaced.")
        assertTest(
            deviceHeroes.allSatisfy { !$0.lead.isEmpty } && Set(deviceHeroes.map(\.lead)).count == 2,
            "The lead line has exactly two arms across the six states — `CONNECTED TO` and "
                + "`NOT CONNECTED TO` — so the header's first line is a relation and not a seventh state "
                + "word. `.connected` and `.syncing` are the pair that take the other arm, which is the "
                + "same split `isLinked` makes for Home's dot.")

        // **The trap above and its gate, side by side.** The assertion establishes that a
        // `.disconnected` device reports `100`; these three establish that the page withholds the
        // reading anyway, and prints it only when the strap is really attached.
        assertTest(
            DeviceSettingsView.batteryText(for: disconnected) == ActivityFigure.dash,
            "A disconnected strap's battery renders `—` even though the same object reports "
                + "`batteryPercentage == 100`, per the assertion above — that figure is a constant this "
                + "app wrote down at discovery rather than a measurement it took.")
        assertTest(
            DeviceSettingsView.batteryText(for: nil) == ActivityFigure.dash,
            "No strap at all is the same dash and not `0%`. **This is the assertion that fails if "
                + "`device?.batteryPercentage ?? 0` comes back**: the Settings page this replaced printed "
                + "exactly that, so a strap that was absent read a fabricated `0%` and one merely "
                + "discovered read a fabricated `100%`, while the badge's page gated the same reading "
                + "correctly. Two screens disagreeing about one strap is what the merge removed.")
        assertTest(
            DeviceSettingsView.batteryText(
                for: WhoopDevice(id: "strap", batteryPercentage: 62, connectionState: .connected)) == "62%",
            "A connected strap's battery is its own stored percentage — the gate withholds the reading "
                + "when there is none and prints it when there is one.")

        // ---- The gate those three read, over the whole enum, and the two drawings of its absence ----
        //
        // Swept rather than sampled because the arm that matters is the one nobody would write a case for:
        // `.syncing` is a live strap that the dot beside this figure draws green, so `== .connected` and
        // `isLinked` are two plausible gates that differ on exactly that state and on nothing else. Either
        // is defensible; what is not is leaving the choice unwritten, since a figure admitted on the
        // strength of what `.syncing` means is admitted on no evidence at all — `WhoopBLEManager` never
        // constructs it, so no battery has ever been read during a drain here. Pinned to `.connected`.
        let batteryStates = connectionStates.map { state in
            WhoopDevice(id: "strap", batteryPercentage: 62, connectionState: state).batteryReading
        }
        assertTest(
            batteryStates == [nil, nil, nil, "62%", nil, nil],
            "Only `.connected` yields a battery figure; the other five states yield none, on one strap "
                + "object constructed with a truthful-looking `62` in every case. **`.syncing` is the arm "
                + "to read**: the link is up there and the dot beside this figure says so, but "
                + "`WhoopBLEManager` never constructs the state, so nothing here has seen a battery read "
                + "during a drain — and a figure admitted because the state *probably* has one is the "
                + "discovery literal `100` printed as a measurement.")
        assertTest(
            connectionStates.allSatisfy { state in
                let device = WhoopDevice(id: "strap", batteryPercentage: 62, connectionState: state)
                return DeviceSettingsView.batteryText(for: device)
                    == (device.batteryReading ?? ActivityFigure.dash)
            },
            "The device page's row is the gate plus the dash, on every state, so the two screens cannot "
                + "come to disagree about *when* there is a reading — only about how to draw its absence, "
                + "which is the one thing they are meant to differ on. `batteryText(for: nil)` is covered "
                + "by the three assertions above it.")
        assertTest(
            DeviceSettingsView.batteryText(for: disconnected) == ActivityFigure.dash,
            "…and on any other strap the two part company deliberately: the device page draws the dash, "
                + "because a labelled `BATTERY` row in a `Form` with no value looks unfinished, while "
                + "Home's badge draws nothing at all. The gate is one rule; the absent case is each "
                + "screen's own drawing of it.")

        assertTest(
            DeviceSettingsView.lastSyncText(nil) == ActivityFigure.dash,
            "A strap that has never delivered a sample draws `—`. The producer is the newest row in "
                + "`biometric_samples`, which holds 0 rows in every database on this machine — so this is "
                + "what the page draws here, and it is an honest absence rather than a bug. It populates "
                + "the moment a strap is connected and writes its first sample.")
        // Asserted as a *property* rather than as a literal, on §11's and §13's rule: a hardcoded format
        // string is a test that fails on someone else's machine. The mockup's `08/22` is deliberately not
        // reproduced — a literal `MM/dd` is US-only — so the figure is composed from the app's two
        // locale-aware formatters and this checks it reaches both of them.
        let syncInstant = Date(timeIntervalSince1970: 1_755_889_140)
        let syncText = DeviceSettingsView.lastSyncText(syncInstant)
        assertTest(
            syncText != ActivityFigure.dash
                && syncText.contains(syncInstant.formattedShortDate())
                && syncText.contains(syncInstant.formattedHourMinute()),
            "A stored instant renders as its own short date and clock time — `\(syncText)`. Both halves "
                + "come from the app's existing formatters rather than a literal pattern, so the figure "
                + "moves with the device's locale instead of breaking in it.")

        // ---- The ADVANCED tab's fact row: three marks, and one default that must never print ----
        //
        // The row is the reference's, carrying three facts where the reference draws two. `SIGNAL` is the
        // addition and its justification is a producer rather than a preference: firmware has none at all
        // and the device identifier has none until a strap is discovered, so a row built to the reference's
        // two would be two permanent dashes with this app's one live diagnostic deleted from the page it
        // belongs on.
        //
        // What is assertable is the **value** each column draws. The marks, the stacking and the
        // middle-truncation are drawings and this runner has no renderer — §15's caveat about its bars
        // applies verbatim.
        assertTest(
            DeviceSettingsView.DeviceFact.allCases.map(\.label) == ["DEVICE ID", "FIRMWARE", "SIGNAL"],
            "The fact row draws DEVICE ID, FIRMWARE and SIGNAL in that order — the reference's own left-to-"
                + "right order with SIGNAL appended. `allCases` is the enum's order, so this is the "
                + "assertion that fails if a case is renamed, dropped or reordered.")
        assertTest(
            DeviceSettingsView.DeviceFact.allCases.allSatisfy { !$0.symbol.isEmpty },
            "Every fact carries a non-empty SF Symbol name. **A wrong symbol name is not an error** — it "
                + "draws an empty chip, which is invisible to the compiler and to any screenshot of a "
                + "different row, so this and `ActivityMenu`'s matching assertion are the only things in the "
                + "repo that can see a typo. What it cannot see is the deployment target: a name introduced "
                + "in iOS 18 resolves here and draws nothing on a 17.0 device, because the runner is a macOS "
                + "binary whose own symbol catalogue is the newest OS on the machine.")
        assertTest(
            Set(DeviceSettingsView.DeviceFact.allCases.map(\.symbol)).count
                == DeviceSettingsView.DeviceFact.allCases.count,
            "All three marks are distinct. Three columns drawing one glyph reads as one fact repeated "
                + "rather than as a row of three, and it satisfies the non-empty check above.")
        assertTest(
            DeviceSettingsView.DeviceFact.deviceId.symbol == StrapMark.symbol,
            "DEVICE ID's mark reads `StrapMark.symbol` rather than naming `capsule.portrait` a second time, "
                + "so the app keeps one definition of the strap's mark — the same rule that has `StrapGlyph` "
                + "shared between Home's badge and this page. This fails if the literal is retyped here.")

        // The device identifier is the one fact with a real producer on a discovered strap: it is
        // `peripheral.identifier.uuidString`, written in `didDiscover` and the key the model choice is
        // stored against — so it names the strap rather than describing it.
        let factStrap = WhoopDevice(
            id: "E1A2B3C4-0000-1111-2222-5F60788099AA",
            batteryPercentage: 62,
            connectionState: .connected,
            signalStrengthRssi: -71)
        assertTest(
            DeviceSettingsView.factValue(.deviceId, device: factStrap) == factStrap.id,
            "A discovered strap's DEVICE ID is its own peripheral identifier — the real producer, and the "
                + "only fact in the row that is both present and about a specific strap.")

        // **The firmware assertion is the one that keeps a written-down number off the screen.**
        // `WhoopDevice.firmwareVersion` is `String?` *defaulted to the literal `"41.14.2.0"`*, and
        // `WhoopBLEManager.resolvedDevice` only ever propagates it — so every real strap's device object
        // carries that constant, and returning the field would print a number this app made up. Both of the
        // screens this page replaced printed exactly that.
        assertTest(
            DeviceSettingsView.factValue(.firmware, device: factStrap) == ActivityFigure.dash,
            "FIRMWARE is `—` on a connected, discovered strap — the case where a naive read of "
                + "`device.firmwareVersion` would return `41.14.2.0` and look like a reading. That literal "
                + "is the entity's default and `resolvedDevice` never assigns a real one, so the dash is the "
                + "honest answer, and it is informative rather than apologetic: the clock-set payload is "
                + "firmware-specific and a wrong-length set is accepted but never latched.")

        // **The `-65` trap, and this assertion is the reason the gate exists at all.**
        // `WhoopBLEManager.startScanning` builds its placeholder as
        // `WhoopDevice(id: "", name: "Scanning...", connectionState: .scanning)` — omitting every argument
        // it can, including `signalStrengthRssi`, whose entity default is `-65`. So during a scan there is
        // an object in hand carrying a plausible-looking RSSI for a strap that has not been found. It is the
        // *only* such object: `resolvedDevice` passes `fallback?.signalStrengthRssi` explicitly, so a
        // device built with no fallback gets `nil` and not the default. The empty identifier is what
        // separates them.
        let scanningPlaceholder = WhoopDevice(id: "", name: "Scanning...", connectionState: .scanning)
        assertTest(
            scanningPlaceholder.signalStrengthRssi == -65
                && DeviceSettingsView.factValue(.signal, device: scanningPlaceholder) == ActivityFigure.dash,
            "The scanning placeholder carries the entity's defaulted `-65` RSSI and the row withholds it. "
                + "**This is the pair that fails if the identifier gate is dropped**: the first half proves "
                + "the fabricated-looking value is really on the object, and the second proves it does not "
                + "reach the screen. A row that printed it would show `-65 dBm` — a confident signal reading "
                + "for a strap that has not been found, which is the discovery-`100` battery defect wearing "
                + "a different unit.")
        assertTest(
            DeviceSettingsView.factValue(.deviceId, device: scanningPlaceholder) == ActivityFigure.dash,
            "…and the same placeholder draws no device identifier either, from the same gate and for the "
                + "same reason: `id` is the empty string it was constructed with, and a column titled "
                + "DEVICE ID holding blank space is worse than one holding the app's word for no reading.")
        assertTest(
            DeviceSettingsView.factValue(.signal, device: factStrap) == "-71 dBm",
            "A discovered strap's SIGNAL is its own advertisement RSSI, in dBm. **It is a discovery-time "
                + "reading and the page says so**: the value comes from `didDiscover` and nothing refreshes "
                + "it while connected, so it describes the moment the strap was found rather than the link's "
                + "quality now.")
        assertTest(
            DeviceSettingsView.DeviceFact.allCases.allSatisfy {
                DeviceSettingsView.factValue($0, device: nil) == ActivityFigure.dash
            },
            "With no strap object at all, every fact in the row draws `—`. Not `0`, and not an empty "
                + "column: the dash is this app's one word for *nothing was measured*, and a fact row on a "
                + "fresh install is the state this covers.")

        // **`unpair()` is not asserted here, and saying so is the point rather than an omission.** Its whole
        // behaviour is `ManageBLEConnectionUseCase.disconnect()` → `WhoopBLEManager.cancelPeripheralConnection`,
        // and reaching that requires a `CBCentralManager` — which raises a system Bluetooth prompt mid-run,
        // the reason `CLAUDE.md` gives for the strap-model precedence rule living in a `public static` rather
        // than behind a manager. So what covers the button is the two things around it: its **gate** is
        // `DeviceViewModel.isConnected`, whose underlying `connectionState` is asserted across all six cases
        // above, and its **destination** is the disconnect path this app already had. What is not covered is
        // that the tap does anything, and the reader should read that as *unverified* rather than as *tested*.

        // ---- Home's badge: the connection dot's rule, which is the whole of what is assertable ----
        //
        // The dot is a drawing and this runner has no renderer, so what is covered is the **value the
        // drawing reads** rather than the dot: `WhoopConnectionState.isLinked` and the `linkColor` derived
        // from it, in `Presentation/DesignSystem/WhoopConnectionState+Extensions.swift`. The same caveat
        // §15 attaches to its bars applies here — a passing run is evidence about the rule and not about
        // the picture, and the dot's size, position and knockout ring are the user's to check on a screen.
        let linkedStates = connectionStates.filter(\.isLinked)
        assertTest(
            linkedStates == [.connected, .syncing],
            "Exactly two of the six connection states are a live link: `.connected`, and `.syncing`, which "
                + "is a connected strap draining its history. The other four are not, and neither is `nil` "
                + "— Home reads no strap object at all as `.disconnected`, where this arm already lands. "
                + "`.syncing` is the arm that makes the rule worth asserting rather than assuming: a dot "
                + "that read *connected* and *everything else* would draw red beside the words "
                + "`SYNCING HISTORY`, which is the app calling a working strap absent. Note that neither "
                + "`.syncing` nor `.error` is constructed anywhere in this build — `WhoopBLEManager` "
                + "assigns the other four only — so both arms are unreachable today and are held by this "
                + "assertion rather than by a screen.")
        assertTest(
            linkedStates.allSatisfy { $0.linkColor == Theme.recoveryGreen }
                && connectionStates.filter { !$0.isLinked }
                    .allSatisfy { $0.linkColor == Theme.recoveryRed },
            "The dot is green for a linked strap and red for one that is not, across all six states. "
                + "**The red is the change**: the badge this replaced drew a disconnected strap in the "
                + "neutral `textMuted`, and a neutral states nothing — it cannot be told from a dimmed "
                + "control, which is what the same colour means a few points away on the `SLEEP` row.")
        assertTest(
            connectionStates.allSatisfy { $0.linkColor != Theme.recoveryYellow },
            "…and the amber is gone. The badge used to draw `.scanning`, `.connecting` and `.syncing` in "
                + "`recoveryYellow`, which put a strap the app is still searching for and a strap it is "
                + "draining in one bucket between green and red — a third position no reader can act on "
                + "differently. This is the assertion that fails if the third arm comes back, and it is "
                + "the pair to the one above it: two colours, and no reachable third.")
    }
}
