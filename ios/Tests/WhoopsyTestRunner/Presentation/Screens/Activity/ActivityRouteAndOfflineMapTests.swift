import Foundation
import SwiftUI
import Whoopsy

enum ActivityRouteAndOfflineMapTests {
    static func run() async throws {
        // MARK: - The route map

        // A pure value with no database behind it, like the delta and the zone rows above: `ActivityRoute`
        // is the whole of the rule, and `ActivityRouteMapView` is construction with nothing in it that
        // could be got wrong in a way an assertion could see.
        //
        // **The block is shaped by the fact that no session this app can show has a route.** The
        // `RECORD ROUTE` toggle is the only producer of `workout_route_points`, it is off by default, and
        // `biometric_samples` holds 0 rows here — so every literal below is built by hand, and the
        // `nil`-at-fewer-than-two gate is not an edge case but the state every screen is in. What the
        // block proves is the arithmetic and the gates; nothing here is evidence that a recorded path is
        // accurate.
        //
        // The two absences the reference's own overlay carries get an assertion each, because each is a
        // figure this app could be tempted to invent: ELEVATION has no producer at any layer, and a route
        // whose fixes share one instant has no span to divide a speed by. Both are *dropped* and neither is
        // drawn as a `—`, which is the whole of what the assertions below pin.
        do {
            /// A fix at a known place and instant, with a heart rate the map never draws.
            func fix(
                _ latitude: Double,
                _ longitude: Double,
                at seconds: TimeInterval,
                hr: Int = 120
            ) -> WorkoutRoutePoint {
                WorkoutRoutePoint(
                    latitude: latitude,
                    longitude: longitude,
                    timestamp: ActivityDetailTests.anchor.addingTimeInterval(seconds),
                    heartRate: hr)
            }

            // MARK: The gate

            // One fix is a place, not a path. This pair is the whole absence rule: the page draws no
            // section at all on `nil`, so a route that admitted one point would put a marker on a map and
            // claim a session moved.
            let onePoint = ActivityRoute(points: [fix(51.5, -0.12, at: 0)])
            let twoPoints = ActivityRoute(points: [fix(51.5, -0.12, at: 0), fix(51.51, -0.12, at: 60)])
            assertTest(
                onePoint == nil && twoPoints?.points.count == 2,
                "A route is two positions or it is nothing: one plausible fix is a place rather than a path "
                    + "and is the same absence a session with none draws (\(ActivityDetailTests.shown(onePoint?.points.count)))")

            // MARK: The filter, applied on the read

            // The same test the recording path drops fixes with, applied again here. The column has no
            // constraint behind it, so a row written by an older build or by a hand-run probe would
            // otherwise be drawn — and a `(0, 0)` on a route is a polyline striking across the map to the
            // Gulf of Guinea.
            let filtered = ActivityRoute(points: [
                fix(51.5, -0.12, at: 0),
                fix(0, 0, at: 10),  // CoreLocation's "not resolved yet" placeholder
                fix(91, -0.12, at: 20),  // latitude past ±90
                fix(51.5, 181, at: 30),  // longitude past ±180
                fix(.nan, -0.12, at: 40),  // arithmetic that went wrong
                fix(51.51, -0.12, at: 50),
            ])
            assertTest(
                filtered?.points.count == 2
                    && filtered?.points.allSatisfy { $0.isPlausible } == true,
                "…and the plausibility filter is applied **on the read as well as at the write**: a `(0, 0)`, "
                    + "a latitude past ±90, a longitude past ±180 and a `NaN` are all dropped from a stored "
                    + "route (\(ActivityDetailTests.shown(filtered?.points.count)) of 6 kept)")

            // MARK: The ordering, and the tie-break that is not available

            // Sorted by instant, because a polyline is an ordered sequence by definition. The equal pair is
            // the assertion that matters: `sorted(by:)` is stable (SE-0372), so two fixes sharing an instant
            // keep the order they arrived in — and `id` is a fresh `UUID`, so a secondary sort on it would
            // order the same two rows differently on every launch.
            let arrivedFirst = fix(51.5, -0.12, at: 0, hr: 100)
            let arrivedSecond = fix(51.51, -0.12, at: 0, hr: 110)
            let ordered = ActivityRoute(points: [
                fix(51.53, -0.12, at: 120),
                fix(51.52, -0.12, at: 60),
                arrivedFirst,
                arrivedSecond,
            ])
            assertTest(
                ordered?.points.map(\.heartRate) == [100, 110, 120, 120],
                "…and the path is ordered by its own instants, with two fixes sharing one keeping the order "
                    + "they arrived in — the stable sort, since `id` is a fresh `UUID` and would order the "
                    + "same two rows differently on every launch "
                    + "(\(ActivityDetailTests.shown(ordered?.points.map(\.heartRate))))")

            // MARK: The length

            // One degree of latitude on the IUGG mean sphere. Pinned against a literal rather than against
            // `CLLocation.distance(from:)`, which is the whole reason the haversine is hand-rolled: a runner
            // that must not build a `CLLocationManager` cannot ask the framework for this figure.
            let oneDegree = ActivityRoute(points: [fix(10, 20, at: 0), fix(11, 20, at: 60)])
            assertTest(
                abs((oneDegree?.distanceMeters ?? 0) - 111_195.08) < 1,
                "A degree of latitude is 111,195 m on the mean sphere — the haversine pinned to a literal, so "
                    + "a wrong radius or a degrees/radians slip fails rather than agreeing with itself "
                    + "(\((oneDegree?.distanceMeters ?? 0).formattedOneDecimal()) m)")

            // **The length is a sum along the path and not the distance between its ends.** A three-point
            // route whose middle fix is off the straight line is longer than the two-endpoint route through
            // the same start and finish, and a value that quietly measured end-to-end would report a
            // switchback as a straight line.
            let dogleg = ActivityRoute(points: [
                fix(51.50, -0.12, at: 0),
                fix(51.51, -0.12, at: 60),
                fix(51.51, -0.11, at: 120),
            ])
            let endToEnd = ActivityRoute(points: [fix(51.50, -0.12, at: 0), fix(51.51, -0.11, at: 120)])
            assertTest(
                (dogleg?.distanceMeters ?? 0) > (endToEnd?.distanceMeters ?? .infinity) + 1,
                "…and the length is the sum of the consecutive legs rather than the span between the two "
                    + "ends, so a route that doubles back is longer than the same two endpoints in a "
                    + "straight line (\((dogleg?.distanceMeters ?? 0).formattedOneDecimal()) m over "
                    + "\((endToEnd?.distanceMeters ?? 0).formattedOneDecimal()) m)")

            // MARK: The frame

            // A path that covered no ground at all is framed at the floor rather than at a zero-height box,
            // and the floor is applied *under* the padding so a route that exactly fills it still gets its
            // margin. The centre is the midpoint of the path's own extremes either way.
            let tiny = ActivityRoute(points: [fix(51.5000, -0.1200, at: 0), fix(51.5001, -0.1201, at: 60)])
            assertTest(
                abs((tiny?.region.latitudeSpan ?? 0) - ActivityRoute.minimumSpanDegrees) < 1e-9
                    && abs((tiny?.region.longitudeSpan ?? 0) - ActivityRoute.minimumSpanDegrees) < 1e-9
                    && abs((tiny?.region.centerLatitude ?? 0) - 51.50005) < 1e-9,
                "A route that barely moved is framed at `minimumSpanDegrees` on both axes rather than at a "
                    + "box metres wide, with its centre still the midpoint of its own extremes "
                    + "((\(ActivityDetailTests.shown(tiny?.region.latitudeSpan))))")

            let wide = ActivityRoute(points: [fix(51.0, -1.0, at: 0), fix(52.0, 0.0, at: 600)])
            assertTest(
                abs((wide?.region.latitudeSpan ?? 0) - 1.4) < 1e-9
                    && abs((wide?.region.longitudeSpan ?? 0) - 1.4) < 1e-9,
                "…and a route that covered a degree is framed at 1.4 of it, so the path sits inside its "
                    + "frame with a margin on every side (\((wide?.region.latitudeSpan ?? 0).formattedOneDecimal())°)")

            // MARK: The two figures

            // Both unit systems driven explicitly, because the unit is a parameter rather than a read of
            // `Locale.current` inside the formatter — a figure that only holds in one region is a test that
            // fails on someone else's machine, and this app ships to both.
            assertTest(
                ActivityRoute.Unit.forLocale(Locale(identifier: "en_US")) == .imperial
                    && ActivityRoute.Unit.forLocale(Locale(identifier: "en_GB")) == .imperial
                    && ActivityRoute.Unit.forLocale(Locale(identifier: "de_DE")) == .metric,
                "The unit is the locale's own measurement system, with **metric as the one named case** and "
                    + "everything else falling to imperial — `en_US` and `en_GB` both get miles, which is "
                    + "right for road distance")

            // Exactly one mile, so the two systems' answers are a conversion rather than a rounding.
            let mile = ActivityRoute(points: [
                fix(0.01, 0.01, at: 0),
                fix(0.01 + 1_609.344 / 111_195.08, 0.01, at: 3_600),
            ])
            assertTest(
                mile?.distanceText(in: .imperial) == "1.0 mi"
                    && mile?.distanceText(in: .metric) == "1.6 km",
                "…and one statute mile prints `1.0 mi` where the same distance prints `1.6 km`, through the "
                    + "app's own one-decimal formatter — which is `String(format:)` with no locale, so the "
                    + "point is a point in every region "
                    + "(\(ActivityDetailTests.shown(mile?.distanceText(in: .metric))))")

            // MARK: The speed, and the span it divides by

            // 1.6 km in 3600 s is 1609.344 / 3600 = 0.44704 m/s, which is 1.609 km/h and 1.0 mph. The
            // assertion that matters is not the arithmetic but the **divisor**: the route's own span and
            // never the session's duration, since the toggle can be turned on two minutes into a run and
            // dividing by the session's own length would report an average over distance never measured.
            assertTest(
                mile?.averageSpeedText(in: .imperial) == "1.0 mph"
                    && mile?.averageSpeedText(in: .metric) == "1.6 km/h"
                    && abs((mile?.durationSeconds ?? 0) - 3_600) < 0.5,
                "…and its average is the path's own length over **the path's own span**, so a route whose "
                    + "toggle was flipped on mid-session reports the average it actually covered "
                    + "(\(ActivityDetailTests.shown(mile?.averageSpeedText(in: .metric))))")

            // Every fix at one instant is a route with no time in it. A speed is a distance over a time, so
            // with no time there is no answer rather than a fast one — and the overlay drops the cell
            // rather than drawing a `—` beside a real distance, which is the same rule that keeps ELEVATION
            // off it.
            let instantaneous = ActivityRoute(points: [
                fix(51.50, -0.12, at: 0),
                fix(51.51, -0.12, at: 0),
            ])
            // **Flattened to one optional before it is compared**, and that is not tidiness: on the
            // failable initialiser's own optional this reads `String??`, and `instantaneous?.
            // averageSpeedText(…) == nil` then asks whether *`instantaneous`* is nil and answers `false`
            // while the speed is `nil` — the same trap §18 records against `recorded?.source == nil`.
            let instantaneousSpeed = instantaneous.flatMap { $0.averageSpeedText(in: .imperial) }
            assertTest(
                instantaneous != nil
                    && instantaneous?.durationSeconds == 0
                    && instantaneousSpeed == nil
                    && instantaneous?.distanceText(in: .metric) == "1.1 km",
                "…and a route whose every fix shares one instant has no span to divide by, so it draws the "
                    + "distance alone rather than a speed and never a `—` "
                    + "(speed \(ActivityDetailTests.shown(instantaneousSpeed)))")

            // MARK: The words

            // The spoken sentence is the card's whole accessible content, because a map is a drawing and
            // says nothing to VoiceOver. Two things about it are rules rather than phrasing: it names the
            // route rather than only reciting figures, and **it never speaks a duration** — the page prints
            // the session's own `DURATION` above this card, and a second span in a reader's ear with
            // nothing to tell the two apart is worse than silence.
            //
            // The fixture's own span is a full hour, so the duration clause has something to say and its
            // absence is a fact rather than an accident of a zero-length route.
            let spoken = mile?.spokenSummary(in: .imperial) ?? ""
            assertTest(
                spoken == "Map of the recorded route. 1.0 miles, averaging 1.0 miles per hour.",
                "…and the card speaks one sentence naming the route and its two figures, through the same "
                    + "one-decimal formatter the caption uses (\(spoken))")
            assertTest(
                !spoken.contains("1 hour") && !spoken.lowercased().contains("duration"),
                "…and **no duration is spoken**: that route's fixes span a full hour, so a sentence that "
                    + "recited its own span would say so — and the page's own `DURATION` is already on "
                    + "screen a few inches above this card, with nothing in a reader's ear to tell the two "
                    + "apart (\(spoken))")

            // A route with no span drops the speed clause rather than speaking a zero, on the same rule
            // that drops the cell from the overlay. Its distance is a ten-thousandth of a degree of
            // latitude, which in kilometres prints `1.1` — the kilometre figured rather than the mile one
            // so the assertion beside it is not a second copy of the same conversion.
            assertTest(
                instantaneous?.spokenSummary(in: .metric)
                    == "Map of the recorded route. 1.1 kilometres.",
                "…and with no span to divide by the speed clause is dropped rather than spoken as zero "
                    + "(\(ActivityDetailTests.shown(instantaneous?.spokenSummary(in: .metric))))")
        }

        // MARK: - The page's own route property, through the database

        // The block above proves the value; this one proves **the page is handed it**. `ActivityRoute` is
        // drawn only from `ActivityDetailViewModel.route`, which forwards `session.route` — and `session`
        // comes back through `GRDBWorkoutRepository`, which fetches `workout_route_points` per workout. So
        // the chain this block walks is the whole distance between a stored fix and a polyline: storage →
        // repository → the page's own property. A read that dropped the children would leave every
        // assertion above passing while every screen drew nothing.
        do {
            let db = LocalDatabaseManager(inMemory: true)
            let workoutRepository = GRDBWorkoutRepository(db: db)
            let profileRepository = GRDBUserProfileRepository(db: db)

            let path = [
                WorkoutRoutePoint(
                    latitude: 51.50, longitude: -0.12,
                    timestamp: ActivityDetailTests.anchor.addingTimeInterval(0), heartRate: 110),
                WorkoutRoutePoint(
                    latitude: 51.51, longitude: -0.12,
                    timestamp: ActivityDetailTests.anchor.addingTimeInterval(300), heartRate: 130),
            ]
            let withRoute = WorkoutSession(
                startedAt: ActivityDetailTests.anchor,
                endedAt: ActivityDetailTests.anchor.addingTimeInterval(1_800),
                strain: 8,
                averageHeartRate: 120,
                maxHeartRate: 150,
                route: path,
                splits: [],
                activityName: "Running")
            let withoutRoute = WorkoutSession(
                startedAt: ActivityDetailTests.anchor,
                endedAt: ActivityDetailTests.anchor.addingTimeInterval(1_800),
                strain: 8,
                averageHeartRate: 120,
                maxHeartRate: 150,
                route: [],
                splits: [],
                activityName: "Running")
            try await workoutRepository.save(withRoute)
            try await workoutRepository.save(withoutRoute)

            let stored = try await workoutRepository.getWorkouts(for: withRoute.startedAt.startOfDay)
            let readBack = stored.first { $0.id == withRoute.id }
            let blank = stored.first { $0.id == withoutRoute.id }

            assertTest(
                readBack?.route.map(\.heartRate) == [110, 130]
                    && ActivityRoute(points: readBack?.route ?? [])?.durationSeconds == 300,
                "A route survives the round trip through `workout_route_points`, in order and with its own "
                    + "instants: two fixes 300 s apart, which is the span `ActivityRoute` measures the "
                    + "speed over rather than the session's 1,800 "
                    + "(\(ActivityDetailTests.shown(readBack?.route.count)) points, "
                    + "\((ActivityRoute(points: readBack?.route ?? [])?.durationSeconds ?? -1).formattedOneDecimal()) s)")

            assertTest(
                blank?.route.isEmpty == true && ActivityRoute(points: blank?.route ?? []) == nil,
                "…and a session that recorded none is `nil` rather than an empty route, which is the page's "
                    + "whole absence for this block: no heading, no frame and no note "
                    + "(\(ActivityDetailTests.shown(blank?.route.count)) points)")

            // Built from the **read-back** session and not from the one just saved, which is the point of
            // the block: a page handed the in-memory object would draw a map off a route that might never
            // have reached the column.
            if let readBack, let blank {
                let recordedPage = await MainActor.run {
                    ActivityDetailViewModel(
                        session: readBack,
                        workoutRepository: workoutRepository,
                        userProfileRepository: profileRepository,
                        biometricRepository: GRDBBiometricRepository(db: db),
                        recoveryRepository: GRDBRecoveryRepository(db: db),
                        offlineMaps: SpyOfflineMaps())
                }
                let blankPage = await MainActor.run {
                    ActivityDetailViewModel(
                        session: blank,
                        workoutRepository: workoutRepository,
                        userProfileRepository: profileRepository,
                        biometricRepository: GRDBBiometricRepository(db: db),
                        recoveryRepository: GRDBRecoveryRepository(db: db),
                        offlineMaps: SpyOfflineMaps())
                }
                let pageRoute = await MainActor.run { recordedPage.route }
                let blankRoute = await MainActor.run { blankPage.route }

                assertTest(
                    pageRoute?.points.map(\.heartRate) == [110, 130] && blankRoute == nil,
                    "…and both reach the page's own `route` property — the one the view draws from — as a "
                        + "route and as an absence, so the map is on the sessions that recorded a path and "
                        + "no section at all is drawn on the ones that did not "
                        + "(\(ActivityDetailTests.shown(pageRoute?.points.count)) and \(ActivityDetailTests.shown(blankRoute?.points.count)))")
            }
        } catch {
            assertTest(false, "The route round-trip block threw: \(error)")
        }

        // MARK: - The offline map's renderer decision

        // The whole of `RouteMapRenderer` is a pure function of two values, so the part of this feature that
        // decides *which* map a page draws is asserted here with no database and no spy behind it — and it
        // sits above every `LocalDatabaseManager` in this section, so it still asserts if one below throws.
        //
        // **What it cannot see is the drawing.** `map(route:unit:regionID:)` returns an `AnyView` built by a
        // type in a module this build never compiles, and the runner has no renderer, so the offline card's
        // own pixels are the user's to check on a device. What is assertable is the gate.
        do {
            let hike = ActivityDetailTests.session("Hiking", startOffset: 0, durationSeconds: 3_600, region: "whoopsy-7c1f")

            assertTest(
                RouteMapRenderer.resolve(session: hike, state: .ready)
                    == .offline(regionID: "whoopsy-7c1f"),
                "A row that names a region, against a store that says those tiles are on disk, draws the "
                    + "offline card — and the identifier handed to the renderer is the row's own rather than "
                    + "one re-derived, which is what lets the renderer open the store the session wrote to")

            // Every other answer, swept rather than sampled. `.ready` is the only state that reaches the
            // offline renderer, so a half-finished download, a failed one, a build with no SDK behind it and
            // a region the user simply never asked for all have to draw the iOS map.
            let notReady: [OfflineMapState] = [
                .unsupported,
                .absent,
                .downloading(fraction: 0),
                .downloading(fraction: 0.5),
                .downloading(fraction: 1),
                .failed("No connection."),
            ]
            let drawnOffline = notReady.filter {
                RouteMapRenderer.resolve(session: hike, state: $0) != .mapKit
            }
            assertTest(
                drawnOffline.isEmpty,
                "…and every one of the other \(notReady.count) states draws the iOS map instead, which is the "
                    + "half that matters: a card drawn over tiles that are not there is a blank rectangle on a "
                    + "hillside, where the standard map is at worst missing its imagery and at best fine "
                    + "(\(drawnOffline.count) state(s) reached the offline branch)")

            assertTest(
                RouteMapRenderer.resolve(
                    session: ActivityDetailTests.session("Hiking", startOffset: 0, durationSeconds: 3_600),
                    state: .ready) == .mapKit,
                "…and a store that says `.ready` changes nothing for a session whose row names no region, "
                    + "which is what makes the gate a pair rather than one flag: the tiles have to exist *and* "
                    + "the row has to have asked for them")

            let fallback = await MainActor.run { UnavailableOfflineMaps() }
            let fallbackSupported = await fallback.isSupported
            let fallbackState = await fallback.state(for: "whoopsy-7c1f")
            assertTest(
                fallbackSupported == false && fallbackState == .unsupported,
                "…and the service every build without the SDK is handed reports the capability itself as "
                    + "absent rather than answering with an empty store: `.unsupported` and not `.absent`, "
                    + "because `.absent` means *this app could download here and has not*, which is a state "
                    + "the user can act on (isSupported \(fallbackSupported), state \(fallbackState))")
        }

        // MARK: - The offline switch, through the spy

        // The runner must not build a `TileStore`, for `SpyOfflineMaps`' own reason — a real one downloads
        // over the network and needs a secret token merely to be constructed — so the store is spied and
        // this block drives the use case's own decisions: what it asks, what it refuses, and which of the
        // two turns `cancelDownload()` is called on. That pair is the whole contract the protocol states,
        // and it is a pair no single fixture can see.
        do {
            let db = LocalDatabaseManager(inMemory: true)
            let workoutRepository = GRDBWorkoutRepository(db: db)
            let profileRepository = GRDBUserProfileRepository(db: db)

            /// One session per case, because the switch's state is per session and every field below is read
            /// off the one that was just driven. The telemetry repository is shared between the use case and
            /// its biometric stream the way §19's two-readers block shares it, so a session that never
            /// starts is still a session that *could*.
            func makeSession(
                _ location: SpyLocationTracking, _ maps: SpyOfflineMaps
            ) -> LiveSessionUseCase {
                let telemetry = ScriptedTelemetryRepository()
                return LiveSessionUseCase(
                    controller: SpyLiveActivityController(),
                    locationTracking: location,
                    streamBiometricsUseCase: StreamBiometricsUseCase(
                        bleRepository: telemetry, biometricRepository: EmptyBiometricStore()),
                    saveWorkoutUseCase: SaveWorkoutUseCase(repository: workoutRepository),
                    userProfileRepository: profileRepository,
                    bleRepository: telemetry,
                    activeFastRepository: SpyActiveFastRepository(),
                    offlineMaps: maps)
            }

            // ---- A build with no map SDK behind the switch ----

            let noSDKLocation = SpyLocationTracking()
            let noSDKMaps = SpyOfflineMaps()
            let noSDKSession = makeSession(noSDKLocation, noSDKMaps)
            let supported = await noSDKSession.isOfflineMapSupported
            await noSDKSession.setOfflineMap(true)
            let noSDKError = await noSDKSession.offlineMapError
            let noSDKRequested = await noSDKSession.isOfflineMapRequested
            let noSDKRegion = await noSDKSession.offlineRegionID
            let noSDKState = await noSDKSession.offlineMapState
            let noSDKPrompts = await MainActor.run { noSDKLocation.requestPermissionCount }
            let noSDKDownloads = await MainActor.run { noSDKMaps.downloadCount }

            assertTest(
                supported == false,
                "A build with no SDK behind the switch reports the capability as absent before anything is "
                    + "asked, which is what lets the screen draw the switch disabled and say why rather than "
                    + "accepting a flip that does nothing")
            assertTest(
                noSDKError?.contains("build") == true,
                "…and flipping it anyway is refused with an authored sentence naming the build as the reason "
                    + "rather than the user's position or their permission (\(noSDKError ?? "nil"))")
            assertTest(
                noSDKPrompts == 0 && noSDKDownloads == 0 && !noSDKRequested && noSDKRegion == nil
                    && noSDKState == .absent,
                "…and it gets no further than that: the location prompt is not raised, no download is "
                    + "attempted, the switch does not latch and no region is minted — the whole refusal is one "
                    + "sentence and nothing else (prompts \(noSDKPrompts), downloads \(noSDKDownloads), "
                    + "region \(ActivityDetailTests.shown(noSDKRegion)), state \(noSDKState))")

            // ---- A permission the user refused earlier ----

            let deniedLocation = SpyLocationTracking()
            let deniedMaps = SpyOfflineMaps()
            await MainActor.run {
                deniedLocation.permission = .denied
                deniedMaps.isSupported = true
            }
            let deniedSession = makeSession(deniedLocation, deniedMaps)
            await deniedSession.setOfflineMap(true)
            let deniedError = await deniedSession.offlineMapError
            let deniedPrompts = await MainActor.run { deniedLocation.requestPermissionCount }
            let deniedDownloads = await MainActor.run { deniedMaps.downloadCount }

            assertTest(
                deniedPrompts == 0,
                "A permission already refused is read rather than re-requested: `requestPermission()` on a "
                    + "settled status is a no-op that iOS answers with no delegate callback at all, so a "
                    + "continuation parked behind it is never resumed and the switch would wait forever "
                    + "(\(deniedPrompts) prompt(s))")
            assertTest(
                deniedError?.contains("Privacy & Security") == true,
                "…and the refusal is reported as a sentence naming where the user changes it "
                    + "(\(deniedError ?? "nil"))")
            assertTest(
                deniedDownloads == 0,
                "…with no download attempted, because there is no centre to download around "
                    + "(\(deniedDownloads) download(s))")

            // ---- The *other* refusal ----
            //
            // Still `.undetermined` after a request means Location Services are off for the whole device,
            // which the user fixes on a different screen entirely. The two get different sentences, and the
            // assertion that carries this case is that it is **not** the sentence above: one generic message
            // would send the user to a per-app setting that is not the problem.
            let offLocation = SpyLocationTracking()
            let offMaps = SpyOfflineMaps()
            await MainActor.run {
                offLocation.permission = .undetermined
                offLocation.permissionAfterRequest = .undetermined
                offMaps.isSupported = true
            }
            let offSession = makeSession(offLocation, offMaps)
            await offSession.setOfflineMap(true)
            let offError = await offSession.offlineMapError
            let offPrompts = await MainActor.run { offLocation.requestPermissionCount }

            assertTest(
                offPrompts == 1,
                "…and the case that *does* prompt asks exactly once (\(offPrompts) prompt(s))")
            assertTest(
                offError?.contains("Location Services") == true
                    && offError?.contains("Privacy & Security") != true,
                "…and gets its own sentence about Location Services being off for the device rather than the "
                    + "per-app one above, which is the pair a single generic message would collapse "
                    + "(\(offError ?? "nil"))")

            // ---- The switch on, and a fix in hand ----

            let liveLocation = SpyLocationTracking()
            let liveMaps = SpyOfflineMaps()
            await MainActor.run { liveMaps.isSupported = true }
            let liveSession = makeSession(liveLocation, liveMaps)
            await liveSession.setOfflineMap(true)

            let stateOnFlip = await liveSession.offlineMapState
            let regionOnFlip = await liveSession.offlineRegionID
            assertTest(
                stateOnFlip == .downloading(fraction: 0) && regionOnFlip?.hasPrefix("whoopsy-") == true,
                "On the way on the card is already `.downloading` at zero with a region minted, before a "
                    + "single tile is asked for — the region is named by this app and not by the store, "
                    + "because `end()` builds its session without an id and there is no session name to "
                    + "borrow while it is still recording (\(stateOnFlip), \(ActivityDetailTests.shown(regionOnFlip)))")

            assertTest(
                await waitUntil { await MainActor.run {
                    liveLocation.yield(latitude: 51.5074, longitude: -0.1278)
                } },
                "The switch waits for one position fix, read off a GPS stream the session starts for itself: "
                    + "the two switches are independent, so this one cannot borrow the route's fix and has to "
                    + "ask for its own")

            assertTest(
                await waitUntil { await MainActor.run { liveMaps.downloadCount } == 1 },
                "…and only then asks the store to download, once")
            assertTest(
                await waitUntil { await liveSession.offlineMapState == .ready },
                "…and the card lands on `.ready`, which is the answer the route map's gate is waiting for — "
                    + "read back off the store rather than assumed, so a download that failed inside the "
                    + "store would leave the card in `.failed` with its own sentence")

            let liveRegion = await liveSession.offlineRegionID
            let storedForRegion = await MainActor.run {
                liveRegion.map { liveMaps.state(for: $0) }
            }
            let centre = await MainActor.run { (liveMaps.lastLatitude, liveMaps.lastLongitude) }
            let released = await liveLocation.stopCount

            assertTest(
                centre.0 == 51.5074 && centre.1 == -0.1278,
                "…and the centre it downloaded around is the fix that was handed in rather than a constant or "
                    + "a later reading taken somewhere else (\(ActivityDetailTests.shown(centre.0)), \(ActivityDetailTests.shown(centre.1)))")
            assertTest(
                storedForRegion == .ready,
                "…and the identifier the session recorded is the one the store holds tiles under, so the "
                    + "answer the detail page gets later is about the region this session actually downloaded "
                    + "(\(ActivityDetailTests.shown(storedForRegion)))")
            assertTest(
                released == 1,
                "…and the GPS is released the moment the fix is in hand: a tile download is a one-shot, and "
                    + "leaving the radio running for it would put the blue indicator up for a session that is "
                    + "recording no route (\(released) stop(s))")

            // ---- The switch off *after* the tiles landed ----
            //
            // This and the mid-download block below are a pair, and the pair is the whole contract
            // `cancelDownload()` states. Off here must **not** cancel: the tiles are already on disk, and
            // revoking them would take back the thing the user asked for a moment earlier.
            await liveSession.setOfflineMap(false)
            let offRequested = await liveSession.isOfflineMapRequested
            let clearedRegion = await liveSession.offlineRegionID
            let clearedState = await liveSession.offlineMapState
            let keptCancels = await MainActor.run { liveMaps.cancelledCount }

            assertTest(
                !offRequested && clearedRegion == nil && clearedState == .absent,
                "Turning the switch off clears the card and the region, so the flag and the identifier the "
                    + "stored row is written from cannot disagree about what this session asked for "
                    + "(\(ActivityDetailTests.shown(clearedRegion)), \(clearedState))")
            assertTest(
                keptCancels == 0,
                "…and cancels nothing, because the download had already finished — a cancel here is the one "
                    + "the protocol forbids, and it is unreachable only because the state is read before it is "
                    + "cleared (\(keptCancels) cancellation(s))")

            // ---- The switch off *while* the tiles are still arriving ----

            let pendingLocation = SpyLocationTracking()
            let pendingMaps = SpyOfflineMaps()
            await MainActor.run {
                pendingMaps.isSupported = true
                pendingMaps.holdsDownloadOpen = true
                pendingMaps.progressValues = [0.25, 0.75]
            }
            let pendingSession = makeSession(pendingLocation, pendingMaps)
            await pendingSession.setOfflineMap(true)
            assertTest(
                await waitUntil { await MainActor.run {
                    pendingLocation.yield(latitude: 51.5074, longitude: -0.1278)
                } },
                "…and the same holds with a store that does not come back: the fix went in, so what follows "
                    + "is about the download rather than about the wait for a centre")
            assertTest(
                await waitUntil { await pendingSession.offlineMapState == .downloading(fraction: 0.75) },
                "The store's progress reaches the card: two fractions are reported and the card holds the last "
                    + "of them, which is what makes the bar on the session screen move rather than sit at zero "
                    + "for the whole download")

            let pendingRegion = await pendingSession.offlineRegionID
            await pendingSession.setOfflineMap(false)
            let pendingState = await pendingSession.offlineMapState
            let pendingRegionAfter = await pendingSession.offlineRegionID
            let pendingCancels = await MainActor.run { pendingMaps.cancelledCount }
            let orphan = await MainActor.run {
                pendingRegion.map { pendingMaps.state(for: $0) }
            }

            assertTest(
                pendingCancels == 1,
                "…and turning the switch off while it is still `.downloading` cancels it, which is the one "
                    + "turn this call exists for (\(pendingCancels) cancellation(s))")
            assertTest(
                pendingState == .absent && pendingRegionAfter == nil,
                "…leaving the card and the region cleared (\(pendingState), \(ActivityDetailTests.shown(pendingRegionAfter)))")
            assertTest(
                orphan == .absent,
                "…and nothing half-downloaded behind it: a cancelled download leaves the store as it found it, "
                    + "so a later attempt is a fresh one rather than a resumed partial (\(ActivityDetailTests.shown(orphan)))")

            // A second flip while one is already in flight is a no-op rather than a second download over the
            // first, and the region it leaves alone is the proof: re-entering would mint a new one.
            await pendingSession.setOfflineMap(true)
            let secondRegion = await pendingSession.offlineRegionID
            await pendingSession.setOfflineMap(true)
            let afterSecondFlip = await pendingSession.offlineRegionID
            assertTest(
                secondRegion != nil && afterSecondFlip == secondRegion,
                "…and flipping it on again starts a fresh attempt while a second flip against one already in "
                    + "flight is a no-op, so a double tap cannot put two downloads over each other "
                    + "(\(ActivityDetailTests.shown(secondRegion)), \(ActivityDetailTests.shown(afterSecondFlip)))")
            await pendingSession.setOfflineMap(false)

            // ---- No position fix ----

            let blindLocation = SpyLocationTracking()
            let blindMaps = SpyOfflineMaps()
            await MainActor.run {
                blindMaps.isSupported = true
                blindLocation.finishesStreamImmediately = true
            }
            let blindSession = makeSession(blindLocation, blindMaps)
            await blindSession.setOfflineMap(true)
            let blindGaveUp = await waitUntil { await blindSession.offlineMapError != nil }
            let blindError = await blindSession.offlineMapError
            let blindRequested = await blindSession.isOfflineMapRequested
            let blindRegion = await blindSession.offlineRegionID
            let blindDownloads = await MainActor.run { blindMaps.downloadCount }
            let blindStops = await blindLocation.stopCount

            assertTest(
                blindGaveUp,
                "A session that cannot get a position fix gives up rather than leaving the switch latched, and "
                    + "does so when the stream ends rather than when the ten-second wait expires — which is "
                    + "what the spy's already-finished stream stands in for (\(blindError ?? "nil"))")
            assertTest(
                blindError?.contains("position fix") == true,
                "…and says so in its own words, naming the sky rather than the network: the tiles have to be "
                    + "fetched while there is still signal, and a fix is what they are fetched *around* "
                    + "(\(blindError ?? "nil"))")
            assertTest(
                !blindRequested && blindRegion == nil && blindDownloads == 0,
                "…with the switch back off and no region left behind, so the card is not left claiming a "
                    + "download that never happened (\(blindRequested), \(ActivityDetailTests.shown(blindRegion)), "
                    + "\(blindDownloads) download(s))")
            assertTest(
                blindStops == 1,
                "…and the GPS released even on the failing path, which is the one place a leaked radio would go "
                    + "unnoticed because nothing is waiting on it anymore (\(blindStops) stop(s))")
        }

        // MARK: - The region on the stored row, and the gate that reads it

        // The block above proves the switch; this one proves the **row it leaves behind**, and then the
        // distance from that row to the card. The chain is the whole feature: `end()` writes the region
        // exactly when the user left the switch on, `GRDBWorkoutRepository` carries it, and
        // `RouteMapRenderer.resolve` turns the pair (row, store) into the one branch that draws offline. A
        // read that dropped the column would leave every assertion above passing while every page drew the
        // standard map.
        do {
            let db = LocalDatabaseManager(inMemory: true)
            let workoutRepository = GRDBWorkoutRepository(db: db)

            let named = ActivityDetailTests.session(
                "Hiking", startOffset: 0, durationSeconds: 3_600, region: "whoopsy-7c1f")
            let nameless = ActivityDetailTests.session("Hiking", startOffset: 0, durationSeconds: 3_600)
            try await workoutRepository.save(named)
            try await workoutRepository.save(nameless)

            let stored = try await workoutRepository.getWorkouts(for: ActivityDetailTests.anchor.startOfDay)
            let namedRow = stored.first { $0.id == named.id }
            let namelessRow = stored.first { $0.id == nameless.id }

            assertTest(
                namedRow?.offlineRegionID == "whoopsy-7c1f",
                "A session's region survives the round trip through `workouts`, which is what makes the detail "
                    + "page's answer about it a fact about the database rather than about the process that "
                    + "wrote it (\(ActivityDetailTests.shown(namedRow?.offlineRegionID)))")
            assertTest(
                namelessRow?.offlineRegionID == nil,
                "…and a session that never asked reads back `nil` rather than an empty string — the same "
                    + "distinction `source` and `steps` carry: asking for no region is not asking for one "
                    + "called `\"\"`, and a mapper that substituted one would put a session on a region that "
                    + "does not exist (\(ActivityDetailTests.shown(namelessRow?.offlineRegionID)))")

            let bridged = namedRow.map { RouteMapRenderer.resolve(session: $0, state: .ready) }
            assertTest(
                bridged == .offline(regionID: "whoopsy-7c1f"),
                "…and the row that came back **off the database** is what the gate reads: the stored region "
                    + "beside a store that says `.ready` resolves to the offline card, which is the whole "
                    + "distance between a switch the user flipped during a session and the map they see "
                    + "afterwards (\(ActivityDetailTests.shown(bridged)))")
        } catch {
            assertTest(false, "The offline region round-trip block threw: \(error)")
        }

        // MARK: - The page's own renderer

        // `ActivityDetailViewModel.routeRenderer` is the property `ActivityDetailView` switches on, and it is
        // resolved once in `load()` rather than recomputed in the `body` — so what this block drives is the
        // page's own answer, through the same `load()` the screen calls. **The view's two branches are not
        // assertable here**: one of them is a `Map` and the other is an `AnyView` built in a module this
        // build does not compile, and the runner has no renderer at all.
        do {
            let db = LocalDatabaseManager(inMemory: true)
            let workoutRepository = GRDBWorkoutRepository(db: db)
            let profileRepository = GRDBUserProfileRepository(db: db)

            func page(_ subject: WorkoutSession, _ maps: SpyOfflineMaps) async -> ActivityDetailViewModel {
                let model = await MainActor.run {
                    ActivityDetailViewModel(
                        session: subject,
                        workoutRepository: workoutRepository,
                        userProfileRepository: profileRepository,
                        biometricRepository: GRDBBiometricRepository(db: db),
                        recoveryRepository: GRDBRecoveryRepository(db: db),
                        offlineMaps: maps)
                }
                await model.load()
                return model
            }

            let readyMaps = SpyOfflineMaps()
            await MainActor.run {
                readyMaps.isSupported = true
                readyMaps.states["whoopsy-7c1f"] = .ready
            }
            let asked = await page(
                ActivityDetailTests.session("Hiking", startOffset: 0, durationSeconds: 3_600, region: "whoopsy-7c1f"),
                readyMaps)
            assertTest(
                await asked.routeRenderer == .offline(regionID: "whoopsy-7c1f"),
                "A page handed a session whose region has tiles on disk resolves to the offline card, so the "
                    + "session screen's switch is what the detail page draws from afterwards")

            let emptyMaps = SpyOfflineMaps()
            await MainActor.run { emptyMaps.isSupported = true }
            let pending = await page(
                ActivityDetailTests.session("Hiking", startOffset: 0, durationSeconds: 3_600, region: "whoopsy-7c1f"),
                emptyMaps)
            assertTest(
                await pending.routeRenderer == .mapKit,
                "…and a region named on the row that the store has never heard of draws the standard map, "
                    + "which is the state a session is in the moment it ends: the row is written before the "
                    + "tiles land, so a page opened in that window is drawn rather than left blank")

            let unasked = await page(
                ActivityDetailTests.session("Hiking", startOffset: 0, durationSeconds: 3_600), readyMaps)
            assertTest(
                await unasked.routeRenderer == .mapKit,
                "…and a store holding a ready region changes nothing for a session whose row names none, "
                    + "because the two halves of the gate are asked of different things — the row and the "
                    + "store — and neither alone is enough")

            let unavailable = await page(
                ActivityDetailTests.session("Hiking", startOffset: 0, durationSeconds: 3_600, region: "whoopsy-7c1f"),
                SpyOfflineMaps())
            assertTest(
                await unavailable.routeRenderer == .mapKit,
                "…and a build with no SDK behind the switch draws the standard map like every other build, "
                    + "which is the property the whole seam was built for: forgetting to link Mapbox costs "
                    + "this app nothing but the offline option")
        }
    }
}
