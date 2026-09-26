# Setup Guide

Manual, step-by-step setup for hosting this API on Railway with a Neon Postgres database and place data from Overture Maps.

## 1. Neon (Postgres database)

1. Go to https://console.neon.tech and sign in (or create an account).
2. Click **New Project**. Pick a name (e.g. `hackysack-api`) and a region close to where you'll deploy on Railway.
3. Once created, go to the project's **Dashboard** and find the **Connection String** panel.
4. Select the **Pooled connection** variant (recommended for serverless/Node environments) and copy the full connection string. It looks like:
   ```
   postgres://user:password@ep-xxxx-pooler.region.aws.neon.tech/neondb?sslmode=require
   ```
5. Save this as `DATABASE_URL` — you'll set it locally and in Railway below.

Apply the migrations before starting the API:
```bash
npm run db:generate   # regenerates SQL from src/db/schema.ts after a schema change
npm run db:migrate    # applies any pending migrations to DATABASE_URL
```

Migrations are applied manually — they do not run at boot or as part of the
Railway build, so a deploy that needs a new table needs `db:migrate` first.

> **Before applying `0004_remove_passwords_add_test_users`, create a Neon
> branch too.** It deletes every account without an Apple ID, along with their
> checkins and friendships, because email/password sign in no longer exists
> and those accounts have no way left to sign in.

> **Before applying `0002_checkins_user_id_foreign_key` to a database with real
> data, create a Neon branch.** That migration begins with `DELETE FROM
> checkins` and cannot be undone. It is needed because `checkins.user_id` used
> to be a free-form string the client supplied, so the old rows cannot be
> attributed to any real account. Neon branches are copy-on-write and instant:
> open the project's **Branches** tab and click **New Branch** from `main`.

## 2. Overture Maps (place data)

