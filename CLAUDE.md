Digisquare is a simple open source app for checking into places and sharing with
your friends. It is hosted on Railway/Neon and uses Google Places API for data.

# Code conventions

Never use single letter variables or abbrevations in code. For example, use
`latitude` instead of `lat` or `query` instead of `q`. These abbreviations are
acceptable only for these extremely common variables in the API params - i.e.
`/places?q=foo` is acceptable.

# Repo structure

This is a monorepo. `api` has the Hono api, and the ios app lives in `ios`.
