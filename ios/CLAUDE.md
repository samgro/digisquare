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
