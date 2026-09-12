# WHOOP 4.0 / 5.0 BLE Protocol Specification

This document details the reverse-engineered Bluetooth Low Energy (BLE) protocol utilized by WHOOP hardware (including WHOOP 4.0 "Harvard" / Gen 4 variants and later iterations). 

---

## 1. GATT Services & Characteristics

The device advertises standard BLE services (`0x180D` Heart Rate, `0x180F` Battery, `0x180A` Device Info), which remain largely dormant until a secure bond is established and session initialization occurs. The core data exchange happens over a proprietary custom primary service.

* **Service UUIDs:**
  * **Variant A (WHOOP 4.0 / Gen 4 - `hboylston`/`gharvard`):** `61080000-8d6d-82b8-614a-1c8cb0f8dcc6`
  * **Variant B (WHOOP MG / 5.0 / later stacks):** `fd4b0000-cce1-4033-93ce-002d5875f58a`

### Characteristic Map (Variant A Base: `610800xx-...`)
* `61080001-...`: Service Declaration Base
* `61080002`: Command Write (Client $\rightarrow$ Strap)
* `61080003`: Response Read / Indicate (Strap $\rightarrow$ Client)
* `61080004`: Events Notification (Wear state, battery, tap detection)
* `61080005`: Raw Sensor Data Stream (HR, IMU, PPG / optical packets)

---

## 2. Packet Framing & Wire Format

All binary payloads sent across the command/response and data channels are wrapped in a custom framing structure protected by a dual checksum layout (CRC8 over the length attribute and standard CRC32 over the inner payload).

[0xAA (SOF)] [Length (LE uint16)] [CRC8 (poly=0x07)] [Payload Buffer] [CRC32 (zlib)]


* **SOF (Start of Frame):** `0xAA` (1 byte)
* **Length:** Little-endian 16-bit integer representing the length of the inner payload.
* **CRC8:** Calculated across the 2-byte length field using polynomial `0x07`.
* **Payload Structure:** 
[PacketType (1B)] [Sequence (1B)] [Command/Type ID (1B)] [Data...]

* *Packet Types:* 
  * `0x23` / `0x72`: Command / Request
  * `0x24` / `0x73`: Response / Acknowledgment
  * `0x30`: Asynchronous Event / Heartbeat
* **CRC32:** Standard zlib CRC-32 computed over the entire inner payload block.

---

## 3. Initialization & Handshake Sequence

To wake up live metrics and request historical syncs from a freshly bonded strap, clients must execute a strict handshake protocol:

| Step | Command ID | Description / Purpose |
| :--- | :--- | :--- |
| **1** | `0x23` | `GET_HELLO_HARVARD` — Timestamp exchange; returns 133-byte device status payload containing the hardware serial number. |
| **2** | `0x0A` | Clock Synchronization. |
| **3** | `0x75` | Feature flag query initialization. |
| **4** | `0x76` ($\times 13$) | Feature flag iteration (`general_ab_test`, `sigproc_10_sec_dp`, etc.). |
| **5** | `0x78` ($\times 11$) | Feature flag configuration (`enable_r19_v2_packets`, `enable_capsense_wear_detect`, etc.). |
| **6** | `0x22` | Config query (returns 69-byte block). |
| **7** | `0x16` | Historical data request command. |
| **8** | `0x17` ($\times N$) | Historical data acknowledgment and trimming loop. |

---

## 4. Real-Time Streaming & Sensor Records

Once initialized, activating streaming channels (such as live heart rate via characteristic `0x2A37` or high-rate sensor packets via `61080005`) exposes granular physiological payload structures:

* **Biometric Record (v18):** Contains packed structural blocks for instantaneous Heart Rate, R-R intervals (millisecond delta for HRV calculations), skin temperature readings, and the 3-axis gravity/accelerometer vector.
* **Optical PPG Record (v26):** Streams raw multi-channel optical light-sensor samples necessary for waveform analysis.
* **Packet Reassembly:** Because raw payloads (such as IMU chunks up to 1,928 bytes or optical blocks up to 1,244 bytes) exceed standard BLE MTU sizes, clients must reassemble fragmented notifications matching sequence IDs before passing them to the CRC32 verification layer.

### The `0x2A37` R-R field is a *series*, not a value

`0x2A37` is the Bluetooth SIG Heart Rate Measurement characteristic, and its R-R field (present when flags bit 4, `0x10`, is set) is a **repeated** `uint16` list: one notification may carry several beat-to-beat intervals, and their count is whatever fits the payload after the flags, the heart rate and the optional energy-expended field. Each value is in units of 1/1024 s, so milliseconds are `raw / 1024 * 1000`.

Two things follow, and both are load-bearing:

* **Within a notification the intervals are adjacent beats by definition**, and they arrive in beat order. That ordering is exact — unlike a timestamp, which for a BLE notification is an *arrival* instant (the app stamps `Date()` when the packet is decoded) and not the time the beats occurred.
* **A client that keeps only the first interval is discarding most of the series.** Whoopsy did exactly that until `v8`. Because Respiratory Sinus Arrhythmia is read off the beat-to-beat tachogram — a contiguous, correctly ordered series — a thinned stream cannot support it. The full list is now stored in `biometric_samples.rrIntervalsMs`, with `rrIntervalMs` retained as the first element.

The decoder (`WhoopPacketDecoder.decodeStandardHeartRate`) has always returned the whole list; `WhoopBLEManager` is where it was being truncated.