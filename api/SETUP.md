# Setup Guide

Manual, step-by-step setup for hosting this API on Railway with a Neon Postgres database and the Google Places API.

## 1. Neon (Postgres database)

1. Go to https://console.neon.tech and sign in (or create an account).
2. Click **New Project**. Pick a name (e.g. `digisquare-api`) and a region close to where you'll deploy on Railway.
3. Once created, go to the project's **Dashboard** and find the **Connection String** panel.
4. Select the **Pooled connection** variant (recommended for serverless/Node environments) and copy the full connection string. It looks like:
   ```
   postgres://user:password@ep-xxxx-pooler.region.aws.neon.tech/neondb?sslmode=require
   ```
5. Save this as `DATABASE_URL` — you'll set it locally and in Railway below.

There are no tables yet in this app, so no migration step is required right now. When tables are added later, run:
```bash
npm run db:generate   # generates SQL migration files from src/db/schema.ts
npm run db:migrate    # applies them to DATABASE_URL
```

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

## 3. Railway (hosting)

1. Go to https://railway.app and sign in.
2. Click **New Project > Deploy from GitHub repo**, and select this repository (push it to GitHub first if you haven't).
   - Alternatively, install the Railway CLI (`npm i -g @railway/cli`), run `railway login`, then `railway init` and `railway up` from this project's root.
3. Once the project is created, open the service and go to the **Variables** tab. Add:
   - `DATABASE_URL` — the Neon pooled connection string from step 1.
   - `GOOGLE_PLACES_API_KEY` — the key from step 2.
   - Railway automatically injects `PORT`; you don't need to set it manually, but the app will fall back to `3000` if it's missing.
4. Go to the **Settings** tab and confirm/set:
   - **Build Command**: `npm run build`
   - **Start Command**: `npm start`
5. Deploy. Railway will build and start the service; check the **Deployments** tab for logs.
6. Once live, Railway gives you a public URL (or you can add a custom domain under **Settings > Networking**). Test it:
   ```bash
   curl "https://<your-railway-domain>/places?lat=37.7749&lng=-122.4194"
   ```

## 4. Local development

1. Copy the example env file:
   ```bash
   cp .env.example .env
   ```
2. Fill in `DATABASE_URL` and `GOOGLE_PLACES_API_KEY` in `.env`.
3. Install dependencies and run the dev server:
   ```bash
   npm install
   npm run dev
   ```
4. Test the endpoint:
   ```bash
   # Nearby places, ranked by popularity
   curl "http://localhost:3000/places?lat=37.7749&lng=-122.4194"

   # Text search near a location, ranked by relevance
   curl "http://localhost:3000/places?lat=37.7749&lng=-122.4194&q=coffee"

   # Optional radius override (meters, default 1500, max 50000)
   curl "http://localhost:3000/places?lat=37.7749&lng=-122.4194&radius=500"
   ```
