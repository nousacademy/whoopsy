# The APK reading

`docs/BLE_PROTOCOL.md` cites this project by role as **the APK reading**: a third independent
reverse-engineering, from decompiled WHOOP Android plus PacketLogger captures. It is used as a third
opinion, and two of its claims are recorded there without being adopted.

## Identity and evidence base

* **`docs/whoop-ble-protocol.md`** (the fork `Asherlc/dofek`) — a third independent reading, from APK
  decompilation of WHOOP Android v5.439.0 plus PacketLogger captures and live probing, and **the
  source of §2.1's second worked 5.0 frame**. It corroborates §6's `R21` layout **independently of
  the community reference**: its table lists the same eight fields, at the same frame-absolute offsets once its 8-byte
  envelope is added, and it states the range in as many words — "±8g (1g ≈ 4096 LSB)". It also names
  packet `0x2B` / 43 `REALTIME_RAW_DATA` with the "Maverick R21 format" behind it, which is a third
  independent statement that layout 21 rides a **live** packet. Two of its claims are recorded here
  without being adopted, because each needs a capture to settle. It describes the `0x2B` flow as
  needing no toggle, which is true only when piggybacking on a session the WHOOP app has already
  configured (§6). And it states that **the strap requires BLE bonding before accepting any
  commands**, with unbonded writes answered by `PUFFIN_COMMAND_RESPONSE` and error `0x049c` — which,
  if it holds, is a precondition this app does not currently satisfy and would have to before any
  command path is worth building. Note that the standard SIG services are separately reported to work
  **unbonded**, so the two claims are consistent and describe different paths: `0x2A37` is why this
  app's live heart rate works at all, and the custom command characteristic is a different question.

  **Two limits on that claim, and both matter.** It is **single-sourced**: a public code search finds
  `0x049c` in this project's docs and nowhere else in the ecosystem, so it is one unreplicated report
  rather than a settled fact — and it is not a standard ATT code, being an application-level error in
  the Puffin payload, so it cannot be checked against a spec. And its **bonded iOS evidence is
  piggybacking, not bonding**: the successful path it reports is
  `retrieveConnectedPeripherals(withServices:)` **reusing the bond the official WHOOP app already
  established**, which is a different claim from a third-party app creating one. Read together with
  the community reference's own just-works bond — which ships on macOS **and** iOS — and the fact that Apple exposes no
  bond state at all (§7 Q6), the honest status for a third-party iOS client is that it **can** bond,
  but Apple cannot tell it whether it already has.
  <https://github.com/Asherlc/dofek/blob/main/docs/whoop-ble-protocol.md>

## Excerpts

_No verbatim passage of this document is quoted in this repository yet. The quotes below are the two
it is cited for, as `docs/BLE_PROTOCOL.md` records them._

> **±8g (1g ≈ 4096 LSB)** — the `R21` range, in its own words.

> `PUFFIN_COMMAND_RESPONSE` with error **`0x049c`** — its report that unbonded writes are refused,
> single-sourced and not reproduced here.

> Packet **`0x2B` / 43 `REALTIME_RAW_DATA`**, carrying the "Maverick R21 format".
