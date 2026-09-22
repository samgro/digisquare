Hackysack is a simple open source app for checking into places and sharing with
your friends. It is hosted on Railway/Neon and uses Google Places API for data.

# Code conventions

Never use single letter variables or abbrevations in code. For example, use
`latitude` instead of `lat` or `query` instead of `q`. These abbreviations are
acceptable only for these extremely common variables in the API params - i.e.
`/places?q=foo` is acceptable.

# Terminology

"Checkin" is the noun and "check in" is the verb. Never write "check-in".
For example: "Your checkin was saved", "Couldn't Load Checkins", "Tap + to
check in somewhere". This applies to identifiers too: `Checkin`,
`CheckinStore` and `formattedCheckinTime` for the noun, and `CheckInView` for
the screen that performs the action.

# Repo structure

This is a monorepo. `api` has the Hono api, and the ios app lives in `ios`.
