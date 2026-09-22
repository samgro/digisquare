# Setup Guide

Manual, step-by-step setup for hosting this API on Railway with a Neon Postgres database and the Google Places API.

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

> **Before applying `0002_checkins_user_id_foreign_key` to a database with real
> data, create a Neon branch.** That migration begins with `DELETE FROM
> checkins` and cannot be undone. It is needed because `checkins.user_id` used
> to be a free-form string the client supplied, so the old rows cannot be
> attributed to any real account. Neon branches are copy-on-write and instant:
> open the project's **Branches** tab and click **New Branch** from `main`.

## 2. Google Places API

1. Go to https://console.cloud.google.com and create a new project (or select an existing one).
2. In the left sidebar, go to **APIs & Services > Library**.
3. Search for **"Places API (New)"** and click **Enable**.
4. Google Places requires billing to be enabled on the project:
   - Go to **Billing** in the sidebar and link a billing account (Google provides a recurring free monthly credit for Places API usage).
5. Create an API key:
   - Go to **APIs & Services > Credentials**.
   - Click **Create Credentials > API key**.
   - Copy the generated key.
6. Restrict the key (recommended):
   - Click into the new key's settings.
   - Under **API restrictions**, select **Restrict key** and choose **Places API (New)**.
   - Under **Application restrictions**, restrict by IP address (Railway's outbound IP, if static) or leave unrestricted for initial testing, then tighten later.
7. Save this as `GOOGLE_PLACES_API_KEY`.

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
   - `GOOGLE_PLACES_API_KEY` — the key from step 2.
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
2. Fill in `.env`. `DATABASE_URL`, `GOOGLE_PLACES_API_KEY`, `AUTH_JWT_SECRET`
   and the five `R2_*` values are all required — the server exits at startup
   and names anything missing.
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
5. Exercise the endpoints:
   ```bash
   # Nearby places, ranked by popularity
   curl "http://localhost:3000/places?lat=37.7749&lng=-122.4194"

   # Text search near a location, ranked by relevance
   curl "http://localhost:3000/places?lat=37.7749&lng=-122.4194&q=coffee"

   # Optional radius override (meters, default 1500, max 50000)
   curl "http://localhost:3000/places?lat=37.7749&lng=-122.4194&radius=500"
   ```

   `/places` is open, but `/checkins` and `/users` need a bearer token. Create
   an account and use the token it returns:
   ```bash
   curl -X POST http://localhost:3000/auth/register \
     -H "Content-Type: application/json" \
     -d '{"email":"you@example.com","password":"a-long-enough-password","name":"You"}'

   curl http://localhost:3000/users/me -H "Authorization: Bearer <accessToken>"
   ```
   The Bruno collection in `bruno/` captures the token automatically and covers
   the error cases too.