Places come from the [Overture Maps Foundation](https://overturemaps.org)
places dataset, an open, monthly-updated set of about 50 million points of
interest, loaded into the `places` table of your own database. There is no
API key and nothing is billed per request. The API fetches the data itself,
straight from Overture's public release files on S3, using DuckDB inside the
API process; you never download anything by hand unless you want to.

Venue grounds come with it: the polygons of airports, parks, campuses,
stadium grounds and the like from Overture's base theme are attached to the
matching places, so the app knows you are inside SFO from a gate 1.4 km from
its pin. Users can also add venues from the app, which land in the same table
with `source = 'user'` and are private (visible only to the creator and their
friends) unless they say otherwise.

### 2a. Pick a release

1. Releases are named by date. List them with the AWS CLI (no account needed)
   or just open the bucket listing in a browser:
   ```bash
   aws s3 ls --no-sign-request s3://overturemaps-us-west-2/release/
   ```
2. Save the latest as `OVERTURE_RELEASE`, for example `2026-09-23.0`. Bumping
   it later is how you refresh: the API rolls every loaded area to the new
   release in the background (see 2d).

### 2b. Seed the Bay Area and New York

The database needs PostGIS, which migration `0009` enables (Neon ships it).
Apply the migrations (step 1), then load the two launch regions once from a
machine with `DATABASE_URL` and `OVERTURE_RELEASE` set:
```bash
npm run coverage:seed -- bay-area new-york
```
Each region is fetched in 1 degree tiles straight from S3; a stopped run
resumes where it left off, since tiles already loaded are skipped. Expect on
the order of 0.5 M places for the Bay Area and 1.2 M for New York, and tens of
minutes per region. Regions are bounding boxes in `scripts/seed-regions.ts`;
add one there to seed another metro.

To check a change in the app without waiting on a whole region, seed just
downtown San Francisco (the four cells a search from SoMa checks), which
takes a minute or two:
```bash
npm run coverage:seed -- --soma
npm run coverage:seed -- --sfo     # the airport, for checking how grounds rank
```

### 2c. Everywhere else: fetched on demand

When a signed-in user searches from an area with no data, the API enqueues a
fetch of the 0.1 degree cells around them (about 10 km squares) and tells the
app how long it should take; the app asks them to try again in a few minutes.
Once those cells are in, the API grows the fetch to the whole city (found from
Overture's division boundaries; capped at 60 cells) in the background. Limits
keep this from being abused: 4 area requests per user per day, at most 10
waiting at once, and at most 300 cells a day across all users. Anonymous
callers never trigger a fetch.

The worker runs inside the API process, one fetch at a time, so nothing else
needs deploying. Failed fetches are retried three times; `npm run
coverage:retry` puts anything that gave up back in the queue.

### 2d. Keeping it fresh

Overture releases monthly. Set `OVERTURE_RELEASE` to the new release and
redeploy: the worker finds every loaded cell recorded under an older release
and re-fetches it, lowest priority, so a user waiting on a new area always
goes first. Rows are upserted on Overture's stable ids, so checkins keep
pointing at the same places; rows the new release dropped (closed venues) are
retired rather than deleted, hidden from search but still shown on old
checkins. User-created venues are never touched. To do it right away instead
of in the background, run `npm run coverage:refresh`.

### 2e. Loading from files instead

The official CLI works too, for an area you already downloaded:
```bash
pip install overturemaps
overturemaps download --bbox=-122.55,37.70,-122.35,37.85 -f geojsonseq --type=place -o sf-places.geojsonseq
overturemaps download --bbox=-122.55,37.70,-122.35,37.85 -f geojsonseq --type=land_use -o sf-land-use.geojsonseq
overturemaps download --bbox=-122.55,37.70,-122.35,37.85 -f geojsonseq --type=infrastructure -o sf-infrastructure.geojsonseq
npm run overture:import -- sf-places.geojsonseq
npm run overture:import-extents -- sf-land-use.geojsonseq sf-infrastructure.geojsonseq
```
The cells a file covers are marked loaded, so the API never fetches them
again.

Migration `0008_add_places` also carries over any checkins made while the
app used Google Places: each distinct Google place becomes a `places` row
with `source = 'google'`, so old timelines and history-based ranking keep
working. The Google API key is no longer needed anywhere.

## 3. Cloudflare R2 (avatar storage)

Avatars are uploaded straight from the app to R2 using a short-lived presigned
URL, so image bytes never pass through the API.

1. Go to https://dash.cloudflare.com and pick (or create) an account.
2. In the sidebar, open **R2 Object Storage** and click **Create bucket**. Name
   it `hackysack-avatars` and pick a location hint near your users.
3. Copy your **Account ID** from the R2 overview page — save it as
   `R2_ACCOUNT_ID`.
4. Still under R2, open **Manage R2 API Tokens > Create API token**:
   - Permission: **Object Read & Write**.
   - Scope it to the `hackysack-avatars` bucket rather than all buckets.
   - Create it, then copy the **Access Key ID** and **Secret Access Key** —
     save them as `R2_ACCESS_KEY_ID` and `R2_SECRET_ACCESS_KEY`. The secret is
     shown once.
5. Make the bucket readable, since avatar URLs are fetched directly by the app.
   In the bucket's **Settings**, either connect a **Custom Domain** (e.g.
   `avatars.hackysack.app`) or enable the **r2.dev** subdomain for development.
   Save whichever URL you get as `R2_PUBLIC_BASE_URL`, with no trailing slash.
6. Save the bucket name as `R2_BUCKET_NAME`.

No CORS configuration is needed: uploads come from a native app, not a browser.

To check the setup end to end, get a presigned URL from the API and use it:
```bash
curl -X PUT --data-binary @avatar.jpg -H "Content-Type: image/jpeg" "<uploadUrl>"
```
A `403 SignatureDoesNotMatch` almost always means the `Content-Type` header
does not match what was signed byte for byte, the body length differs from the
declared `contentLength`, or an `Authorization` header was sent alongside the
query-string credentials.

## 4. Railway (hosting)

1. Go to https://railway.app and sign in.
2. Click **New Project > Deploy from GitHub repo**, and select this repository (push it to GitHub first if you haven't).
   - Alternatively, install the Railway CLI (`npm i -g @railway/cli`), run `railway login`, then `railway init` and `railway up` from this project's root.
3. Once the project is created, open the service and go to the **Variables** tab. Add:
   - `DATABASE_URL` — the Neon pooled connection string from step 1.
   - `OVERTURE_RELEASE` — the release from step 2a.
   - `AUTH_JWT_SECRET` — generate one with `openssl rand -base64 48`. Changing
     it later signs every user out, since it invalidates all existing access
     tokens.
   - `APPLE_BUNDLE_IDENTIFIER` — `samgro.Hackysack`. Apple identity tokens are
     checked against this, so a mismatch rejects every sign-in.
   - The five `R2_*` variables from step 3 below.
   - Railway automatically injects `PORT`; you don't need to set it manually, but the app will fall back to `3000` if it's missing.

   **Set these before deploying.** The app validates its whole environment at
   startup and exits immediately if anything is missing, naming the fields —
   it will not boot into a half-configured state.
4. Go to the **Settings** tab and confirm/set:
   - **Build Command**: `npm run build`
   - **Start Command**: `npm start`
5. Deploy. Railway will build and start the service; check the **Deployments** tab for logs.
6. Once live, Railway gives you a public URL (or you can add a custom domain under **Settings > Networking**). Test it:
   ```bash
   curl "https://<your-railway-domain>/places?lat=37.7749&lng=-122.4194"
   ```

## 5. Local development

1. Copy the example env file:
   ```bash
   cp .env.example .env
   ```
2. Fill in `.env`. `DATABASE_URL`, `OVERTURE_RELEASE`, `AUTH_JWT_SECRET` and
   the five `R2_*` values are all required — the server exits at startup and
   names anything missing. A local Postgres needs the PostGIS extension
   installed (`postgresql-16-postgis-3` on Debian and Ubuntu, `postgis` on
   Homebrew); the migration enables it.

   To work against a Neon branch instead, put its `DATABASE_URL` (and
   anything else that differs) in `.env.branch` at the repo root. It is
   gitignored and overrides both `.env` and the shell, for the server, the
   scripts and `db:migrate` alike.

   `npm run dev` takes the first free port from 3000 up, and logs which, so
   several checkouts (git worktrees) can run at once; the simulator app
   probes ports 3000-3009 and uses the server on its own branch. Set `PORT`
   to pin a port. Those checkouts also share the token secret, so the app
   could not otherwise tell them apart. A
   Debug simulator build is therefore stamped with the branch and commit it
   was built from and sends them on every request; a dev server on another
   branch answers 409 and the app shows a full-screen "Wrong Dev Server"
   notice naming both builds until you start the matching server (or
   rebuild the app). A server from before this check, which names no build
   at all, is refused the same way. Same branch but a newer commit only
   shows a banner.
3. Install dependencies and run the dev server:
   ```bash
   npm install
   npm run dev
   ```
4. Run the test suite:
   ```bash
   npm test          # vitest, stubs fetch and never touches the database
   npm run typecheck # tsc over src and test
   ```
   The tests supply their own environment through `test/setup-env.ts`, so they
   run without a `.env`. Note the endpoints that need a database are covered
   against a stub — verifying the SQL still means pointing `DATABASE_URL` at a
   real Postgres and running the Bruno collection.
5. Search from wherever you are: signed in, the API fetches the area for you
   the first time (step 2c), or seed a region (step 2b). Then exercise the
   endpoints:
   ```bash
   # Nearby places: the 20 nearest, venues whose grounds you are in, then
   # large venues within 2 km. `coverage` says whether the area is loaded.
   curl "http://localhost:3000/places?lat=37.7749&lng=-122.4194&accuracy=25"

   # Name search near a location
   curl "http://localhost:3000/places?lat=37.7749&lng=-122.4194&q=coffee"

   # Optional radius override (meters, default 1500, max 50000)
   curl "http://localhost:3000/places?lat=37.7749&lng=-122.4194&radius=500"

   # One place, with how many checkins it has
   curl "http://localhost:3000/places/<placeId>"
   ```

   Searching `/places` is open, but creating a venue there, and everything
   under `/checkins` and `/users`, needs a bearer token. The only real sign in
   is Apple, which needs a device, so locally sign in as a test user instead.
   Set `ENABLE_TEST_USERS=true` in `.env`, seed the test users (Alice, Bob,
   Catherine and David, each with checkins at real chain locations in their
   home city, and all friends with each other), then use the token it returns:
   ```bash
   npm run db:seed-test-users

   curl -X POST http://localhost:3000/auth/test-users/7e570000-0000-4000-8000-000000000001/session

   curl http://localhost:3000/users/me -H "Authorization: Bearer <accessToken>"

   # Add a venue by hand (private unless "isPrivate": false), then check in there
   curl -X POST http://localhost:3000/places \
     -H "Authorization: Bearer <accessToken>" -H "Content-Type: application/json" \
     -d '{"name":"My Garage","primaryType":"bar","latitude":37.7751,"longitude":-122.4189}'

   curl -X POST http://localhost:3000/checkins \
     -H "Authorization: Bearer <accessToken>" -H "Content-Type: application/json" \
     -d '{"placeId":"<id from the response above>","message":"Band practice"}'
   ```
   The seed fetches the test users' home cities from Overture if they are not
   loaded yet (so it needs `OVERTURE_RELEASE`, step 2a), then checks them in
   at branches from the `places` table. It can be rerun at any time, and
   replaces the test users' checkins and friendships with each other each run. Leave `ENABLE_TEST_USERS` off anywhere real
   people have accounts: the `/auth/test-users` routes sign in with no
   credential.
   The Bruno collection in `bruno/` captures the token and the venue id
   automatically and covers the error cases too.
