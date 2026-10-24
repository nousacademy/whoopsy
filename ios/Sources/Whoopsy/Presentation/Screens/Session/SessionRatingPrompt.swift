import SwiftUI

/// The one question asked after a session ends: how hard did it feel?
///
/// **A sheet over the session page, not a field before the pop.** `LiveSessionUseCase.end()` has already
/// stamped `endedAt` and saved the row when this appears, so the recorded window is the session itself
/// and not the session plus the time spent answering. RATING writes the answer onto that same row;
/// SKIP dismisses without a second write, which leaves the session unrated rather than rated zero.
///
/// **Five words rather than a 0–10 slider**, because a number nobody can reproduce a week later is not a
/// measurement. `WorkoutRPE.Bucket` is the one place the word becomes the stored figure, and this view
/// knows nothing about that mapping beyond reading `value` back out of the bucket it was handed.
struct SessionRatingPrompt: View {
    let onRate: (Int) -> Void
    let onSkip: () -> Void

    private var buckets: [WorkoutRPE.Bucket] { WorkoutRPE.Bucket.allCases }

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("How hard did that feel?")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)

                Text("Rate the effort, not the result. This is your own figure and is not compared with the heart-rate score.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            // `-1` selects nothing: the session has no answer yet, and pre-selecting a bucket would
            // put a rating in front of the user that they did not give.
            SegmentedPillControl(
                titles: buckets.map(\.shortLabel),
                selectedIndex: -1,
                onSelect: { index in onRate(buckets[index].value) })

            Button(action: onSkip) {
                Text("SKIP")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .tracking(1.0)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.homeBackground)
        .presentationDetents([.height(270)])
        // **A swipe-down must not be a third way out.** RATING and SKIP both tell the caller what to do
        // with the session it just ended; a dismissal that only lowered the sheet would leave the user
        // on a page whose session no longer exists, with the row in the database and nothing handing it
        // to Home. So the sheet is modal until one of the two answers is given.
        .interactiveDismissDisabled()
        .preferredColorScheme(.dark)
    }
}
