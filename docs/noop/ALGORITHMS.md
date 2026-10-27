# Excerpts — the counter and the activity class

Quoted verbatim from the reference's `docs/PROTOCOL_SENSORS.md`. This is the material this
repository's `docs/ALGORITHMS.md` cites when it describes the strap's own pedometer; the
protocol-level context is in [BLE_PROTOCOL.md](BLE_PROTOCOL.md).

> | 57 | 2 / u16 | Selected cumulative step/motion counter; selection detailed below |
> | 59 | 2 / u16 | Cadence-like raw value, supplied from u8; high byte is zero |
> | 61 | 2 / u16 | Hardware counter when software override is active, otherwise zero |
> | 63 | 1 / u8 | Activity: 0 still, 1 walk, 2 run; other input classes become FF and must not be surfaced as those three classes |
> | 64 | 1 / u8 | 10 hex when software counter override is active, otherwise zero |

> For this layout, the normal value at 57 is the hardware pedometer count. When software counter
> override is enabled, 57 carries the software count, 61 retains the hardware count and 64 becomes
> `0x10`. With no override, bytes 61–62 and 64 are zero. This allows a client to retain both sources
> and avoid turning a change of source into a false step delta.

> The hardware tuple contains count, cadence-like byte and activity class. A cadence value is **not a
> documented steps-per-minute conversion**; even a consistent relationship to speed is not guaranteed.
> Preserve it raw. Neither counter is established as equal to the official app's aggregated step count.
> Rollover, reset and day boundaries remain unresolved; a timestamped counter must …
