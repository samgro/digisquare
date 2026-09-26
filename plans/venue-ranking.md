# Plan: venue search ranking

## Context

At La Taqueria (2889 Mission St, SF) the Check In list led with Josey Baker
Bread, Reem's, Mission Pie (closed since 2019), Chase Mortgage, "Jesus
Gabriel Yanez" (a business-registry record for a person) and Secret Food
Tours. La Taqueria was nowhere on the first screen.

Reproduced against Overture release 2026-09-23.0 with DuckDB:

- Overture has La Taqueria: confidence 0.99, from Meta, corroborated by
  Foursquare, `basic_category` restaurant.
- The fix in the screenshot, back-solved from the displayed distances, was
  about 41 m from Overture's pin (Google's coordinate for the venue). More
  than 70 places sit within 77 m of that pin; La Taqueria was 16th by
  distance, and the server returned only the 20 nearest.
- The iOS ranker assumed 12 m of pin error, so with a 5 m simulator fix a
  venue 41 m away scored about 25x worse than one 10 m away. No category or
  popularity term could recover that, and nothing penalized junk records.

## What Overture gives us (measured on all 73,584 SF places)

| Signal | Finding | Use |
|---|---|---|
| `sources[]` | Exactly one provider record per place; Overture promotes a source rather than merging. The other entries are Overture's own bookkeeping. Its length means nothing. | The dataset name only. |
| Provider mix | BrightQuery 41%, meta 37%, Foursquare 12%, Microsoft 10%, AllThePlaces <1%. | |
| BrightQuery | Built from business filings: the source of the person names, "Inc"s, every `permanently_closed` record in SF, 93% of `health_care`, 92% of `legal_service`. | -2 unless corroborated. |
| Bridge files | List every provider matched to a GERS id. 28% of SF places have 2+; half of restaurants and bars, a tenth of professional services. La Taqueria 2, Reem's 3, the junk 1. Chains inflate it (Chase Mortgage 5). No bbox, so a whole-release scan (about 5 GB, 4 minutes for even a small box). | +0.5 per extra provider, capped at 2; a once-per-release batch pass. |
| `confidence` | Fixed per-provider defaults except for Meta. Overture's docs say not comparable across providers. Nearly everything below 0.5 is Meta with a null status. | Log-odds, only when the status is unconfirmed, never a gain. |
| `operating_status` | open / null / permanently_closed. Null tracks low Meta confidence. | Stored. |
| `taxonomy.hierarchy`, `basic_category` | A clean tree: 13 roots, about 2,300 leaves, about 280 basic categories. A null or root-only hierarchy (about 5%) is mostly registry junk. | Category tiers; -3 when missing. |
| Source `update_time` | Real for Foursquare (2020-2026) and Microsoft (2008-2025; Chase Mortgage is 2016). Delivery date for the rest. | -1 before 2023 for those two. |
| Popularity, ratings | None in Overture, none in Foursquare's free dataset. | Our own checkin counts. |

## What was built

1. **Import keeps the signals** (`api/src/lib/overture.ts`, migration
   `0013_add_place_quality_signals`): `source_dataset`, `source_updated_at`,
   `basic_category`, `taxonomy_hierarchy`, `operating_status`,
   `provider_count`, `prior`. `api/src/lib/place-quality.ts` computes the
   prior: quality (registry feed, missing category, staleness, confidence)
   plus a category tier (+1 food, drink, lodging, venues, parks, stations,
   landmarks; -1.5 services, practitioners, tour operators, civic
   organizations). Existing rows need `npm run coverage:refresh -- --all`.
2. **Bridge pass** (`npm run overture:bridge`): scans the release's bridge
   files once, writes `places.provider_count` and matches imported Foursquare
   venues to their Overture ids. The search adds the corroboration bonus when
   a row is read, so a re-import never blanks it.
3. **Retrieval** (`api/src/lib/places-search.ts`): the nearest-pin search
   returns 60 instead of 20 and drops rows whose prior is below -4 (a
   registry record with no category). Name search still finds everything.
   `GET /places` returns `prior` and `basicCategory`.
