# Design

Prefer not to use row separators. Hide them in lists
(`.listRowSeparator(.hidden)`) and let spacing divide the rows. Only keep a
separator when the design truly needs one.

# Building

Build the app for the simulator with:

```
xcodebuild -project Hackysack.xcodeproj -scheme Hackysack \
  -destination 'generic/platform=iOS Simulator' -configuration Debug clean build
```

Use `clean build`, not just `build` — an incremental build skips recompiling
files you didn't touch, so a warning already sitting in an untouched file
(including one introduced by a change to a *different* file, like a shared
method losing its actor isolation at a call site elsewhere) won't show up.

Run this before finishing any change to the ios app. Check the output for
`warning:` lines (grep -i warning) and fix any that come from the Swift
compiler before returning — do not leave warnings for the user to clean up.
The `appintentsmetadataprocessor` "Metadata extraction skipped" warning is
expected (the app has no AppIntents.framework dependency) and can be ignored.

# Testing

Unit tests live in `HackysackTests` (Swift Testing, `@testable import
Hackysack`). Run them on a concrete simulator; `generic/` destinations cannot
run tests:

```
xcodebuild -project Hackysack.xcodeproj -scheme Hackysack \
  -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug test
```

The checkin ranking tests read `fixtures/ranking/*.json` at the repo root,
shared with the API's tests and written by `npm run fixtures:record` in `api`.
Keep the ranking model (`PlaceRanker.swift`) free of CoreLocation and other
device-only frameworks so it stays testable from fixtures.

Run the tests before finishing any change to the home/work detector
(`FrequentPlaceDetector.swift`), the visit history, or the visit processor.
The detector tests are driven by generated schedules in
`HackysackTests/VisitScenarioBuilder.swift`; add a scenario there when a new
kind of routine (a second job, a night shift, a long trip) needs covering.
