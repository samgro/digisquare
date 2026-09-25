# TestFlight launch plan

Goal: get Hackysack into the hands of a small group of trusted friends through
TestFlight, with enough monitoring to know when something breaks, and nothing
more. Anything that only matters for a public App Store release is listed under
[Deferred](#deferred-not-before-this-launch) at the bottom.

## Where things stand

Already in place:

- Sign in with Apple, sign out, token refresh with reuse detection, rate-limited
  auth endpoints.
- Check in manually or from a suggested visit, friends vs private visibility,
  offline retry of failed checkins.
- Friend requests, friends feed, user search, profiles with avatars.
- Debug-only UI (test users, visit debug menu) is behind `#if DEBUG`, and device
  builds already point at the Railway production API.
- API validates its environment at boot, and the test-user routes 404 unless
  `ENABLE_TEST_USERS` is set.

Gaps found while reviewing the code:

| Gap | Why it matters | Where it's handled |
| --- | --- | --- |
| The app icon asset catalog has no image | App Store Connect rejects the upload | [Manual: App Store Connect](#manual-apple-developer-and-app-store-connect) |
| No `ITSAppUsesNonExemptEncryption` key | Every build gets stuck on the export compliance question | [Session 4](#session-4-ios-release-readiness-and-crash-reporting) |
| Can't delete or edit a checkin once it's posted (the API has `PATCH /checkins/:id`, the app has no UI for it, and there's no delete at all) | Checking in at the wrong place is the most common mistake users will make | [Session 1](#session-1-edit-and-delete-your-own-checkins) |
| No way to delete an account | Apple guideline 5.1.1(v); Beta App Review can reject external builds for it | [Session 2](#session-2-delete-account-and-privacy-policy) |
| No privacy policy | Required for external TestFlight testing, and the app collects location | [Session 2](#session-2-delete-account-and-privacy-policy) |
| API errors are caught and sent to `console.error` in ~30 places, and Railway can't alert on log lines | A 500 on the friends feed would go unnoticed until someone texts you | [Session 3](#session-3-api-error-reporting-and-health-check) |
| Release builds log nothing (`DevLog` compiles away) and there's no crash or non-fatal reporting | A decoding error after an API change shows up as "Couldn't Load …" with no trace | [Session 4](#session-4-ios-release-readiness-and-crash-reporting) |
| `/places` needs no auth and every call bills Google | A leaked Railway URL could run up a Places bill | [Manual: production backend](#manual-production-backend) (quota cap) |

## Monitoring recommendation

| Concern | Use | Why |
| --- | --- | --- |
| iOS crashes | **TestFlight / Xcode Organizer** (built in) **+ Sentry** | TestFlight gets crash reports and tester screenshot feedback for free, but they arrive late and miss non-fatal errors. Sentry adds same-minute crashes plus captured non-fatal API and decoding failures. |
| API errors | **Sentry** (`@sentry/node`) | Railway keeps logs but has no alerting on error lines. Sentry's free Developer plan (5k errors/month) emails you on the first occurrence of each new error. That's the biggest gain for the least effort in this whole plan. |
| API uptime | Railway healthcheck, plus an optional free uptime monitor (Better Stack or UptimeRobot) | Railway restarts a dead service; an external monitor tells you when Neon or Railway itself is down. |
| Analytics | **No SDK.** TestFlight metrics (installs, sessions, crashes per build) plus a few saved SQL queries in Neon | With a dozen testers you can read the database directly. An analytics SDK would also change what the privacy policy has to say. |
| Tester feedback | TestFlight's built-in screenshot feedback | Testers take a screenshot, tap Share Beta Feedback, and it shows up in App Store Connect. Tell them it exists. |

Use one Sentry organization with two projects (`hackysack-api` and
`hackysack-ios`). Both SDKs cost nothing for a group this size.

---

## Suggested order

1. [Manual: accounts and signups](#manual-accounts-and-signups) (about 15 min, and it gets the Sentry DSNs you'll need later)
2. Sessions 1–4. They're independent, so they can run in parallel worktrees
   (`new-worktree.sh`).
3. [Manual: production backend](#manual-production-backend)
4. [Manual: Apple Developer and App Store Connect](#manual-apple-developer-and-app-store-connect)
5. [Manual: launch day](#manual-launch-day)

---

## Manual: accounts and signups

- [ ] Confirm the Apple Developer Program membership for team `X5G52MAAW2` is
      the paid program ($99/yr), not a free personal team. TestFlight needs
      the paid one.
- [ ] Create a Sentry account (free Developer plan) and two projects:
      `hackysack-api` (platform: Node.js) and `hackysack-ios` (platform: Apple
      iOS). Copy both DSNs.
- [ ] In Sentry, create an auth token with `project:releases` and
      `project:write` scopes for uploading dSYMs (Session 4).
- [ ] Decide the name that appears in App Store Connect. It must be unique
      across the whole App Store, and "Hackysack" may already be taken. It can
      differ from the home screen name, which comes from
      `INFOPLIST_KEY_CFBundleDisplayName` and can stay "Hackysack".

---

## Session 1: Edit and delete your own checkins

Users will check in at the wrong place or want to take back a message. Right
now the only fix is you editing Neon by hand.

**API**
- Add `DELETE /checkins/:id`, scoped to the owner the same way `PATCH` is:
  someone else's checkin gets the same 404 as one that doesn't exist. Return
  204.
- Tests in `checkins.test.ts` (owner deletes → 204; someone else's → 404; bad
  id → 400) and a Bruno request for each case.

**iOS**
- Add `delete(checkinId:)` and `update(checkinId:message:visibility:)` to
  `CheckinsAPI`, backed by the existing `PATCH`.
- On the timeline, give your own confirmed checkins a context menu (or swipe
  actions) with **Edit** and **Delete**.
  - Edit opens a sheet for the message and the `CheckinPrivacyToggle`. The
    place can't be changed; to change it, delete the checkin and check in again.
  - Delete asks for confirmation ("Delete this checkin?") and removes the row
    optimistically, putting it back if the request fails.
- `CheckinStore` owns both mutations so the timeline and the friends feed stay
  consistent.
- Pending or failed entries that never reached the server should only offer
  delete, which just drops them locally.

**Done when:** API tests pass, the iOS clean build has no warnings, and you've
edited and deleted a checkin on a device against a local API.

## Session 2: Delete account and privacy policy

**API**
- Add `DELETE /users/me`. It deletes the user row, which cascades to sessions,
  checkins and friendships, and then deletes the user's avatar objects from R2.
  If the R2 cleanup fails, log it but still return 204; an orphaned avatar
  isn't worth failing the deletion over.
- Tests, plus a Bruno request.
- Out of scope for TestFlight: revoking the Apple token through Apple's
  `/auth/revoke` endpoint, which needs a Sign in with Apple private key and
  client secret. See [Deferred](#deferred-not-before-this-launch).

**iOS**
- In Profile, add a destructive **Delete Account** row below Sign Out. Confirm
  with an alert that says what gets removed (checkins, friends, profile). Then
  call the endpoint and sign out locally with the existing
  `sessionStore.signOut`. Also clear the local visit history and suggestions,
  since those live on the device.

**Privacy policy**
- Write `PRIVACY.md` at the repo root. The repo is public, so
  `https://github.com/samgro/hackysack/blob/main/PRIVACY.md` works as the
  privacy policy URL. Base it on what the code actually does:
  - Collected on the server: Apple user ID, the name and email Apple shares,
    profile name, bio, avatar photo (R2), checkins with place and coordinates,
    friendships, and session metadata (user agent, IP address).
  - Kept only on the device: visit history used for suggestions and home/work
    detection. Say explicitly that it is never uploaded until the user accepts a
    suggestion.
  - Third parties: Google Places receives coordinates for place lookups. Sentry
    receives crash and error reports with no location data (see Session 4).
    Hosting is Railway, Neon and Cloudflare R2.
  - How to delete your data: in-app Delete Account, or email.
- Link to it from the Profile screen (a "Privacy Policy" row that opens the URL).

**Done when:** API tests pass, the iOS clean build has no warnings, and
deleting a test account on a device against a local API leaves no rows behind.

## Session 3: API error reporting and health check

- Add `@sentry/node`. Add `SENTRY_DSN` to `config.ts` as an **optional**
  variable so local dev and tests work without it, and initialize Sentry in
  `index.ts` only when it's set. Errors only; no tracing or profiling.
- Add a small `reportError(error, details)` helper in `src/lib/` that calls
  `console.error` and `Sentry.captureException`. Replace the bare
  `console.error(error)` calls in the route catch blocks and in
  `google-places.ts` / `rate-limit.ts` with it. Tag each report with the route
  and the userId (a UUID, not personal data).
- Add `app.onError` so anything uncaught also goes through `reportError` and
  returns a JSON 500 in the same shape the routes use.
- Add `GET /health`, which runs `select 1` against Neon and returns 200 or 503.
  Keep `/` as it is.
- Add a request log middleware that prints method, route path **without the
  query string** (it contains coordinates), status, duration, and userId when
  there is one. Railway's logs then answer "what failed for Alice at 3pm".
- Tag Sentry events with the Railway environment (`RAILWAY_ENVIRONMENT_NAME`)
  and the commit (`RAILWAY_GIT_COMMIT_SHA`), which Railway injects on its own.
- Update `SETUP.md` and `.env.example`.

**Done when:** tests and typecheck pass, and throwing from a route locally with
a real DSN shows up in Sentry.

## Session 4: iOS release readiness and crash reporting

**Release configuration**
- Add `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO` to both app build
  configurations. The app only uses HTTPS, which is exempt, and this skips the
  export compliance question on every upload.
- Set `TARGETED_DEVICE_FAMILY = 1` (iPhone only). The app has never been laid
  out for iPad, and iPad support means iPad screenshots and iPad review later.
  iPad owners can still run it in iPhone mode.
- Do a clean Release build (`-configuration Release`), fix any warnings, and
  confirm `TestUsersView` and `DebugVisitMenu` aren't compiled in.
- Check for Required Reason API use (`UserDefaults`, file timestamps, system
  uptime and so on). Nothing in the app uses them today, so no
  `PrivacyInfo.xcprivacy` is needed yet. If the first upload's email mentions
  ITMS-91053, add one.

**Sentry**
- Add `sentry-cocoa` with Swift Package Manager. Start it in `AppDelegate.init`
  so crashes during background visit relaunches are caught too, which a
  SwiftUI `.task` would miss. Keep it off in `DEBUG` and when running tests.
- Put the DSN in a build setting exposed through Info.plist; a DSN isn't
  secret. Set `sendDefaultPii = false`, and add a `beforeSend` or breadcrumb
  filter that strips URL query strings, because `/places?lat=…&lng=…` holds
  the user's coordinates.
- Capture non-fatal errors in `APIClient`: decoding failures and unexpected
  5xx responses. Leave out expected cases like 401 → refresh, cancellation,
  and offline.
- Capture `VisitProcessor` failures that currently only go to `os.Logger`.
- Upload dSYMs. The target has `ENABLE_USER_SCRIPT_SANDBOXING = YES`, so a
  `sentry-cli` Run Script phase has to declare its inputs or be exempted. If
  that's fiddly, document a one-line `sentry-cli debug-files upload` to run
  after archiving instead.
- Set the Sentry user to the userId only; no name or email.

**Done when:** the Debug and Release clean builds are warning-free, tests pass,
and a test crash from a Release build on a device shows up symbolicated in
Sentry.

---

## Manual: production backend

**Railway**
- [ ] Variables: confirm `ENABLE_TEST_USERS` is unset or `false`, and that
      `APPLE_BUNDLE_IDENTIFIER=samgro.Hackysack`. Add `SENTRY_DSN` (the
      `hackysack-api` DSN).
- [ ] Settings → Deploy → **Healthcheck Path** = `/health` (after Session 3),
      so a bad deploy never replaces a good one.
- [ ] Settings → Deploy → restart policy **On Failure**.
- [ ] Make sure the service doesn't sleep when idle (Serverless / App Sleeping
      off), so a friend's first checkin of the day doesn't hit a cold start.
- [ ] Deploy the Session 1–3 changes.

**Neon**
- [ ] Run `npm run db:migrate` against production and confirm every migration
      through `0005` is applied (`select * from drizzle.__drizzle_migrations`).
- [ ] Check there are no test users in production:
      `select id, name from users where is_test_user;`. Delete any that show up.
- [ ] Check your plan's point-in-time restore window (Project → Settings →
      Storage / History retention), and create a branch named
      `pre-testflight` as a snapshot before inviting anyone.
- [ ] Save these queries in the SQL Editor to use as your analytics:
      ```sql
      -- Signups
      select date_trunc('day', created_at) as day, count(*) from users
      where not is_test_user group by 1 order by 1 desc;

      -- Weekly active users (a refresh rotation roughly means an app open)
      select count(distinct user_id) from sessions
      where coalesce(rotated_at, created_at) > now() - interval '7 days';

      -- Checkins per day, by source
      select date_trunc('day', created_at) as day, source, count(*) from checkins
      group by 1, 2 order by 1 desc;
      ```

**Google Cloud (Places API)**
- [ ] Billing → Budgets & alerts: add a budget (e.g. $25/month) with email
      alerts at 50%, 90% and 100%.
- [ ] APIs & Services → Places API (New) → Quotas: cap requests per day at a
      level that's generous for a dozen people but bounds the worst case (a few
      thousand a day). That caps the damage if someone finds the open `/places`
      endpoint.
- [ ] Confirm the key is restricted to Places API (New).

**Uptime (optional, 5 min)**
- [ ] Create a free Better Stack or UptimeRobot monitor on
      `https://digisquare-api-production.up.railway.app/health` with email
      alerts.

**Sentry**
- [ ] In each project, turn on alerts for new issues and regressions (on by
      default for new projects, but check), sent to your email or phone.

## Manual: Apple Developer and App Store Connect

**App icon (blocker)**
- [ ] Make a 1024×1024 PNG with no transparency and drop it into
      `Assets.xcassets/AppIcon` (Any appearance). Dark and tinted variants
      are optional. The upload fails without it.

**Developer portal**
- [ ] Certificates, IDs & Profiles → Identifiers → `samgro.Hackysack`:
      confirm **Sign in with Apple** is enabled. It should be, since sign in
      works on device.

**App Store Connect**
- [ ] Apps → **+** → New App: platform iOS, the name you chose, primary
      language, bundle ID `samgro.Hackysack`, any SKU (e.g. `hackysack`).
- [ ] In Xcode: pick the **Any iOS Device** destination → Product →
      **Archive** → Distribute App → **App Store Connect** → Upload. Let Xcode
      manage the build number, which has to go up with every upload.
- [ ] Wait for processing (usually 5–30 min) and the "ready to test" email.

**TestFlight → Test Information** (needed for external testers)
- [ ] Beta App Description: one paragraph on what the app does.
- [ ] Feedback Email.
- [ ] Privacy Policy URL: the `PRIVACY.md` link from Session 2.
- [ ] Beta App Review Information: contact name, email and phone. Check
      **Sign-in required** and, in the notes, explain that sign in is Sign in
      with Apple only, so reviewers can use any Apple ID. Also explain why the
      app asks for Always location: visits drive the checkin suggestions, and
      nothing is shared until the user accepts. You don't need a demo account.

**Testers**
- [ ] Use an **External Testing** group, not Internal. Internal testers have
      to be App Store Connect users on your team, which means giving friends
      access to your developer account. External testers only need an email
      address or a public link.
- [ ] Create a group (e.g. "Friends"), add the build, and submit it for
      **Beta App Review**. The first build of each version is usually
      reviewed within a day, and later builds of the same version often
      skip review.
- [ ] After approval, add testers by email, or turn on a public link with a
      tester limit (e.g. 20).
- [ ] Fill in **What to Test** for each build.

**Apple constraints to keep in mind**
- The deployment target is **iOS 26.4**, so testers need iOS 26.4 or later.
  Check before inviting anyone.
- TestFlight builds **expire after 90 days**, so upload a fresh build at least
  that often.
- Testers may stay on older builds. Keep API changes backwards compatible
  (add fields, don't rename or remove them) until everyone's on the new build.
- Builds have to be made with the current required Xcode/SDK. Update Xcode
  when App Store Connect warns you.

## Manual: launch day

- [ ] Install the TestFlight build on your own phone and do a smoke test
      against production: sign in, check in manually, accept a suggested
      visit, edit and delete a checkin, send and accept a friend request (from
      a second Apple ID or a friend), upload an avatar, sign out and back in.
- [ ] Force a test error in production and check it reaches Sentry.
- [ ] Send testers a short note:
  - Install TestFlight, then accept the invite.
  - Sign in with Apple, then set your name so friends can find you in search.
  - Grant **Always** location if you want visit suggestions. **While Using**
    still lets you check in by hand.
  - To send feedback, take a screenshot and tap **Share Beta Feedback**, or
    open TestFlight → Hackysack → Send Beta Feedback.
  - There are no push notifications yet. Open the app to see friend requests
    and your friends' checkins.

---

## Deferred (not before this launch)

These are left out on purpose. Each is either handled by hand for now or only
matters for a public release.

| Item | Why it can wait | Workaround until then |
| --- | --- | --- |
| Push notifications (friend requests, friend checkins) | Biggest missing feature, but it's a whole APNs + server project. Get feedback first. | The Profile tab badge shows pending requests while the app is open |
| Report and block users (guideline 1.2) | Required for the App Store with user-generated content, not for a friends-only beta | Unfriend; you delete rows in Neon if needed |
| Revoking the Sign in with Apple token on account deletion | Needed for App Store review, and requires a Sign in with Apple key and client secret | Rows are deleted; the Apple link goes stale on its own |
| Require auth and a per-user rate limit on `/places` | The Google quota cap bounds the cost, and the code deliberately leaves it open so checkins work mid-refresh | Quota cap and budget alert |
| Custom API domain (e.g. `api.hackysack.app`) | Nice to have so you can move hosts without shipping a build. With a 90-day build lifetime, switching later is fine. | Railway URL |
| App Privacy "nutrition label", screenshots, App Store listing | Only needed for App Store submission | — |
| Third-party product analytics | Overkill for a dozen testers | Saved Neon queries and TestFlight metrics |
| Forced minimum-version check | TestFlight prompts testers to update | Keep the API backwards compatible |
| Pagination on the timeline and friends feed beyond the current limits | Won't matter at this scale for a while | — |
