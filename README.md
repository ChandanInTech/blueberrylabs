# Blueberry — AI-Powered Social Media Image Resizer

Crop and resize any image to the exact dimensions Instagram, TikTok and YouTube expect.
Upload from the browser, choose a preset, and the server produces a pixel-perfect result.

[![CI](https://github.com/ChandanInTech/blueberrylabs/actions/workflows/ci.yml/badge.svg)](https://github.com/ChandanInTech/blueberrylabs/actions/workflows/ci.yml)

- **Status:** MVP, demo authentication only
- **Live app:** <https://blueberrylabs-frontend.vercel.app>
- **Live API:** <https://blueberrylabs-backend-production.up.railway.app> (Railway, PostgreSQL + private buckets)
- **Full design:** [ARCHITECTURE.md](./ARCHITECTURE.md)
- **Agent guidance:** [AGENTS.md](./AGENTS.md)

## Repository topology

This is **not** a monorepo. It is a parent repository holding two independent git
repositories as submodules:

```
blueberrylabs/            # parent — orchestration and docs only
├── backend/              # git submodule → Bun + Elysia API, queue, Sharp worker
├── frontend/             # git submodule → Next.js app (Vercel)
├── docker-compose.yml    # local PostgreSQL only
├── package.json          # delegating scripts, no application dependencies
└── scripts/
    └── sync-contracts.sh # packs backend/contracts → frontend/vendor
```

Shared TypeScript contracts are **not** shared through a workspace. `backend/contracts`
is packed into a versioned tarball and installed into `frontend/`, so the two
submodules stay decoupled while agreeing on one source of truth.

## Quick start

```bash
git clone --recurse-submodules <parent-repo-url>
cd blueberrylabs

cp backend/.env.example backend/.env        # set DATABASE_URL + DEMO_SESSION_SECRET
cp frontend/.env.example frontend/.env.local

npm run db:up                               # or: docker compose up -d postgres
bun --cwd backend install
bun --cwd frontend install

npm run migrate
npm run dev
```

Open <http://localhost:3000> and choose **Continue with demo account**.

### Running without Docker

The backend can use any reachable PostgreSQL. For a throwaway local cluster:

```bash
initdb -D /tmp/blueberry-pg/data -U app --auth=trust
pg_ctl -D /tmp/blueberry-pg/data -o "-p 55432" -l /tmp/blueberry-pg/log.txt start
createdb -h localhost -p 55432 -U app social_resizer
```

Then set `DATABASE_URL=postgresql://app@localhost:55432/social_resizer`.

### Without Railway Bucket credentials

Set `STORAGE_DRIVER=filesystem`. The API then serves presigned-style URLs from
`/__storage/...` itself, so the browser upload path (XHR PUT with progress) is
identical to production. Switch to `STORAGE_DRIVER=s3` and fill the
`RAILWAY_BUCKET_*` variables to use real buckets.

## Commands

| Command | What it does |
| --- | --- |
| `npm run dev` | Starts the API (3001) and the Next.js app (3000) |
| `npm run migrate` | Applies Drizzle SQL migrations |
| `npm run test` | Backend then frontend test suites |
| `npm run lint` | Biome in both submodules |
| `npm run typecheck` | `tsc --noEmit` in both submodules |
| `npm run build` | Production Next.js build |
| `npm run contracts:sync` | Re-packs `backend/contracts` into `frontend/vendor` |
| `npm run verify` | lint + typecheck + test |

Integration tests start their own PostgreSQL if `TEST_ADMIN_DATABASE_URL` is unset and
`initdb`/`pg_ctl` are on `PATH`. Each run creates and drops a
`social_resizer_test_<pid>` database; no developer database is touched.

## Supported presets

| Platform | Format | Output | Ratio |
| --- | --- | --- | --- |
| Instagram | Square post | 1080 × 1080 | 1:1 |
| Instagram | Portrait post | 1080 × 1350 | 4:5 |
| Instagram | Story | 1080 × 1920 | 9:16 |
| TikTok | Cover | 1080 × 1920 | 9:16 |
| YouTube | Thumbnail | 1280 × 720 | 16:9 |

Presets live in `backend/contracts/src/presets.ts`. The backend validates every
selection; the frontend only renders the list.

## API

Base path `/api/v1`. Interactive docs at `/api/docs`.

```
POST /auth/demo                      create demo session
GET  /auth/session                   current session
POST /auth/logout                    revoke session

POST /uploads                        create asset + presigned PUT URL
POST /uploads/:assetId/complete      verify object and finalize
GET  /assets/:assetId                asset metadata
GET  /assets/:assetId/download-url   short-lived signed URL

POST /generations                    create generation + enqueue job (202)
GET  /generations/:id                status + output metadata
GET  /generations                    cursor-paginated history
POST /generations/:id/download-url   short-lived signed output URL

GET  /health/live                    liveness
GET  /health/ready                   readiness (config + database)
GET  /metrics                        Prometheus exposition
```

Errors always use one shape:

```json
{ "error": { "code": "RATE_LIMIT_EXCEEDED", "message": "…", "requestId": "…", "retryAfterSeconds": 30 } }
```

## Security model (MVP)

- Demo-only server-issued sessions. HttpOnly, `SameSite=Lax`, `Secure` in production.
- The server derives `userId` from the session row — never from the client.
- Every asset and generation read is ownership-scoped; another user's id returns 404.
- CSRF protection: `Origin` allow-list on all unsafe methods plus a double-submit CSRF
  token that must arrive in the `X-CSRF-Token` header.
- Bucket credentials are server-side only; the browser only ever sees short-lived
  signed URLs.
- Rate limits (per user *and* per IP) and daily/concurrency quotas are enforced with
  atomic PostgreSQL operations.
- Files are validated by extension *and* MIME type before signing, re-verified by
  `HEAD` after upload, and decoded by Sharp with a pixel cap before processing.

### Demo limitations — read before deploying publicly

- There is no signup, password, or OAuth. Each demo login creates a fresh principal.
- Anyone with the URL can mint a session. This is **not** multi-tenant identity.
- Before real use, replace demo auth with an identity provider and keep the same
  `userId` ownership model.

## Deployment

**Backend → Railway.** Build from the `backend/` repository using its `Dockerfile`.
One service runs Elysia *and* the background job loop. Configure
`DATABASE_URL` from the Railway PostgreSQL service, `RAILWAY_BUCKET_*` from the bucket
connection details, `WEB_ORIGIN` set to the Vercel origin, and health check path
`/health/ready`. Migrations run from `docker-entrypoint.sh`; set `RUN_MIGRATIONS=false`
if you apply them as a separate release step.

**Frontend → Vercel.** Project root is the `frontend/` repository. Set
`NEXT_PUBLIC_API_BASE_URL` to the public Railway URL. Never put bucket credentials in
`NEXT_PUBLIC_*`.

Because `*.vercel.app` and `*.up.railway.app` are different registrable domains, the
browser treats every API call as cross-site. The backend must therefore run with
`COOKIE_SAME_SITE=none` and `COOKIE_SECURE=true`, or the session cookie is never sent
and every authenticated request returns 401. Add the Vercel origin to both buckets'
CORS as well. See ARCHITECTURE.md §27.8.

Configuration is checked in: `backend/railway.json` (Dockerfile builder, `/health/ready`
probe, restart-on-failure) and `frontend/vercel.json` (Next.js preset, Bun build).
`NEXT_PUBLIC_API_BASE_URL` is read from a Vercel environment variable, never committed.

**Railway Buckets.** Create private `media-originals` and `media-generated` buckets.
Note that Railway issues **per-bucket** credentials and uses **virtual-host**
addressing, and that the S3 bucket name is suffixed (e.g.
`media-originals-rhkdzcsji`) — use the `bucketName` from
`railway bucket credentials`, not the dashboard name. CORS is not exposed by the
CLI; apply it with `PutBucketCors` and add your Vercel origin before deploying
the frontend. See ARCHITECTURE.md §27.8.
Enable CORS for the Vercel origin with `PUT`, `GET`, and the `Content-Type` header —
without wildcard origins in production.

## Operational runbook

**Backend restart.** Check `/health/ready`. If a job was left `RUNNING`, the lease
sweeper requeues it once `WORKER_JOB_LEASE_SECONDS` elapses (or fails it when attempts
are exhausted) and reconciles the generation out of `PROCESSING`.

**Queue backlog.** Inspect `SELECT status, count(*) FROM jobs GROUP BY status;` and the
oldest `run_at`. Check `/metrics` (`queue_depth`, `jobs_failed_total`) and worker logs.
Never delete jobs blindly.

**Failed generation.** Search logs by `generationId` and `jobId`. Inspect the sanitized
`error_code` and attempt count. Failed generations are terminal by design; retry by
creating a new generation.

**Upload failures.** Check presigned URL expiry, bucket CORS, and that the client sent
the required `Content-Type`. The API only marks an asset `UPLOADED` after a successful
`HEAD` verification — a browser success alone is not enough.

**Rate-limit false positives.** Inspect the operation, window and reset time from the
`RateLimit-*` headers. Raise one limit rather than disabling limiting wholesale.

**Database migration.** Back up, run `npm run migrate` once, verify `/health/ready`, and
roll forward with a corrective migration where possible.

## Continuous integration

Each repository owns its workflow, per the architecture:

| Repository | Jobs |
| --- | --- |
| parent | submodule integrity, no app source or dependencies in the parent, pinned-commit builds of both sides, contracts tarball drift |
| backend | lint, typecheck, test (real `postgres:16` service), Docker image build |
| frontend | lint, typecheck, test, production `next build` |

Submodules are public, so CI clones them with the default token. If you make them
private again, set a `SUBMODULE_TOKEN` secret on the parent repository with read
access to both.

Reproduce the container build locally:

```bash
cd backend && docker build --no-cache -t blueberrylabs-backend:ci .
```

## Known limitations

- Real Railway Bucket presigned uploads and Vercel→Railway cookies were not exercised
  against live infrastructure in this environment; the S3 adapter follows the
  documented S3 signer behaviour, and the filesystem adapter mirrors the same URL
  contract for local verification.
- OpenTelemetry is a documented partial integration (correlation IDs are mandatory and
  always present; the OTLP exporter is wired only when an endpoint is configured).
- Sentry support is a seam (`SENTRY_DSN`) that must be backed by the SDK before use.
- Metrics are per-process in-memory counters exposed at `/metrics`; a multi-replica
  deployment needs a scraper per replica (e.g. Prometheus with per-pod targets).

## Licence

Assessment project — not licensed for redistribution.
