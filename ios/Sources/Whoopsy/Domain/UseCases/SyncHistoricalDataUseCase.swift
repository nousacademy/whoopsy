import Foundation

public final class SyncHistoricalDataUseCase: Sendable {
    private let bleRepository: any WhoopBLEDeviceRepository
    private let biometricRepository: any BiometricRepository

    public init(
        bleRepository: any WhoopBLEDeviceRepository,
        biometricRepository: any BiometricRepository
    ) {
        self.bleRepository = bleRepository
        self.biometricRepository = biometricRepository
    }

    /// How many drained samples are buffered before a write.
    ///
    /// Larger than the live stream's ten because a drain delivers a day or more of records back to
    /// back rather than one pulse per second, so the same buffer size would mean thousands of
    /// single-row transactions. The final partial buffer is flushed when the stream ends, and
    /// `AsyncStream.finish()` delivers what it has buffered before ending — so the last, newest
    /// records are not lost to a size threshold.
    private static let batchSize = 50

    /// Drains the strap's flash buffer back to the last sample this app holds, **writes the records
    /// it recovers**, and returns what the drain did.
    ///
    /// The window's start is the most recent stored sample, which is a **resumed** cursor rather than
    /// a fresh one: the strap keeps its read pointer across connections, so a drain that stopped early
    /// continues from where it stopped instead of fetching the same records again. A day is the
    /// fallback when nothing is stored, which is a first sync rather than an incremental one.
    ///
    /// **The persistence is this call's other half, and its absence was the silent failure.** The
    /// manager decoded nothing from the records it drained until this change — a drain reported its
    /// counts and the heart rates and R-R intervals inside those records went nowhere. The two now
    /// run together: the consumer is subscribed **before** the request, because the request is what
    /// creates the drain, and the manager finishes the stream when the drain ends
    /// (`concludeDrain` → `finishHistoricalTelemetry`). Subscribing afterwards would attach to a
    /// stream that had already finished, or to the next drain's.
    ///
    /// **The two endings are handled differently on purpose.** A refusal that never started a drain
    /// (`.noCommandPath`) cancels the consumer, because nothing will ever finish the stream it is
    /// waiting on. An ending that stopped the drain early (`.endedWithoutConfirmation`) is still
    /// thrown — the caller must not report a completed sync — but only after the consumer has
    /// drained and saved every record the strap did send, because those records are real.
    @discardableResult
    public func execute() async throws -> HistoricalSyncOutcome {
        let latestSample = try await biometricRepository.getLatestSample()
        let startDate = latestSample?.timestamp ?? Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let endDate = Date()

        let samples = bleRepository.historicalTelemetryStream
        let bioRepo = biometricRepository
        let persistence = Task {
            var buffer: [BiometricSample] = []
            var lastFlush = Date()

            /// **Drops records this database already holds, and the duplicate is the reason.**
            /// `biometric_samples` is keyed on an auto-increment `id`, so every drain inserts new rows
            /// for records it has sent before — and the strap re-sends the same batch on every link
            /// (measured: the same 59 records stamped `2026-08-24 12:51` on six successive drains).
            /// The live path cannot collide, because an arrival instant is never repeated; a drained
            /// record is stamped by the strap and repeats exactly. An automatic drain on every connect
            /// would turn that into 59 new rows each time, so the filter is what makes it safe.
            func unsaved(_ batch: [BiometricSample]) async -> [BiometricSample] {
                guard let first = batch.first?.timestamp, let last = batch.last?.timestamp else {
                    return batch
                }
                let stored = (try? await bioRepo.getSamples(
                    from: first.addingTimeInterval(-1), to: last.addingTimeInterval(1))) ?? []
                let taken = Set(stored.map(\.timestamp))
                return batch.filter { !taken.contains($0.timestamp) }
            }

            for await sample in samples {
                buffer.append(sample)

                // The time check is the live stream's rule carried over: a slow drain still writes
                // while it is running rather than holding the whole history in memory.
                if buffer.count >= Self.batchSize || Date().timeIntervalSince(lastFlush) >= 5.0 {
                    let toSave = buffer
                    buffer.removeAll(keepingCapacity: true)
                    lastFlush = Date()
                    do {
                        let fresh = await unsaved(toSave)
                        if !fresh.isEmpty { try await bioRepo.saveSamples(fresh) }
                    } catch {
                        AppLogger.database.error(
                            "Failed saving drained biometric batch: \(error.localizedDescription)")
                    }
                }
            }

            if !buffer.isEmpty, let fresh = try? await unsaved(buffer), !fresh.isEmpty {
                try? await bioRepo.saveSamples(fresh)
            }
        }

        do {
            let outcome = try await bleRepository.requestHistoricalSync(from: startDate, to: endDate)
            // The drain has concluded, so the manager has finished the stream and the consumer is
            // draining what it buffered. Waiting for it is what makes "the sync returned" mean the
            // samples are on disk — the Device screen reloads the moment this returns.
            await persistence.value
            return outcome
        } catch let error as WhoopSyncError {
            switch error {
            case .noCommandPath:
                persistence.cancel()
            case .commandUnavailable:
                // Not a drain's error; it is listed so the switch stays exhaustive, and a consumer
                // waiting on a stream nothing will finish is the one thing it must not leave behind.
                persistence.cancel()
            case .endedWithoutConfirmation(let records, let batches, let oldest, let newest):
                AppLogger.ble.warning("""
                    Drain ended without confirmation: \(records, privacy: .public) record(s) in \
                    \(batches, privacy: .public) batch(es), spanning \
                    \(oldest?.description ?? "none", privacy: .public) → \
                    \(newest?.description ?? "none", privacy: .public). The records were saved; the \
                    strain refresh will score the days they cover.
                    """)
            }
            await persistence.value
            throw error
        } catch {
            persistence.cancel()
            await persistence.value
            throw error
        }
    }
}
