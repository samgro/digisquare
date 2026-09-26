# Plan: Fix hometown search for Mexico City and other city-level "regions"

## Context

Typing "Mexico city" in the hometown picker lists Colima, Oaxaca, Zacatecas, Silver City NM… and
never Mexico City. The search settings are the cause: `ios/Hackysack/CitySearch.swift` runs an
`MKLocalSearchCompleter` with `resultTypes = .address` and
`addressFilter = MKAddressFilter(including: .locality)`. MapKit files Ciudad de México (a federal
entity) at the `administrativeArea` tier, so the filter drops it and the completer pads the list
with loose token matches ("…City" towns in New Mexico, Mexican state capitals whose subtitle says
Mexico).

Reproduced from macOS with the same settings (the completer and address APIs are shared):

| filter | "Mexico city" |
|---|---|
| `.locality` | Colima, City Park I Apaseo, Oaxaca, Zacatecas, Aguascalientes, Chihuahua (the screenshot) |
| `[.locality, .administrativeArea]` | **Mexico City \| Mexico** first, then the same rows |

Widening the filter alone would also list real states ("California \| United States", "New York \|
United States"), which must not be pickable as a hometown. Resolving completions shows the
discriminator: `MKMapItem.addressRepresentations.cityWithContext` is **"Mexico City, Mexico" /
"Tokyo, Japan" / "Berlin, Germany" / "Singapore"** for cities and city-states, and **empty** for
California and Hong Kong SAR. `cityName` is *not* usable — it echoes "California" for the state.
(`cityWithContext` came back as `""`, not nil, for the state; treat empty as absent.)

Outcome: Mexico City (and Tokyo, Berlin, Washington DC, Singapore) become findable, plain states
never appear in the list, and picking one saves the same "Mexico City, Mexico" string the Current
Location row would show.

Confirmed against current code: `ios/Hackysack/CitySearch.swift` (one completer, `.locality`
filter, `cityName(for:)` resolves a tapped completion through `MKLocalSearch`, `cityName(at:)`
reverse-geocodes the current location), `ios/Hackysack/CityPickerView.swift` (shows
`completion.title`/`subtitle` verbatim, no debounce). `EditProfileView.swift` only uses the static
`CitySearch.cityName(at:)`. No tests cover either file.

## Approach

Two completers on the same query: the existing strict one (`.locality`) and a wide one
(`[.locality, .administrativeArea]`). Rows the wide completer adds are, by construction,
region-tier; there are only a few per query (e.g. one "New York \| United States"). Resolve just
those through `MKLocalSearch(request: .init(completion:))`, keep the ones whose `cityWithContext`
is non-empty, and show the wide list in its own order minus the rejected rows. A small cache keyed
by `title|subtitle` means retyping never re-resolves, and a short debounce keeps resolves off the
per-keystroke path so MapKit's throttling (`MKError` code 3) isn't hit. Countries stay excluded
(Singapore is still filed as an administrative area, so it works; Monaco may not — accepted).

No user-location `region` bias: a hometown picker should rank "Paris, France" over "Paris, TX"
wherever the user stands.

## Changes

### `ios/Hackysack/CitySearch.swift`

1. Replace the single completer with two, both `resultTypes = .address`, delegate = self:
   - `localityCompleter` — `MKAddressFilter(including: .locality)` (today's behaviour).
   - `regionCompleter` — `MKAddressFilter(including: [.locality, .administrativeArea])`.

   Update the doc comment: cities, plus the region tier above them, because MapKit files some
   cities there (Mexico City is a federal entity; Tokyo, Berlin and Singapore likewise). The filter
   can't draw the city line, so region-tier rows are resolved and kept only when MapKit gives them
   a city name.
2. `search(for:)`: keep the trim/empty handling; set `queryFragment` on both completers. Add a
   ~250 ms debounce (`Task.sleep` in a cancellable `searchTask`) before setting the fragments, so a
   fast typist triggers one round of completions and resolves per pause. Bump a `generation`
   counter per query so late results from an older query are ignored (replaces the `hasQuery`
   bool for that purpose; the empty-query cancel stays).
3. Delegate: on either completer's update, store its results; when both have answered for the
   current generation, build the list:
   ```swift
   let localityKeys = Set(localityResults.map(Self.key))
   var rows: [MKLocalSearchCompletion] = []
   for completion in regionResults {
       if localityKeys.contains(Self.key(completion)) { rows.append(completion); continue }
       if await resolvedCity(for: completion) != nil { rows.append(completion) }   // cached
       // else: a state, or unresolvable — hidden
   }
   completions = rows
   ```
   Run this in a `Task` tied to the generation; cap resolves at ~4 per update (drop the rest —
   they are the least likely matches). `key` = `"\(title)|\(subtitle)"`. If the region completer
   fails but the locality one succeeds, fall back to the locality results (today's behaviour),
   and vice versa.
4. `resolvedCity(for:)` — the one place that talks to `MKLocalSearch`:
   ```swift
   /// The city a completion resolves to, formatted like a reverse geocode, or
   /// nil when MapKit filed it as a region with no city ("California"). Cached,
   /// since the same rows come back keystroke after keystroke.
   private func resolvedCity(for completion: MKLocalSearchCompletion) async -> String?
   ```
   Uses `MKLocalSearch(request: MKLocalSearch.Request(completion:))`, then the pickable-name
   helper below. Cache `[String: String?]` keyed by `key(completion)`; a failed search
   (offline/throttled) is not cached so it is retried next time.
5. Add `static func pickableCityName(for mapItem:) -> String?` returning `cityWithContext` only,
   with an empty string treated as nil — this is the gate, and what lets "Mexico City, Mexico"
   through while "California" (empty `cityWithContext`) is refused. Leave `cityName(for
   mapItem:)` (`cityWithContext ?? cityName`) for `cityName(at:)`, where the input is a real
   coordinate and the fallback is wanted.
6. `cityName(for completion:)` (tap): reuse `resolvedCity(for:)` so the tap is a cache hit for rows
   that were resolved for display; for locality rows (never resolved) it resolves now, as today.
   Fall back to `completion.title` only when the search itself fails.

### `ios/Hackysack/CityPickerView.swift`

No structural change. Keep `resolvingCompletion` for the spinner. Results now land after the
debounce plus any resolves, so keep `isSearching` true until the merged list is assigned (the
empty-results overlay already waits on it).

### Tests

MapKit can't be exercised in unit tests, but the merge/gate logic can if it is factored as a pure
function taking the two result lists plus a `resolve: (key) async -> String?` closure —
`HackysackTests/CitySearchTests.swift`: region-only rows are kept when resolved, dropped when nil,
order follows the wide list, locality rows are never resolved, the resolve cap holds.

## Verification

1. `xcodebuild -project Hackysack.xcodeproj -scheme Hackysack -destination
   'generic/platform=iOS Simulator' -configuration Debug clean build`, grep `warning:` (per
   `ios/CLAUDE.md`). Don't touch `MKMapItem.placemark` — deprecated in iOS 26 and it would warn.
2. Run the unit tests on `iPhone 17`.
3. In the simulator, Edit Profile → Hometown, English device language:

| Query | Expect |
|---|---|
| Mexico City | "Mexico City \| Mexico" first; tap saves "Mexico City, Mexico" |
| Ciudad de México | Mexico City findable (Spanish alias) — nice-to-have |
| Washington DC, Tokyo, Berlin, Singapore | pickable; saved as "Washington, DC", "Tokyo, Japan", "Berlin, Germany", "Singapore" |
| California, Texas, New York, Mexico | no bare state/country row; "California City, CA" and "New York, NY" pickable |
| Truckee, San Francisco, Paris | unchanged: "Truckee, CA", "San Francisco, CA", Paris, France above Paris, TX |
| Type fast then clear the field | list empties and stays empty; no stale rows reappear |
| Simulator custom location 19.4326, -99.1332 | Current Location row shows "Mexico City, Mexico" — matches the picked string |
| Airplane mode | locality rows still resolve to `completion.title` on tap; region rows don't appear |

Known limitation to note in the commit: places MapKit files only as countries (Monaco, and Hong
Kong, which resolves with an empty `cityWithContext`) remain unfindable; adding `.country` would
list every country, so it is left out.
