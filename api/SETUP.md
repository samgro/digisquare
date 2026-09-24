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
API key and nothing is billed per request; you import the areas your users
are in and refresh them when a new release lands. Users can also add venues
from the app, which land in the same table with `source = 'user'`.

1. Install the official download CLI (needs Python 3.9+):
   ```bash
   pip install overturemaps
   ```
2. Download the places for an area as newline-delimited GeoJSON. The bounding
   box is `west,south,east,north`; this one covers San Francisco:
   ```bash
   overturemaps download --bbox=-122.55,37.70,-122.35,37.85 \
     -f geojsonseq --type=place -o sf-places.geojsonseq
   ```
   A city is tens of thousands of places and downloads in a minute or two.
   Larger areas work the same way, just slower; import each metro your users
   are in rather than a whole country.
3. Apply the migrations (step 1) and import the file:
   ```bash
   npm run overture:import -- sf-places.geojsonseq
   ```
   Rows are upserted on Overture's stable GERS id, so re-running with a newer
   release updates places in place, never duplicates them, and checkins keep
   pointing at the same rows. Permanently closed places are skipped. Repeat
   for every area, then again whenever you want a fresher release.
4. Check it worked:
   ```bash
   curl "https://<your-api>/places?lat=37.7749&lng=-122.4194&q=coffee"
   ```

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
2. Fill in `.env`. `DATABASE_URL`, `AUTH_JWT_SECRET` and the five `R2_*`
   values are all required — the server exits at startup and names anything
   missing.
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
5. Import some places (step 2) for wherever you will be testing from, then
   exercise the endpoints:
   ```bash
   # Nearby places: the 20 nearest, then large venues within 2 km
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

   # Add a venue by hand, then check in there
   curl -X POST http://localhost:3000/places \
     -H "Authorization: Bearer <accessToken>" -H "Content-Type: application/json" \
     -d '{"name":"My Garage","primaryType":"bar","latitude":37.7751,"longitude":-122.4189}'

   curl -X POST http://localhost:3000/checkins \
     -H "Authorization: Bearer <accessToken>" -H "Content-Type: application/json" \
     -d '{"placeId":"<id from the response above>","message":"Band practice"}'
   ```
   The seed checks the test users in at branches already in the `places`
   table, so import Overture for their home cities first (step 2). It can be
   rerun at any time, and replaces the test users' checkins and friendships
   with each other each run. Leave `ENABLE_TEST_USERS` off anywhere real
   people have accounts: the `/auth/test-users` routes sign in with no
   credential.
   The Bruno collection in `bruno/` captures the token and the venue id
   automatically and covers the error cases too.
