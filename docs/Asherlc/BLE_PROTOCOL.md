# The Swift 4.0 client

`docs/BLE_PROTOCOL.md` cites this project by role as **the Swift 4.0 client**: an unofficial Swift
client for the strap's BLE protocol, read for one design input rather than for any offset.

**`WhoopBleDataWatchdog` is a file inside that client, not a repository.** An earlier citation here
linked it as `Asherlc/WhoopBleDataWatchdog`, and that URL has never resolved — the check that catches
this is opening the link, not reading the name.

## Identity and evidence base

* **`Asherlc/whoop-ble-swift`** — "Unofficial Swift client for the reverse-engineered WHOOP strap BLE
  protocol", MIT. Its `ios/WhoopBleDataWatchdog.swift` is the source of the **15 s** silent-stream
  re-send window on a 4.0, recorded in `docs/BLE_PROTOCOL.md` §4 and in `KeepAlivePolicy`. On silence
  its delegate re-runs the client's activation commands, which is the "re-arm the producers" shape
  this app's keep-alive copies. Nothing else in this repository rests on it.
  <https://github.com/Asherlc/whoop-ble-swift>

## Excerpts

From `ios/WhoopBleDataWatchdog.swift` — the file, quoted verbatim:

> /// Monitors for BLE data silence and triggers a callback when no data arrives
> /// within the configured timeout. The WHOOP strap sends 0x28 packets at ~1 Hz;
> /// sustained silence means our activation commands were likely dropped.

> init(queue: DispatchQueue, timeoutSeconds: TimeInterval = 15) {

And the answer to what it does when the window elapses, from `ios/WhoopBleClient.swift`:

> func watchdogDidDetectSilence(_: WhoopBleDataWatchdog, retryCount _: UInt64) {
>     guard connectionManager.cmdCharacteristic != nil else {
>         watchdog.stop()
>         return
>     }
>     sendActivationCommands(includeImu: isImuStreaming)
> }

That is the whole of what is taken from this client: a 15-second window, and a re-send of the same
enable sequence rather than a reconnect.
