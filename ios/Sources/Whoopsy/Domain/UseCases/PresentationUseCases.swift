import Foundation

public final class SaveWorkoutUseCase: Sendable {
    private let repository: any WorkoutRepository
    public init(repository: any WorkoutRepository) { self.repository = repository }
    public func execute(_ workout: WorkoutSession) async throws { try await repository.save(workout) }
}

// **A type kept *in case* a feature returns is a type that keeps its name in doc comments across the
// codebase** — and when the feature does go, every one of those pointers goes stale with it. That is
// the argument for making a removal complete rather than partial: the type, its callers and the
// comments that cited it go in one pass, because a pointer at deleted code is worse than no pointer.
// Four files in this repo used to describe their own rule by naming a type that had already been
// deleted, which is what that failure looks like from the inside.
//
// No placeholder is left behind to carry a note like this one. A doc comment in this repo hangs on a
// declaration, and an empty `enum` whose only job is to hold one would be a symbol in `Sources/` with
// no reader — the same dead weight the note is about, in a smaller size.
