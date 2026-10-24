import Foundation
import Whoopsy

/// The day's strain writer, composed from repositories a screen test already holds.
///
/// **A fixture and not a production shape.** `HomeViewModel` and `StrainViewModel` require a
/// `RefreshStrainUseCase` because the ring and the gauge have a live feed; a section that is about
/// something else — the receptive-inactivity card, the month's tiers, a session's row — needs it only
/// to exist. Its `start()` loop belongs to `MainContainerView` and is never called from here, so
/// nothing in these fixtures recomputes anything unless the screen itself asks.
///
/// The default `motionEpochRepository` records no motion, which is the honest fixture for a section
/// that is not about the motion term: a generated quiet grid would still be a claim that the strap
/// was worn.
func fixtureRefreshStrain(
    strainRepository: any StrainRepository,
    biometricRepository: any BiometricRepository,
    userProfileRepository: any UserProfileRepository,
    motionEpochRepository: any MotionEpochRepository = FixtureMotionEpochRepository(epochs: [])
) -> RefreshStrainUseCase {
    RefreshStrainUseCase(
        calculate: CalculateStrainUseCase(
            biometricRepository: biometricRepository,
            strainRepository: strainRepository,
            userProfileRepository: userProfileRepository,
            motionEpochRepository: motionEpochRepository),
        strainRepository: strainRepository,
        biometricRepository: biometricRepository,
        motionEpochRepository: motionEpochRepository)
}
