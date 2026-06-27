# Diogramos

A collaborative diagram & canvas editor. Draw shapes and connectors on a
canvas, hand out edit access by link, or drop a read-only embed into another
site. Phoenix LiveView on top of PostgreSQL, with live multi-user editing.

## Features

- **Canvas editor** — shapes and connectors with anchor-aware routing,
  edited live at `/c/:slug` (Phoenix LiveView). Open boards from
  `/canvases`.
- **Metadata links** — attach external (`https://…`) or canvas-to-canvas
  links to an element; they render as side-by-side icons on the shape.
- **Folders & organization** — group canvases into folders.
- **Sharing & permissions** — role-based grants per folder/canvas, plus
  one-off share links (`/s/:token`).
- **Embeds** — publish a canvas read-only via `/embed/:token` (and the
  `/c-embed/:slug` redirect for in-canvas links).
- **JSON export** — `/c/:slug/export.json` for any canvas you can see.
- **Accounts** — magic-link login by default, password optional, with
  invite-gated registration (`/users/invites`).
- **Themes** — pick a daisyUI theme; the choice persists.

## Quick start

```sh
# 1. Bring up Postgres (see compose.yml)
podman compose up -d   # or: docker compose up -d

# 2. Install deps, create + migrate the dev DB, build assets
mix setup

# 3. Start the dev server
mix phx.server
```

Then open <http://localhost:4000>. Registration is invite-only by default —
mint a link from `/users/invites`, or seed an initial confirmed user:

```sh
mix run -e 'Diogramos.Release.init("you@example.com", "a strong password")'
```

## Container images

CI publishes a multi-registry image on every push to `master`:

- `ghcr.io/neiam/diogramos`
- `docker.io/neiam/diogramos`
- `quay.io/neiam/diogramos`

Tags: `latest` (default branch), `vX.Y.Z` + `X.Y` (git tags), the branch name,
and the commit SHA.

```sh
docker pull ghcr.io/neiam/diogramos:latest

docker run --rm -p 4000:4000 \
  -e PHX_SERVER=true \
  -e SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  -e PHX_HOST=localhost \
  -e POSTGRES_HOST=host.containers.internal \
  -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=diogramos \
  ghcr.io/neiam/diogramos:latest
```

Or set `DATABASE_URL=ecto://user:pass@host/db` instead of the discrete
`POSTGRES_*` variables.

## Tests

```sh
mix test
mix precommit   # compile --warnings-as-errors, deps.unlock --unused, format, test
```

`mix precommit` is what CI runs and what every change should pass.