4. **Ranking** (`ios/Hackysack/PlaceRanker.swift`): pin placement error 12 m
   to 30 m; the server prior is added to the score (waived when the user has
   their own history there); a place the priors count against is never
   auto-suggested, and the suggestion margin is judged against rivals with
   their penalties waived, so an office beside the fix still keeps the list
   showing. The resolution and size terms use the fix's accuracy alone.
   One SFO expectation changed with that: from a tight fix at a counter in
   the terminal the airport now leads the list rather than being jumped to,
   because the counter is a plausible answer; from a coarse fix it is still
   suggested outright. The alternative (treating shops inside recorded
   grounds as parts of the venue) was tried and dropped as too eager.
   Two fixtures changed because the refresh attached grounds the old
   recordings lacked: a runner with history at Golden Gate Park now gets
   the park suggested at the de Young's door, and a first-time visitor at
   Lift Workspace gets the Truckee Tahoe Airport, whose Overture polygon
   takes in the business park (a regular there gets Lift on top, with the
   airport close enough behind that the list is shown). Town halls and
   courthouses got the category boost so a town hall leads the departments
   listed inside it, which the footprint table's old office penalty used to
   arrange.
   `PlaceFootprint` keeps only the physical fixtures
   (parking, restrooms, chargers); the office and service penalties moved to
   the server prior. The models moved to `Place.swift` and
   `CheckinHistoryEntry.swift` so the ranker compiles outside the app.
5. **Evaluation** (`npm run ranking:evaluate`): ranks candidates for real
   Swarm checkins with the app's own ranker (compiled with swiftc) from noisy
   fixes, reporting top-1, top-3 and MRR by accuracy; flags override weights
   for before/after runs.
6. **Fixture**: `mission-la-taqueria` in `api/scripts/ranking-scenarios.ts`.

## Results

Measured with `npm run ranking:evaluate` on the `venuesearch-ranking` Neon
branch (Bay Area, release 2026-09-23.0): 300 imported Swarm checkins at
venues matched to Overture places, a fix 35 m per axis off each pin, no
history.

| Ranker | top-1 | top-3 | MRR |
|---|---|---|---|
| Before (pin error 12 m, no prior) | 3.7% | 16.3% | 0.160 |
| After (pin error 30 m, prior weight 1) | 26.3% | 46.0% | 0.400 |

Pin error 20 and 40 m score the same as 30 within noise; 50 m loses,
mostly at 65 m accuracy. Prior weight 1.5 gains a point of top-1 and 0.7
loses five, so 1 stays. The storefront radius (25 m) loses badly when
shrunk to 15 or 10. Ordering the large-venue search by prior was tried and
reverted: it filled the candidates with well-attested colleges a kilometer
away, whose guessed 600 m grounds then beat every storefront.

The corroboration bonus is the strongest single term: per extra provider,
0 gives 12.0% top-1, 0.25 gives 21.7%, 0.5 gives 26.3%, 0.75 gives 29.3%
and 1.0 gives 30.3%. That is inflated, though: the truths are found through
Foursquare's bridge records, so nearly all of them are corroborated, which
rewards any bonus. It stays at 0.5 until the evaluation has ground truth
from the app's own checkins.

At the La Taqueria fix from the screenshot, La Taqueria moves from 13th
to 7th: the six places still ahead of it are real restaurants nearer that
fix. From Overture's own pin for it, it is first.

The 8% of cases where the true venue is not among the candidates, and the
misses that remain, are mostly one of two things: a storefront school or
airline office typed `college_university` or `airport`, which the app's
footprint table sizes as a campus or an airfield (so the fix is "inside"
it), and Foursquare venues whose Overture match is a different pin for the
same business.

## Not done, worth doing

- The footprint guesses for `airport` (1.5 km) and `college_university`
  (600 m) fire for airline ticket offices and storefront schools. Most real
  campuses and airfields have recorded grounds; the guessed disc could shrink
  when a venue has none, or apply only to corroborated records.

- A time-of-day x category term (coffee in the morning, bars at night).
- A "report closed or wrong" action: Mission Pie shows no Overture signal
  catches every closure.
- Once Swarm venues are matched, point their checkins at the Overture rows
  and retire the duplicates.
