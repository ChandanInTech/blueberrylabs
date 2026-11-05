# AI-Powered Social Media Image Resizer

## Architecture & Agent Implementation Plan

**Document type:** Technical architecture and delivery specification\
**Status:** Approved for MVP implementation\
**Version:** 1.0\
**Primary goal:** Give an autonomous coding agent enough detail to
build, test, and deploy the MVP without making major architectural
decisions independently.

------------------------------------------------------------------------

## 1. Product scope

Build a web application where a user can:

1.  Open the application using demo authentication.
2.  Upload an image.
3.  Choose a social platform and an output format.
4.  Submit a resize/crop job.
5.  See upload progress.
6.  See queued/processing/completed/failed job status.
7.  Preview the processed image.
8.  Download the result.

### 1.1 Supported platforms and image presets

Implement these initial presets as configuration, not scattered
conditionals:

  Platform    Format             Dimensions   Aspect ratio
  ----------- --------------- ------------- --------------
  Instagram   Square post       1080 × 1080            1:1
  Instagram   Portrait post     1080 × 1350            4:5
  Instagram   Story             1080 × 1920           9:16
  TikTok      Cover             1080 × 1920           9:16
  YouTube     Thumbnail          1280 × 720           16:9

These are MVP output presets. Keep them in a typed configuration module
so they can be changed without modifying processing logic.

### 1.2 Explicitly out of scope

Do not implement these in the MVP:

-   Video upload or video processing.
-   AI image generation or generative editing.
-   Caption, hashtag, or copy generation.
-   Social network publishing or account integrations.
-   Payments, subscriptions, or billing.
-   Full user registration, password reset, or OAuth.
-   WebSockets or Server-Sent Events.
-   A separate Railway worker service.
-   Redis, Kafka, Supabase, AWS S3, or Cloudflare R2.
-   Multi-tenant production authentication.

The generation provider is not needed for the resize-only MVP. The
background job performs deterministic image processing with Sharp. Keep
processing behind a service interface so a future AI provider can be
added without redesigning the API.

------------------------------------------------------------------------

## 2. Approved technology decisions

  -----------------------------------------------------------------------
  Area                                Technology
  ----------------------------------- -----------------------------------
  Frontend                            Next.js, React, TypeScript

  Frontend hosting                    Vercel

  Backend/API                         Bun, Elysia, TypeScript

  Backend hosting                     Railway

  Database                            Railway PostgreSQL

  ORM / migrations                    Drizzle ORM + Drizzle Kit

  Job queue                           PostgreSQL-backed application queue

  Job execution                       Background loop in the same
                                      Bun/Elysia process

  Object storage                      Railway Buckets (S3-compatible)

  Image processing                    Sharp

  API style                           REST, versioned under `/api/v1`

  Status updates                      REST polling

  Authentication                      Demo-only server-issued session

  Rate limiting                       Atomic PostgreSQL-backed
                                      fixed-window counters

  Validation                          Elysia TypeBox schemas or a
                                      consistent TypeScript validation
                                      library

  Logging                             Structured JSON logs

  Error tracking                      Sentry or an equivalent provider;
                                      make optional by environment

  Tracing / metrics                   OpenTelemetry-compatible
                                      instrumentation where supported;
                                      structured correlation IDs are
                                      mandatory

  Local development                   Docker Compose for PostgreSQL;
                                      Railway Bucket credentials for a
                                      shared/dev bucket, or a local
                                      S3-compatible test service if
                                      desired

  Repository layout                   Parent repository containing two git
                                      submodules: `blueberrylabs-backend/` and
                                      `blueberrylabs-frontend/`. Each submodule is its
                                      own independent git repository.

  Package management                  Bun workspaces
                                      inside each submodule, never across
                                      submodule boundaries
  -----------------------------------------------------------------------

### 2.1 Runtime boundary

The API and background job runner live in **one Railway service and one
Bun application process**.

-   Elysia serves HTTP requests.
-   A background loop starts during application startup.
-   The loop claims jobs from PostgreSQL and runs them with bounded
    concurrency.
-   Both API and job runner use the same database and application
    service layer.
-   Do not run a second copy of the job loop in local development unless
    intentionally testing multi-instance claiming.
-   The queue must remain safe if Railway later runs more than one
    backend replica.

Do not use Graphile Worker in this design. It is Node-oriented and would
add a runtime boundary that is unnecessary for this MVP. Do not use an
in-memory queue: jobs must survive process restarts and deployments.

### 2.2 Important processing constraint

Image processing is CPU- and memory-intensive compared with ordinary API
work. Use Sharp's asynchronous native processing, cap worker concurrency
initially at **1**, and avoid reading unbounded files into memory.

If processing causes API latency or memory pressure, the first scaling
step is to deploy the same job-runner code as a separate Railway
service. That is a future deployment change, not part of the MVP.

------------------------------------------------------------------------

## 3. High-level architecture

``` text
                         Vercel
                 +---------------------+
                 | Next.js application|
                 |                     |
                 | Upload UI           |
                 | Preset selector     |
                 | Progress + polling  |
                 | Preview + download  |
                 +----------+----------+
                            |
                            | HTTPS REST
                            v
                    Railway backend
              +---------------------------+
              | Bun + Elysia              |
              |                           |
              | Demo session middleware   |
              | Request validation        |
              | Rate limiting             |
              | Upload orchestration      |
              | Generation API            |
              | Status API                |
              | Download URL API          |
              |                           |
              | Background job loop       |
              | Job claiming + retries    |
              | Sharp image processing    |
              +------+-------------+------+
                     |             |
                     |             |
                     v             v
              Railway          Railway
             PostgreSQL        Buckets
             +----------+     +------------+
             | users    |     | originals  |
             | sessions |     | generated  |
             | assets   |     +------------+
             | jobs     |
             | limits   |
             | events   |
             +----------+
```

### 3.1 Responsibilities

**Next.js frontend** - Collect image and preset selection. - Request an
upload session. - Upload bytes directly to Railway Bucket using a
presigned URL. - Report upload progress from the browser. - Notify the
API that upload is complete. - Create a generation. - Poll for
generation status. - Request a signed preview/download URL. - Never
receive Railway Bucket secret credentials.

**Elysia API** - Authenticate demo sessions. - Validate request bodies
and parameters. - Enforce rate limits and quotas. - Create upload
sessions and presigned URLs. - Verify completed uploads against the
object store. - Create generation and queue records transactionally. -
Return status and signed output URLs. - Enforce ownership on every asset
and generation access.

**Background job loop** - Claim queued jobs safely from PostgreSQL. -
Update job and generation state. - Download source image from Railway
Bucket. - Validate and process with Sharp. - Upload output to Railway
Bucket. - Persist output metadata and terminal status. - Retry transient
errors and fail permanent errors. - Recover abandoned jobs after a
process crash.

**Railway PostgreSQL** - Stores application metadata and job state. -
Stores rate-limit counters and quotas. - Is the source of truth for job
status. - Does not store image binaries.

**Railway Buckets** - Store original and generated image files. - Remain
private. - Are accessed by the backend using S3-compatible credentials
and by the browser only through short-lived presigned URLs.

------------------------------------------------------------------------

## 4. Repository structure

### 4.1 Repository topology

This project is **not** a single monorepo. It is a parent repository that
contains two git submodules:

``` text
blueberrylabs/                 # parent repository (this repo)
├── backend/                   # git submodule -> its own repository
├── frontend/                  # git submodule -> its own repository
├── .gitmodules
├── docker-compose.yml
├── package.json               # root convenience scripts only
├── .env.example
├── README.md
└── ARCHITECTURE.md
```

Rules:

-   `backend/` and `frontend/` are **independent git repositories** with
    their own history, branches, tags, CI, and release cadence.
-   The parent repository tracks only a pinned commit for each submodule.
    It must never contain application source code for either side.
-   Never copy files between `backend/` and `frontend/`. Share contracts
    through a published package or generated client, not by copying.
-   Each submodule owns its own lockfile. Do not create a lockfile at the
    parent root that resolves application dependencies.
-   The parent repository owns only cross-cutting assets: the
    architecture document, local orchestration (Docker Compose), and
    convenience scripts that delegate into the submodules.

### 4.2 Parent repository scripts

The parent `package.json` exists only to delegate. It must not declare
application dependencies. Root scripts must delegate rather than
duplicate logic:

``` json
{
  "scripts": {
    "dev": "bun --cwd backend run dev & bun --cwd frontend run dev",
    "test": "bun --cwd backend run test && bun --cwd frontend run test",
    "lint": "bun --cwd backend run lint && bun --cwd frontend run lint",
    "typecheck": "bun --cwd backend run typecheck && bun --cwd frontend run typecheck"
  }
}
```

Use the package manager each submodule actually declares; the snippet
above is illustrative, not prescriptive.

### 4.3 `backend/` submodule layout

``` text
backend/
├── src/
│   ├── app.ts
│   ├── server.ts
│   ├── config/
│   │   ├── env.ts
│   │   └── presets.ts
│   ├── db/
│   │   ├── client.ts
│   │   ├── schema/
│   │   └── migrations/
│   ├── middleware/
│   │   ├── auth.ts
│   │   ├── rate-limit.ts
│   │   ├── request-context.ts
│   │   └── error-handler.ts
│   ├── modules/
│   │   ├── auth/
│   │   ├── uploads/
│   │   ├── assets/
│   │   ├── generations/
│   │   ├── jobs/
│   │   └── health/
│   ├── queue/
│   │   ├── worker.ts
│   │   ├── claim-job.ts
│   │   ├── retry.ts
│   │   └── handlers/
│   │       └── process-image.ts
│   ├── services/
│   │   ├── storage/
│   │   │   ├── storage.interface.ts
│   │   │   └── railway-bucket.ts
│   │   ├── image/
│   │   │   └── sharp-processor.ts
│   │   └── generation/
│   │       └── generation-service.ts
│   ├── observability/
│   │   ├── logger.ts
│   │   ├── metrics.ts
│   │   └── tracing.ts
│   └── utils/
├── drizzle.config.ts
├── package.json
├── Dockerfile
└── README.md
```

### 4.4 `frontend/` submodule layout

``` text
frontend/
├── app/
│   ├── (app)/
│   │   ├── page.tsx
│   │   ├── generations/[id]/page.tsx
│   │   └── history/page.tsx
│   ├── api/                 # Only if a Next.js proxy is genuinely needed
│   ├── login/page.tsx       # Access-code entry point
│   ├── layout.tsx
│   └── globals.css
├── components/
│   ├── upload/
│   ├── presets/
│   ├── generation/
│   └── ui/
├── hooks/
│   ├── use-upload.ts
│   └── use-generation-polling.ts
├── lib/
│   ├── api-client.ts        # token storage + Authorization header
│   ├── auth.ts              # loadSession / login / endSession
│   └── validation.ts
├── package.json
└── README.md
```

The agent may adjust file names to fit the chosen libraries, but must
preserve the module boundaries and responsibilities.

### 4.5 Submodule workflow

Initial setup, performed once by the agent:

``` bash
git submodule add <backend-repo-url> backend
git submodule add <frontend-repo-url> frontend
git commit -m "Add backend and frontend submodules"
```

Cloning and updating:

``` bash
git clone --recurse-submodules <parent-repo-url>
git submodule update --init --recursive
git submodule update --remote --merge   # advance to each submodule's tip
```

Rules:

-   Commit inside a submodule first, push it, then commit the updated
    submodule pointer in the parent repository. Never commit a pointer to
    an unpushed submodule commit.
-   Pin submodules to a branch (`branch = main` in `.gitmodules`) so
    `--remote` updates are predictable.
-   CI for each submodule lives in that submodule's repository. The
    parent repository CI only verifies that both submodules are
    initialized and that their pinned commits build.
-   A change that spans both sides is two commits in two repositories
    plus one pointer update in the parent. Document the pairing in the
    parent commit message.
-   Do not use `git submodule foreach` to run application tests; run each
    submodule's own scripts.

### 4.6 Shared contracts across the submodule boundary

Because the two applications no longer share a workspace, shared
TypeScript contracts must be distributed explicitly:

-   The backend is authoritative for request/response shapes and
    platform presets.
-   Publish the contracts as a versioned package (for example
    `@social-resizer/contracts`) from the backend repository, or generate
    a typed client from the Elysia OpenAPI document.
-   The frontend consumes a pinned version and upgrades deliberately.
-   Never import across the submodule boundary with relative paths such
    as `../backend/src/...`.
-   The frontend must still treat API responses as runtime-untrusted
    data even when typed by the shared package.

------------------------------------------------------------------------

## 5. Authentication: access code → JWT

Authentication is intentionally lightweight for the assessment, but it is
**not** cookie-based and **not** CSRF-protected. The credential is a signed
JWT sent as a bearer token. This section is the authoritative description of
what is implemented.

### 5.1 The flow

```
operator                    backend                     browser
   |                           |                            |
   | bun run auth:code         |                            |
   |-------------------------->|  INSERT access_codes       |
   |<--------------------------|  (hash only)               |
   |      "9GGCN-SKFAC"        |                            |
   |                           |                            |
   |  (out of band: email/Slack/read it aloud)              |
   |                           |                            |
   |                           |<--- POST /auth/login {code}
   |                           |  verify hash, expiry,      |
   |                           |  single-use claim          |
   |                           |  INSERT auth_sessions      |
   |                           |--- { token, expiresAt } --->
   |                           |                            | localStorage
   |                           |<--- Authorization: Bearer <token>
   |                           |  verify signature + exp    |
   |                           |  check auth_sessions row   |
   |                           |--- 200 ------------------->|
```

1. **The operator issues a code.** `bun run auth:code -- --label "alice"`
   creates a demo user (or reuses one via `--user <uuid>`) and an
   `access_codes` row. The raw code is printed **once** and never stored —
   only its SHA-256 hash is persisted.
2. **The user enters the code** on `/login`. The frontend posts it to
   `POST /api/v1/auth/login`.
3. **The backend verifies the code** (hash match, not expired, not revoked,
   not already redeemed) and, in the same transaction, claims it as redeemed
   and inserts an `auth_sessions` row whose `id` becomes the token's `jti`.
4. **The backend returns a JWT** plus its expiry. The frontend stores it in
   `localStorage`.
5. **Every subsequent request** carries `Authorization: Bearer <token>`. The
   backend verifies the signature and `exp`, then confirms the `auth_sessions`
   row still exists and is not revoked.
6. **Logout** sets `revoked_at` on that row, so the token stops working
   immediately rather than at expiry.

### 5.2 Why a bearer token instead of a cookie

The previous implementation used an `HttpOnly` session cookie plus a
double-submit CSRF token. That was replaced because:

-   **Cross-site cookies were fragile.** The frontend (`*.vercel.app`) and API
    (`*.up.railway.app`) are on different registrable domains, so
    `SameSite=Lax` cookies were never sent and the session silently vanished.
    Making it work required `SameSite=None; Secure`, which is a weaker
    default and still depends on third-party-cookie policy.
-   **CSRF does not apply to bearer tokens.** A browser never attaches an
    `Authorization` header on its own, so a cross-site form post or image tag
    cannot carry the credential. The attack CSRF defends against is
    structurally impossible here, so the CSRF token was removed rather than
    carried along as ceremony.
-   **The `Origin` allow-list is kept** as defence in depth on every unsafe
    method (section 14).

**Tradeoff, stated plainly:** `localStorage` is readable by any script running
on the frontend origin, so an XSS bug could exfiltrate the token. Mitigations:
a 24-hour expiry, immediate server-side revocation on logout, no third-party
scripts, and React's default output escaping. A future hardening step is to
move the token to an `HttpOnly` cookie scoped to a shared parent domain, which
would reintroduce the need for CSRF protection.

### 5.3 Token format

HS256, hand-rolled in `backend/src/modules/auth/jwt.ts` using `node:crypto`
(no new dependency). Claims:

| Claim | Meaning |
| --- | --- |
| `sub` | user id |
| `jti` | `auth_sessions.id` — the revocation handle |
| `iat` | issued-at, seconds |
| `exp` | expiry, seconds |

Verification rules, all enforced in `verifyAccessToken`:

-   exactly three dot-separated segments;
-   header `alg` must be `HS256` — the algorithm is **never** taken from the
    token, which defeats `alg: none` and algorithm-confusion attacks;
-   signature compared with `timingSafeEqual` (constant time, no early exit on
    length mismatch);
-   `sub` and `jti` must be non-empty strings;
-   `exp` must be in the future.

Any failure returns `null`, and `null` is always treated as unauthenticated.
There is no partial-trust result.

### 5.4 Two-layer validation

A JWT alone cannot be withdrawn, so validation is deliberately redundant:

1. **Stateless** — signature and `exp`. Cheap, no database round trip.
2. **Stateful** — the `auth_sessions` row must exist, be unrevoked, be
   unexpired, and its `user_id` must equal the token's `sub`.

Layer 2 is what makes logout immediate. It costs one indexed primary-key
lookup per request, which is the correct trade for a revocable credential.

### 5.5 Endpoints

``` http
POST /api/v1/auth/login     { "code": "9GGCN-SKFAC" }  -> 200 { token, expiresAt, user }
GET  /api/v1/auth/session                              -> 200 { token, expiresAt, user }
POST /api/v1/auth/logout                               -> 204
```

`/auth/login` is the only unauthenticated endpoint that mutates state, and it
is rate limited by the `auth.login` rule (10 per 15 minutes per IP).

`/auth/session` echoes the caller's own token back so a page reload can
rehydrate without a second login round trip.

### 5.6 Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `JWT_SECRET` | *(required, min 32 chars)* | HS256 signing key. Rotating it invalidates every issued token — the "sign everyone out" lever. |
| `JWT_TTL_HOURS` | `24` | Token lifetime. The user re-enters a code after this. |
| `ACCESS_CODE_SINGLE_USE` | `true` | Whether a code can be redeemed more than once. |
| `ACCESS_CODE_TTL_HOURS` | `720` (30 days) | How long an unused code stays redeemable. |

Generate a secret with `openssl rand -base64 48`.

### 5.7 Issuing codes

``` bash
# Local
cd backend && bun run auth:code -- --label "alice"

# Against the deployed database
railway run --service blueberrylabs-backend bun run auth:code -- --label "alice"

# Another code for an existing user (e.g. a second device)
bun run auth:code -- --user <uuid> --label "second device"
```

The code is 10 alphanumerics, displayed grouped as `ABCDE-FGHIJ`. Input is
normalised (separators stripped, case folded) before hashing, so
`abcde-fghij`, `ABCDE FGHIJ`, and `ABCDEFGHIJ` all resolve to the same row.

### 5.8 Demo limitations

This is not production-grade account authentication. Documented plainly:

-   There is no signup, password, OAuth, or email verification. Codes are
    issued by an operator out of band.
-   There is no per-user profile, password reset, or account recovery.
-   A code is a bearer credential: anyone who has it can sign in until it is
    redeemed (if single-use) or expires.
-   Demo mode must not be presented as secure multi-tenant identity.
-   Before public production use, replace this with a proper identity provider
    and retain the same `userId` ownership model — every route already derives
    `userId` from the verified token, so the swap is contained to
    `modules/auth/` and `middleware/auth.ts`.

### 5.9 What was removed

The cookie + CSRF implementation was deleted, not left dormant:

-   `demo_sessions` table (kept in the schema for the migration history, no
    longer written to; the cleanup function still prunes it).
-   `bl_session` / `bl_csrf` cookies, `SESSION_COOKIE`, `CSRF_COOKIE`,
    `parseCookies`, `sessionCookie`, `csrfCookie`, `clearSessionCookies`,
    `verifyCsrf`.
-   `COOKIE_SECURE`, `COOKIE_SAME_SITE`, `DEMO_SESSION_SECRET`,
    `DEMO_SESSION_TTL_HOURS` environment variables.
-   `POST /api/v1/auth/demo`.
-   The `X-CSRF-Token` CORS allowed header (replaced by `Authorization`).
-   `CSRF_TOKEN_INVALID` is still a valid error code in the contracts package
    for compatibility, but nothing emits it.

------------------------------------------------------------------------

## 6. Railway Buckets and upload design

### 6.1 Buckets

Create two private Railway Buckets:

  Bucket              Purpose
  ------------------- ------------------------
  `media-originals`   Uploaded source images
  `media-generated`   Resized output images

Use separate credentials if Railway supports the desired access scope;
otherwise use one server-side credential set and enforce separation
through object-key conventions and application authorization.

Never expose access keys or secret keys to the browser.

### 6.2 Object keys

Do not use a user-supplied filename as an object key.

``` text
originals/{userId}/{assetId}/source
generated/{userId}/{generationId}/output.{ext}
```

Store the bucket name and object key in PostgreSQL, not permanent URLs.

### 6.3 Direct upload flow

1.  Browser sends `POST /api/v1/uploads` with filename, MIME type, and
    size.
2.  API authenticates user and applies upload rate limit.
3.  API validates file metadata and allowed type/size.
4.  API creates an `assets` row with `upload_status = PENDING`.
5.  API creates a short-lived presigned PUT URL for the exact object
    key.
6.  API returns `assetId`, URL, required headers, and expiry.
7.  Browser uploads directly to Railway Bucket using `XMLHttpRequest` so
    it can observe upload progress.
8.  Browser sends `POST /api/v1/uploads/:assetId/complete`.
9.  API performs a storage `HEAD`/metadata check and verifies actual
    size and content type as far as the object store permits.
10. API updates the asset to `UPLOADED` only after successful
    verification.

A presigned URL being issued is not proof that the upload succeeded.

### 6.4 Upload API

``` http
POST /api/v1/uploads
```

Request:

``` json
{
  "filename": "campaign-image.png",
  "contentType": "image/png",
  "sizeBytes": 1839200
}
```

Response:

``` json
{
  "assetId": "uuid",
  "uploadUrl": "presigned-url",
  "method": "PUT",
  "headers": {
    "Content-Type": "image/png"
  },
  "expiresAt": "ISO-8601 timestamp"
}
```

Completion:

``` http
POST /api/v1/uploads/{assetId}/complete
```

Response:

``` json
{
  "assetId": "uuid",
  "uploadStatus": "UPLOADED"
}
```

### 6.5 Upload progress in the browser

Use `XMLHttpRequest` for direct presigned PUT uploads:

``` ts
function uploadFile(
  url: string,
  file: File,
  headers: Record<string, string>,
  onProgress: (percent: number) => void
): Promise<void> {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open("PUT", url);

    for (const [key, value] of Object.entries(headers)) {
      xhr.setRequestHeader(key, value);
    }

    xhr.upload.onprogress = (event) => {
      if (event.lengthComputable) {
        onProgress(Math.round((event.loaded / event.total) * 100));
      }
    };

    xhr.onload = () => {
      if (xhr.status >= 200 && xhr.status < 300) resolve();
      else reject(new Error(`Upload failed (${xhr.status})`));
    };

    xhr.onerror = () => reject(new Error("Upload network error"));
    xhr.onabort = () => reject(new Error("Upload cancelled"));
    xhr.send(file);
  });
}
```

The frontend must configure Railway Bucket CORS to allow the Vercel
production origin and local development origin, the required PUT method,
and the required headers. Do not use wildcard origins in production if
the bucket configuration supports explicit origins.

### 6.6 File validation

Initial limits:

``` env
MAX_IMAGE_SIZE_MB=25
ALLOWED_IMAGE_TYPES=image/jpeg,image/png,image/webp
```

-   Validate file extension and MIME type at request time.
-   Verify the actual object exists and its size after upload.
-   Inspect/decode the image with Sharp in the worker before processing.
-   Reject malformed, unsupported, or excessively large-dimension
    images.
-   Do not trust browser-provided MIME type as the sole validation.
-   Set reasonable pixel/dimension limits to mitigate decompression
    bombs.
-   Use generated object keys and never interpolate untrusted path
    fragments.

------------------------------------------------------------------------

## 7. Image transformation behavior

### 7.1 Preset configuration

Create a shared typed preset registry:

``` ts
export const IMAGE_PRESETS = {
  instagram: {
    square: { width: 1080, height: 1080 },
    portrait: { width: 1080, height: 1350 },
    story: { width: 1080, height: 1920 },
  },
  tiktok: {
    cover: { width: 1080, height: 1920 },
  },
  youtube: {
    thumbnail: { width: 1280, height: 720 },
  },
} as const;
```

Validate the platform/format pair against this registry on the server.
The client must not submit arbitrary dimensions.

### 7.2 MVP crop behavior

-   Resize to the selected exact dimensions.
-   Use `fit: cover`.
-   Use center positioning.
-   Never stretch or distort the source.
-   Output JPEG for JPEG input, or normalize all outputs to JPEG. Prefer
    normalizing to JPEG for the MVP unless transparency is explicitly
    required.
-   For PNG/WebP input with transparency, define and document a
    background color before JPEG conversion; alternatively preserve
    transparency by outputting WebP/PNG. Do not silently discard
    transparency.
-   Set output quality to a configurable default, e.g. 85.
-   Strip unnecessary metadata unless required.
-   Preserve source asset unchanged.

### 7.3 Sharp example

``` ts
await sharp(sourceBuffer, {
  failOn: "error",
  limitInputPixels: 40_000_000,
})
  .rotate()
  .resize(width, height, {
    fit: "cover",
    position: "centre",
  })
  .jpeg({ quality: 85, mozjpeg: true })
  .toFile(outputPath);
```

Implementation must avoid loading unbounded source files into memory.
Stream or use bounded temporary files where practical. Clean up
temporary files in `finally` blocks. Do not store temporary media
permanently on the Railway filesystem.

------------------------------------------------------------------------

## 8. PostgreSQL data model

Use UUID primary keys unless there is a strong reason otherwise. Use
timezone-aware timestamps (`timestamptz`) and UTC in the database.

### 8.1 `users`

Demo identity table.

  Column         Type          Notes
  -------------- ------------- -------------------
  `id`           uuid PK       User/principal ID
  `kind`         text          `DEMO` for MVP
  `created_at`   timestamptz   Default now

### 8.2 `access_codes`

The only way to obtain a token (section 5).

  Column         Type                   Notes
  -------------- ---------------------- ------------------------------------------------
  `id`           uuid PK                Code ID
  `code_hash`    text unique            SHA-256 of the normalised code; raw code never stored
  `user_id`      uuid FK                References users (cascade delete)
  `label`        text nullable          Operator note, e.g. who the code was issued to
  `expires_at`   timestamptz            After this the code is refused
  `redeemed_at`  timestamptz nullable   Set on first successful login (single-use)
  `revoked_at`   timestamptz nullable   Manual revocation
  `created_at`   timestamptz            Default now

Indexes: unique on `code_hash` (the login lookup), plus `user_id` and
`expires_at` for the retention sweep.

Single-use is enforced by `UPDATE ... WHERE redeemed_at IS NULL RETURNING id`
inside the login transaction, so two concurrent redemptions of one code yield
exactly one token (covered by an integration test).

### 8.3 `auth_sessions`

One row per issued token. The row **is** the revocation record.

  Column         Type                   Notes
  -------------- ---------------------- ------------------------------------------------
  `id`           uuid PK                Equals the JWT `jti`
  `user_id`      uuid FK                References users (cascade delete)
  `expires_at`   timestamptz            Mirrors the token `exp`
  `revoked_at`   timestamptz nullable   Set by logout; makes the token fail immediately
  `created_at`   timestamptz            Default now

Indexes: `user_id` and `expires_at`.

`id` is supplied by the application (not `defaultRandom()`) because it must
equal the `jti` minted into the token.

### 8.4 `demo_sessions` (legacy, unused)

The pre-JWT cookie session table. Retained so the migration history stays
linear and so the cleanup function can still prune old rows; nothing writes to
it any more. It will be dropped in a future migration.

  Column             Type                   Notes
  ------------------ ---------------------- -----------------------------------
  `id`               uuid PK                Session ID
  `user_id`          uuid FK                References users
  `token_hash`       text unique            Hashed session token
  `csrf_token_hash`  text                   Hashed CSRF token
  `expires_at`       timestamptz            Session expiry
  `created_at`       timestamptz            Default now
  `revoked_at`       timestamptz nullable   Logout/revocation

### 8.5 `assets`

  Column                Type                   Notes
  --------------------- ---------------------- ----------------------------------------
  `id`                  uuid PK                Asset ID
  `user_id`             uuid FK                Owner
  `kind`                text                   `IMAGE`
  `original_filename`   text                   Display only; never object key
  `mime_type`           text                   Verified MIME type
  `size_bytes`          bigint                 Verified size
  `width`               integer nullable       Extracted dimensions
  `height`              integer nullable       Extracted dimensions
  `bucket`              text                   `media-originals` or `media-generated`
  `storage_key`         text                   Object key
  `upload_status`       text                   `PENDING`, `UPLOADED`, `FAILED`
  `created_at`          timestamptz            Default now
  `uploaded_at`         timestamptz nullable   Verified upload time

Indexes: - `(user_id, created_at DESC)` - `(upload_status, created_at)`

### 8.6 `generations`

  Column              Type                   Notes
  ------------------- ---------------------- -----------------------------------------------
  `id`                uuid PK                Generation ID
  `user_id`           uuid FK                Owner
  `input_asset_id`    uuid FK                Original asset
  `output_asset_id`   uuid FK nullable       Processed asset
  `platform`          text                   `INSTAGRAM`, `TIKTOK`, `YOUTUBE`
  `format`            text                   Preset key
  `status`            text                   `QUEUED`, `PROCESSING`, `COMPLETED`, `FAILED`
  `progress`          integer                0--100
  `current_step`      text nullable          Machine-readable step
  `message`           text nullable          Safe user-facing message
  `error_code`        text nullable          Stable error code
  `error_message`     text nullable          Sanitized message
  `idempotency_key`   text                   Client-generated request key
  `created_at`        timestamptz            Default now
  `started_at`        timestamptz nullable   Processing start
  `completed_at`      timestamptz nullable   Terminal timestamp

Constraints: - `progress BETWEEN 0 AND 100`. - Unique
`(user_id, idempotency_key)` where idempotency key is not null. - Only
valid status values. - Ensure input and output assets belong to the same
user as the generation.

Indexes: - `(user_id, created_at DESC)` - `(status, created_at)` -
`(input_asset_id)`

### 8.7 `jobs`

  -----------------------------------------------------------------------
  Column                  Type                    Notes
  ----------------------- ----------------------- -----------------------
  `id`                    uuid PK                 Job ID

  `type`                  text                    `PROCESS_IMAGE`

  `payload`               jsonb                   Contains generation ID;
                                                  validate on read

  `status`                text                    `QUEUED`, `RUNNING`,
                                                  `COMPLETED`, `FAILED`

  `priority`              integer                 Lower/higher convention
                                                  documented consistently

  `attempts`              integer                 Number of attempts

  `max_attempts`          integer                 Initial default 3

  `run_at`                timestamptz             Earliest execution

  `locked_at`             timestamptz nullable    Lease start

  `locked_by`             text nullable           Process/instance
                                                  identifier

  `last_error`            text nullable           Sanitized error

  `created_at`            timestamptz             Default now

  `updated_at`            timestamptz             Updated on changes

  `completed_at`          timestamptz nullable    Terminal timestamp
  -----------------------------------------------------------------------

Indexes: - `(status, run_at, priority, created_at)` - `(locked_at)` for
stale-job recovery.

### 8.8 `rate_limit_buckets`

  Column            Type          Notes
  ----------------- ------------- ---------------------------------
  `key`             text PK       Hashed principal/IP + operation
  `window_start`    timestamptz   Fixed-window start
  `request_count`   integer       Counter
  `expires_at`      timestamptz   Cleanup time

### 8.9 `generation_events`

  -----------------------------------------------------------------------
  Column                  Type                    Notes
  ----------------------- ----------------------- -----------------------
  `id`                    bigserial PK            Event ID

  `generation_id`         uuid FK                 Related generation

  `event_type`            text                    `QUEUED`, `PROCESSING`,
                                                  `PROGRESS`,
                                                  `COMPLETED`, `FAILED`

  `progress`              integer nullable        Progress snapshot

  `message`               text nullable           Safe message

  `metadata`              jsonb                   Non-sensitive
                                                  structured metadata

  `created_at`            timestamptz             Default now
  -----------------------------------------------------------------------

Use this table for audit/debug history, not as the primary status
response. The current `generations` row remains the source of truth.

### 8.10 Schema and migration rules

-   Use Drizzle schema definitions and checked-in SQL migrations.
-   Never use automatic destructive schema synchronization in
    production.
-   Add foreign keys and indexes deliberately.
-   Add `ON DELETE` behavior explicitly.
-   Do not store presigned URLs in the database.
-   Do not store secrets, raw session tokens, or full sensitive request
    headers in the database.
-   Add a retention/cleanup policy for expired sessions, old rate-limit
    buckets, failed uploads, and old generated files.

------------------------------------------------------------------------

## 9. PostgreSQL job queue

### 9.1 Why a database queue

A PostgreSQL queue is sufficient for this MVP and avoids Redis or a
separate queue service. It must be durable and safe under concurrent
backend instances.

### 9.2 Enqueue transaction

Creating a generation and its job must happen in one database
transaction:

1.  Validate the uploaded asset belongs to the user and is `UPLOADED`.
2.  Validate platform/format.
3.  Check idempotency key.
4.  Insert generation with `QUEUED`, progress 0.
5.  Insert `PROCESS_IMAGE` job with generation ID payload.
6.  Insert `QUEUED` generation event.
7.  Commit.
8.  Return HTTP 202.

If the transaction fails, neither the generation nor the job should be
left half-created.

### 9.3 Atomic job claiming

Use a transaction and `FOR UPDATE SKIP LOCKED`:

``` sql
WITH candidate AS (
  SELECT id
  FROM jobs
  WHERE status = 'QUEUED'
    AND run_at <= now()
  ORDER BY priority DESC, created_at ASC
  FOR UPDATE SKIP LOCKED
  LIMIT 1
)
UPDATE jobs
SET
  status = 'RUNNING',
  locked_at = now(),
  locked_by = $1,
  attempts = attempts + 1,
  updated_at = now()
WHERE id IN (SELECT id FROM candidate)
RETURNING *;
```

Execute this inside a transaction. Ensure the SQL and priority
convention are consistent. The worker must not claim more work than its
configured concurrency allows.

### 9.4 Worker loop

-   Start after database and storage clients are initialized.
-   Poll for available work with a modest interval (e.g. 500--1000 ms);
    use backoff when idle.
-   Initial concurrency: `1`.
-   Set a stable instance identifier for `locked_by`.
-   Process one job with a timeout appropriate for image size.
-   Update the job lease while long-running work is active, or use a
    lease duration safely longer than expected processing time.
-   On completion, mark job `COMPLETED`.
-   On retryable failure, set `QUEUED`, clear lock, increment attempts,
    and set future `run_at`.
-   On permanent failure or exhausted attempts, mark job `FAILED` and
    generation `FAILED`.
-   Do not leave a job permanently `RUNNING` if the process crashes.

### 9.5 Retry policy

Use exponential backoff with jitter, for example:

``` text
attempt 1 failure -> retry after ~5 seconds
attempt 2 failure -> retry after ~15 seconds
attempt 3 failure -> terminal failure
```

The exact schedule should be configurable. Classify errors: - Retryable:
temporary storage/network failures, transient database connectivity. -
Permanent: invalid/corrupt image, unsupported format, invalid preset,
file exceeds validated limits.

### 9.6 Stale-job recovery

At startup and periodically: - Find `RUNNING` jobs whose lease is older
than the configured timeout. - Requeue if attempts remain. - Otherwise
mark failed. - Reconcile generation status so a generation is not stuck
in `PROCESSING`.

### 9.7 Idempotent processing

A job may be delivered more than once after a crash. The handler must: -
Read the generation and return early if already `COMPLETED`. - Use a
deterministic output key for a generation. - Make output upload safe to
repeat (overwrite the same key or verify existing output). - Use guarded
state transitions. - Never create multiple output assets for the same
completed generation.

### 9.8 Graceful shutdown

On SIGTERM/SIGINT: - Stop claiming new jobs. - Allow current job to
finish within Railway's shutdown grace period. - If it cannot finish,
release/requeue the job safely or let lease recovery handle it. - Close
database and storage clients. - Exit cleanly.

------------------------------------------------------------------------

## 10. Generation state machine and progress

### 10.1 Business status

``` text
QUEUED
  |
  v
PROCESSING
  | \
  |  \----> FAILED
  |
  v
COMPLETED
```

Do not allow arbitrary state transitions. `COMPLETED` and `FAILED` are
terminal for the MVP. A retry should be a new generation or an
explicitly designed retry operation, not an accidental transition from
`COMPLETED` to `PROCESSING`.

### 10.2 Progress stages

Use meaningful stage progress rather than arbitrary percentages:

  Stage                   Progress
  --------------------- ----------
  `QUEUED`                       0
  `VALIDATING_INPUT`            10
  `DOWNLOADING_INPUT`           20
  `RESIZING_IMAGE`              55
  `UPLOADING_OUTPUT`            85
  `FINALIZING`                  95
  `COMPLETED`                  100

The worker updates `generations.progress`, `current_step`, and a
`generation_events` row when a stage changes.

Progress is an approximate stage indicator, not a precise measurement of
CPU work. Do not animate fake progress independently in the frontend.

### 10.3 Status API response

``` json
{
  "id": "generation-uuid",
  "status": "PROCESSING",
  "progress": 55,
  "currentStep": "RESIZING_IMAGE",
  "message": "Resizing image for Instagram",
  "output": null,
  "error": null,
  "createdAt": "2026-01-01T10:00:00.000Z",
  "startedAt": "2026-01-01T10:00:02.000Z",
  "completedAt": null
}
```

On completion, the API may include an output metadata object but should
not persist or expose a long-lived signed URL:

``` json
{
  "id": "generation-uuid",
  "status": "COMPLETED",
  "progress": 100,
  "currentStep": "COMPLETED",
  "message": "Your image is ready",
  "output": {
    "assetId": "output-asset-uuid",
    "width": 1080,
    "height": 1350,
    "mimeType": "image/jpeg",
    "sizeBytes": 412345
  },
  "error": null
}
```

The frontend then calls the download/preview endpoint to obtain a fresh
signed URL.

------------------------------------------------------------------------

## 11. Frontend status delivery: REST polling

Use polling for MVP. The backend does not push job status to the
browser.

### 11.1 Flow

1.  Frontend creates generation and receives `generationId` with
    `QUEUED`.
2.  Frontend navigates to or displays the generation view.
3.  Frontend calls `GET /api/v1/generations/:id`.
4.  Poll every 2 seconds while status is `QUEUED` or `PROCESSING`.
5.  Back off to 5 seconds for longer waits or temporary errors.
6.  Stop polling on `COMPLETED` or `FAILED`.
7.  On completion, request a signed output URL and render the preview.
8.  If the user closes the browser, the backend job continues. On
    return, load the generation by ID and fetch its current state.

### 11.2 Polling requirements

-   Poll only while a generation is non-terminal.
-   Stop polling when the component unmounts.
-   Use `AbortController` or equivalent cancellation.
-   Pause or slow polling when `document.visibilityState === "hidden"`.
-   Handle 401/403/404 distinctly.
-   Retry transient network errors with bounded exponential backoff.
-   Do not create overlapping requests.
-   Avoid polling every generation in history simultaneously; poll only
    the active detail view.
-   Respect `Retry-After` if the API rate-limits the status request.

### 11.3 Upload and processing are separate UI states

Upload progress comes from browser upload events. Processing progress
comes from PostgreSQL through the status endpoint.

Recommended UI phases:

``` text
SELECT_IMAGE
  -> REQUESTING_UPLOAD
  -> UPLOADING (browser progress %)
  -> VERIFYING_UPLOAD
  -> READY_TO_GENERATE
  -> QUEUED
  -> PROCESSING (server progress %)
  -> COMPLETED | FAILED
```

Do not show a single progress bar that implies upload percentage and
processing percentage are one continuous measurement.

------------------------------------------------------------------------

## 12. REST API specification

Base path: `/api/v1`

All request and response bodies are JSON except direct object-storage
upload.

### 12.1 Authentication

  Method   Path              Auth   Purpose
  -------- ----------------- ------ -------------------------------------------
  POST     `/auth/login`     none   Exchange an access code for a JWT
  GET      `/auth/session`   bearer Return the current principal
  POST     `/auth/logout`    bearer Revoke the current token (204)

`POST /auth/login` request and response:

``` json
// request
{ "code": "9GGCN-SKFAC" }

// 200
{
  "token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9....",
  "expiresAt": "2026-11-06T16:50:00.000Z",
  "user": { "id": "uuid", "kind": "DEMO" }
}
```

Every other endpoint requires `Authorization: Bearer <token>`. A missing,
malformed, tampered, expired, or revoked token yields `401 UNAUTHENTICATED`
before the route handler runs. There is no CSRF token (section 5.2).

### 12.2 Uploads and assets

  ---------------------------------------------------------------------------------
  Method                  Path                              Purpose
  ----------------------- --------------------------------- -----------------------
  POST                    `/uploads`                        Create asset and signed
                                                            upload URL

  POST                    `/uploads/:assetId/complete`      Verify object and
                                                            finalize upload

  GET                     `/assets/:assetId`                Get owned asset
                                                            metadata

  GET                     `/assets/:assetId/download-url`   Get short-lived signed
                                                            URL
  ---------------------------------------------------------------------------------

### 12.3 Generations

  -------------------------------------------------------------------------------------------
  Method                  Path                                        Purpose
  ----------------------- ------------------------------------------- -----------------------
  POST                    `/generations`                              Create generation and
                                                                      enqueue job

  GET                     `/generations/:generationId`                Get status and output
                                                                      metadata

  GET                     `/generations`                              List current user's
                                                                      generations

  POST                    `/generations/:generationId/download-url`   Get signed output URL
  -------------------------------------------------------------------------------------------

### 12.4 Health

  Method   Path              Purpose
  -------- ----------------- ----------------------------------------------
  GET      `/health/live`    Process is alive
  GET      `/health/ready`   Database and required dependencies are ready

Do not expose detailed internal errors, stack traces, environment
variables, or credentials from health endpoints.

### 12.5 Create generation request

``` http
POST /api/v1/generations
Idempotency-Key: <random-client-generated-key>
Content-Type: application/json
```

``` json
{
  "assetId": "uploaded-asset-uuid",
  "platform": "INSTAGRAM",
  "format": "PORTRAIT"
}
```

Response:

``` http
HTTP/1.1 202 Accepted
```

``` json
{
  "generationId": "generation-uuid",
  "status": "QUEUED",
  "progress": 0
}
```

Idempotency behavior: - Same authenticated principal + same key + same
request returns the existing generation. - Same key with a different
request returns `409 Conflict`. - Enforce a unique database constraint
to handle concurrent duplicate requests.

### 12.6 Error format

Use a consistent shape:

``` json
{
  "error": {
    "code": "RATE_LIMIT_EXCEEDED",
    "message": "Too many requests. Please try again shortly.",
    "requestId": "request-uuid",
    "retryAfterSeconds": 30
  }
}
```

Never return internal exception details to the browser.

------------------------------------------------------------------------

## 13. Rate limiting and abuse prevention

Rate limiting is mandatory in the initial implementation.

### 13.1 Initial limits

These are initial defaults and must be environment-configurable:

  Operation                       Limit Key
  ----------------------- ------------- -------------
  Demo session creation     10 / 15 min IP
  Create upload URL            10 / min User and IP
  Complete upload              10 / min User
  Create generation             3 / min User
  Get generation status       120 / min User
  Create download URL          30 / min User
  General API fallback        300 / min User and IP

Also enforce: - Maximum 2 concurrent generations per user. - Maximum 20
generations per user per day. - Maximum image size 25 MB. - Maximum
image pixel count (initially 40 megapixels; configurable). - Maximum
number of pending uploads per user (initially 5). - Short expiry for
upload and download URLs.

For a shared demo principal, user limits alone are not sufficient. Apply
IP-based limits too. Hash or otherwise minimize retention of IP
identifiers in rate-limit keys and logs.

### 13.2 PostgreSQL implementation

Use an atomic fixed-window counter implemented by a SQL function or
transaction with `INSERT ... ON CONFLICT DO UPDATE`. It must return both
`allowed` and `remaining` (and preferably reset time).

Requirements: - One atomic operation per rate-limit decision. - Correct
under concurrent API instances. - No read-then-write race. - Do not use
process-local memory as the authoritative limiter. - Clean expired rows
periodically. - Hash long or sensitive rate-limit keys before
persistence. - Return HTTP 429 and `Retry-After`. - Add rate-limit
headers where practical: `RateLimit-Limit`, `RateLimit-Remaining`,
`RateLimit-Reset`.

### 13.3 Quotas vs rate limits

Keep separate concepts: - Rate limit: request frequency over a short
window. - Daily quota: number of generations in a calendar day (UTC). -
Concurrency limit: number of active jobs. - File limit: maximum uploaded
bytes/pixels.

Check quotas and concurrency in a transaction when creating a generation
so simultaneous requests cannot bypass limits.

### 13.4 Proxy/IP handling

The API is behind Railway's proxy. Determine the documented Railway
forwarding-header behavior during implementation. Only trust headers set
by the trusted proxy path; do not blindly trust arbitrary
client-supplied `X-Forwarded-For`. If the client IP cannot be obtained
safely, document the limitation and ensure authenticated user limits
still work.

------------------------------------------------------------------------

## 14. Security requirements

-   All application endpoints except health and demo-session creation
    require a valid demo session.
-   Never accept `userId` from the client as authorization input.
-   Check ownership for every asset and generation query.
-   Keep Railway Bucket credentials server-side.
-   Use private buckets and short-lived presigned URLs.
-   Restrict CORS to Vercel production origin and approved local
    development origin.
-   Validate request schemas and reject unknown or invalid enum values.
-   Enforce upload limits before signing and verify actual uploaded
    object metadata afterward.
-   Decode/inspect image data with Sharp before accepting it for
    processing.
-   Use generated object keys, not original filenames.
-   Avoid logging authorization headers, signed URLs, access codes, or
    secret values.
-   Verify the JWT signature and expiry on every authenticated request, and
    check the `auth_sessions` row so revocation is immediate (section 5.4).
-   Never read the signing algorithm from the token header (defeats
    `alg: none` and algorithm confusion).
-   Compare signatures in constant time.
-   Store only hashes of access codes; never persist or log the raw code.
-   CSRF protection is not applicable to bearer tokens (section 5.2). If the
    token is ever moved into a cookie, CSRF protection becomes mandatory again.
-   Use parameterized SQL/Drizzle queries.
-   Apply request body size limits.
-   Use safe error messages and centralized error handling.
-   Do not expose stack traces in production.
-   Use least-privilege bucket credentials if supported.
-   Add security headers to the frontend and API as appropriate.
-   Document demo-auth limitations prominently.

------------------------------------------------------------------------

## 15. Observability

Observability must cover both HTTP requests and asynchronous processing.

### 15.1 Structured logs

Emit JSON logs to stdout/stderr so Railway captures them.

Every relevant log should include:

``` json
{
  "timestamp": "ISO-8601",
  "level": "info",
  "service": "api",
  "event": "generation.processing.started",
  "requestId": "request-uuid",
  "generationId": "generation-uuid",
  "assetId": "asset-uuid",
  "jobId": "job-uuid",
  "userId": "user-uuid",
  "durationMs": 123
}
```

Do not log raw files, signed URLs, cookies, authorization headers, or
secrets.

### 15.2 Correlation

-   Generate a request ID for every incoming request.
-   Return it in an `X-Request-Id` response header.
-   Persist/propagate `generationId`, `assetId`, and `jobId` through job
    payload and logs.
-   Include the originating request ID in generation/job metadata where
    useful.
-   The worker must log the same generation and job IDs so the full
    lifecycle can be traced.

### 15.3 Metrics

At minimum, expose or record: - HTTP request count and latency by
route/status. - Rate-limit rejections by operation. - Upload
success/failure count and bytes. - Queue depth (queued jobs). - Jobs
started/completed/failed/retried. - Job duration. - Image processing
duration. - Generation duration. - Stale jobs recovered. - Worker
concurrency and active job count.

Avoid high-cardinality metric labels such as user IDs, generation IDs,
or request IDs. Those belong in logs/traces, not metric dimensions.

### 15.4 Error tracking and tracing

-   Integrate Sentry or an equivalent error tracker behind optional
    environment configuration.
-   Capture unhandled API and worker errors.
-   Use OpenTelemetry where the Bun runtime and selected exporters
    support it; do not claim full distributed tracing if only partial
    instrumentation is available.
-   If tracing integration is delayed, request IDs and structured
    lifecycle logs are still mandatory for MVP acceptance.

### 15.5 Health checks

`/health/live`: process is running.

`/health/ready`: database connection works and required configuration is
loaded. Optionally perform a lightweight storage configuration check
without making the endpoint slow or exposing secrets.

------------------------------------------------------------------------

## 16. Configuration and environment variables

Create `.env.example` with placeholders only. Because the applications
live in separate repositories, each submodule owns its own
`.env.example` (`backend/.env.example`, `frontend/.env.example`). The
parent repository may keep a root `.env.example` that documents both
sides for local orchestration, but it must contain placeholders only and
must never be the file the applications load at runtime.

### Backend (`backend/.env.example`)

``` env
NODE_ENV=development
PORT=3001
LOG_LEVEL=debug

DATABASE_URL=postgresql://...

WEB_ORIGIN=http://localhost:3000
API_PUBLIC_URL=http://localhost:3001

# openssl rand -base64 48
JWT_SECRET=replace-with-at-least-32-random-chars
JWT_TTL_HOURS=24
ACCESS_CODE_SINGLE_USE=true
ACCESS_CODE_TTL_HOURS=720

RAILWAY_BUCKET_ENDPOINT=
RAILWAY_BUCKET_REGION=
RAILWAY_BUCKET_ACCESS_KEY_ID=
RAILWAY_BUCKET_SECRET_ACCESS_KEY=
RAILWAY_BUCKET_ORIGINALS=media-originals
RAILWAY_BUCKET_GENERATED=media-generated

PRESIGNED_UPLOAD_TTL_SECONDS=600
PRESIGNED_DOWNLOAD_TTL_SECONDS=300

MAX_IMAGE_SIZE_MB=25
MAX_IMAGE_PIXELS=40000000
ALLOWED_IMAGE_TYPES=image/jpeg,image/png,image/webp

WORKER_ENABLED=true
WORKER_CONCURRENCY=1
WORKER_POLL_INTERVAL_MS=750
WORKER_JOB_LEASE_SECONDS=300
WORKER_MAX_ATTEMPTS=3

RATE_LIMIT_DEMO_AUTH=10
RATE_LIMIT_UPLOAD_PER_MINUTE=10
RATE_LIMIT_UPLOAD_COMPLETE_PER_MINUTE=10
RATE_LIMIT_GENERATION_PER_MINUTE=3
RATE_LIMIT_STATUS_PER_MINUTE=120
RATE_LIMIT_DOWNLOAD_URL_PER_MINUTE=30
RATE_LIMIT_GENERAL_PER_MINUTE=300

MAX_CONCURRENT_GENERATIONS_PER_USER=2
MAX_GENERATIONS_PER_USER_PER_DAY=20
MAX_PENDING_UPLOADS_PER_USER=5

SENTRY_DSN=
OTEL_EXPORTER_OTLP_ENDPOINT=
```

The exact Railway Bucket environment-variable names should be taken from
the Railway dashboard's generated connection variables. Map those values
into the application-specific variables above. Do not assume the
dashboard uses these exact names.

### Frontend (`frontend/.env.example`)

``` env
NEXT_PUBLIC_API_BASE_URL=http://localhost:3001
```

The frontend authenticates with a bearer JWT, so no cookie configuration is
needed and `credentials: "include"` is not used. CORS must still allow the
`Authorization` request header. Never put bucket credentials or `JWT_SECRET`
in `NEXT_PUBLIC_*` variables.

------------------------------------------------------------------------

## 17. Local development

### 17.1 Prerequisites

-   Git with submodule support, and access to both submodule
    repositories.
-   Bun version pinned in `backend/package.json` or
    `backend/.tool-versions`.
-   Node.js only if required by tooling; application API runtime is Bun.
-   pnpm or Bun workspace tooling, chosen consistently **within each
    submodule**.
-   Docker Desktop for local PostgreSQL.
-   Railway account/project and Railway Bucket credentials for storage
    integration testing.

### 17.2 Docker Compose

Run PostgreSQL locally:

``` yaml
services:
  postgres:
    image: postgres:16
    environment:
      POSTGRES_USER: app
      POSTGRES_PASSWORD: app
      POSTGRES_DB: social_resizer
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U app -d social_resizer"]
      interval: 5s
      timeout: 5s
      retries: 10

volumes:
  postgres_data:
```

Do not commit real credentials.

### 17.3 Local commands

The agent must provide working scripts in each submodule, plus root
scripts that delegate to them:

``` bash
# parent repository
git submodule update --init --recursive
docker compose up -d postgres
npm run dev          # delegates to backend and frontend
npm run test
npm run lint
npm run typecheck

# backend/ submodule
bun install
bun run db:generate
bun run db:migrate
bun run dev
bun run test
bun run lint
bun run typecheck

# frontend/ submodule
bun install
bun run dev
bun run test
bun run lint
bun run typecheck
```

If pnpm is selected, use pnpm consistently within a submodule instead of
mixing package managers. Do not install application dependencies from the
parent repository root.

------------------------------------------------------------------------

## 18. Deployment plan

### 18.1 Railway resources

Create one Railway project with: 1. PostgreSQL service. 2. Backend
service built from the `backend/` submodule repository. 3.
`media-originals` private Bucket. 4. `media-generated` private Bucket.

Railway must build from the backend repository directly, not from the
parent repository. The parent repository is not a deployable artifact.

The API service runs both Elysia and the background job loop. Do not
create a separate worker service for the MVP.

Configure: - `DATABASE_URL` using Railway's service reference. - Bucket
endpoint, region, access key, and secret key from Railway Bucket
connection details. - Production `WEB_ORIGIN`. - Production secrets and
rate-limit configuration. - Health check path `/health/ready`. - Restart
policy appropriate for the backend.

Use a Dockerfile or Railway build configuration that installs
dependencies, builds the API, and starts the Bun process. Ensure native
Sharp dependencies are installed for the target Linux environment and
architecture.

### 18.2 Vercel

Deploy the `frontend/` submodule repository as the Vercel project root.

Configure: - `NEXT_PUBLIC_API_BASE_URL` to the public Railway API URL. -
Production domain and approved API origin. - Build command and install
command consistent with the frontend submodule's package manager. -
Preview deployment origins if preview deployments are supported; do not
automatically trust every preview origin in production API CORS.

### 18.3 CORS and auth headers

-   Allow only explicit frontend origins.
-   Allow required methods and headers — `Authorization` is required for the
    bearer token, alongside `Content-Type`, `Idempotency-Key`, and
    `X-Request-Id`.
-   Credentials are **not** enabled: there are no cookies to send.
-   Never combine credentialed requests with wildcard origins.
-   Configure Railway Bucket CORS separately for direct browser PUT uploads.

### 18.4 Database migrations

-   Run migrations as a controlled deployment/release step before the
    new API version receives traffic.
-   Do not let every application replica independently race to run
    migrations.
-   Back up production data before destructive migrations.
-   Prefer backward-compatible migrations.

------------------------------------------------------------------------

## 19. Testing strategy

### 19.1 Unit tests

Test: - Platform/format preset validation. - Upload validation. -
Rate-limit decision logic. - Quota logic. - State transition rules. -
Idempotency behavior. - Retry/backoff calculation. - Image processor
dimensions and output format. - Safe error mapping.

### 19.2 Integration tests

Use a test PostgreSQL database and a test bucket or S3-compatible test
service.

Test: - Demo session creation and validation. - User ownership
isolation. - Upload-session creation. - Upload completion
verification. - Generation + job transaction. - Concurrent job claiming
with `SKIP LOCKED`. - Worker success path. - Worker retry path. -
Permanent failure path. - Stale-job recovery. - Duplicate job
delivery/idempotency. - Signed output URL generation. - Rate-limit
concurrency correctness.

### 19.3 End-to-end tests

At least one full browser test must cover:

1.  Enter an access code and receive a JWT.
2.  Upload a supported image.
3.  Observe upload progress.
4.  Select Instagram portrait.
5.  Submit generation.
6.  Observe queued/processing status.
7.  Wait for completion.
8.  Preview output.
9.  Download output.
10. Refresh the page and verify the completed generation remains
    visible.

Also test: - Invalid image type. - File larger than 25 MB. - Upload
interrupted. - Failed processing. - Rate limit exceeded. - Accessing
another user's asset/generation ID. - Refreshing or closing the browser
while a job is processing.

------------------------------------------------------------------------

## 20. Implementation milestones

The coding agent should implement in the following order. Do not start
all layers simultaneously before the foundation works.

### Sprint 0 --- Repository and runtime foundation

Tasks: - Create the parent repository and add `backend/` and
`frontend/` as git submodules. - Add Next.js frontend in the `frontend/`
submodule. - Add Bun + Elysia backend in the `backend/` submodule. - Add
shared TypeScript contracts as a versioned package consumed by the
frontend. - Add environment validation. - Add Docker Compose
PostgreSQL. - Add Railway deployment skeleton and Dockerfile. - Add
lint, format, typecheck, and test scripts in each submodule. - Add
structured logger and request ID middleware.

Acceptance criteria: - `git submodule status` shows both submodules
initialized at pinned commits. - Frontend starts locally. - API starts
locally. - PostgreSQL is reachable. - `/health/live` and `/health/ready`
work. - No secrets are committed. - CI or local scripts pass
lint/typecheck/tests in each submodule.

### Sprint 1 --- Database, demo authentication, and rate limiting

Tasks: - Define Drizzle schema and initial migrations. - Implement demo
session creation, lookup, and logout. - Add ownership-aware request
context. - Implement atomic PostgreSQL rate-limit function. - Add
endpoint rate limits and HTTP 429 response. - Implement daily quota and
concurrent-generation checks. - Add cleanup for expired sessions and
rate-limit rows.

Acceptance criteria: - A browser can create and use a demo session. -
API never trusts a client-supplied user ID. - Protected routes reject
missing/invalid sessions. - Rate limits work under concurrent
requests. - 429 includes `Retry-After`. - Quota checks cannot be
bypassed by simultaneous requests.

### Sprint 2 --- Railway Bucket upload

Tasks: - Implement storage interface and Railway S3-compatible
adapter. - Configure original/generated bucket names. - Implement
create-upload endpoint. - Generate short-lived presigned PUT URL. -
Implement frontend XHR upload progress. - Implement upload-complete
endpoint and object verification. - Persist asset metadata and upload
state. - Add file type/size/pixel validation.

Acceptance criteria: - A valid image uploads directly from browser to
Railway Bucket. - API does not proxy image bytes. - Upload progress is
visible. - Asset becomes `UPLOADED` only after backend verification. -
Invalid/oversized files are rejected. - Bucket credentials never reach
browser code.

### Sprint 3 --- PostgreSQL job queue and image processing

Tasks: - Implement jobs table and atomic claim SQL. - Implement
same-process background loop. - Implement lease, retry, backoff, and
stale-job recovery. - Implement generation transaction and idempotency
key. - Implement Sharp processing for all configured presets. - Upload
output to generated bucket. - Update generation and event state at each
processing stage. - Implement graceful shutdown.

Acceptance criteria: - Generation creation returns quickly with HTTP
202. - Job survives backend restart. - Only one worker claims a job at a
time. - Successful job creates correctly sized output. - Failure is
recorded and retry policy works. - Duplicate requests/jobs do not create
duplicate outputs. - API remains responsive while processing a job.

### Sprint 4 --- Frontend generation UX and polling

Tasks: - Build upload page and platform/format selector. - Build
generation status component. - Implement polling with cancellation and
bounded backoff. - Build generation detail/history view. - Request
signed preview/download URL on completion. - Add failure and
retry/new-generation UX. - Add loading, empty, and error states.

Acceptance criteria: - User can complete image workflow end to end. -
Upload and processing progress are clearly distinct. - Polling stops on
terminal status. - Refreshing the page restores the current
generation. - Preview and download work using signed URLs. - User cannot
access another user's generation.

### Sprint 5 --- Observability, hardening, and deployment

Tasks: - Complete structured API and worker lifecycle logs. - Add
request/generation/job correlation. - Add metrics for API, queue, rate
limits, uploads, and processing. - Configure optional Sentry and
OpenTelemetry exporter. - Add production CORS/cookie configuration. -
Deploy API and PostgreSQL to Railway. - Create and configure Railway
Buckets. - Deploy frontend to Vercel. - Run migrations and end-to-end
smoke test. - Document operational runbook and known limitations.

Acceptance criteria: - Production Vercel frontend can use Railway API
and buckets. - Full image workflow works on deployed environment. - Logs
can trace one generation from request to completion. - Rate limiting and
quotas work in production. - Health checks work. - Secrets are
configured only in server-side environments. - README includes setup,
architecture, environment variables, tests, deployment, and
troubleshooting.

------------------------------------------------------------------------

## 21. Required user experience

The MVP should have a clean, focused interface.

### Main workflow screen

-   Image dropzone and file picker.
-   File name, file size, and image preview.
-   Upload progress indicator.
-   Platform selector: Instagram, TikTok, YouTube.
-   Format selector that changes based on platform.
-   Generate button.
-   Clear validation messages.

### Generation view

-   Original image preview.
-   Selected platform and format.
-   Status label: Queued, Processing, Completed, Failed.
-   Progress bar and current processing stage.
-   Output preview on completion.
-   Download button.
-   Error message and option to start a new generation.

### History

-   List previous generations.
-   Show thumbnail, platform, format, created date, and status.
-   Allow reopening completed results.
-   Do not expose private storage keys or permanent URLs.

------------------------------------------------------------------------

## 22. API and frontend contract ownership

-   Keep request/response types in a versioned contracts package
    published from the backend repository and consumed by the frontend
    submodule.
-   Keep platform presets in that shared package, but the backend is
    authoritative and validates every selection.
-   Generate OpenAPI documentation from Elysia where practical.
-   Avoid duplicating business rules in frontend code.
-   The frontend may use shared types for developer experience but must
    treat API responses as runtime-untrusted data.
-   Version all public endpoints under `/api/v1`.
-   Return consistent errors and request IDs.
-   Never import across the submodule boundary with relative paths; the
    contracts package is the only shared code channel.

------------------------------------------------------------------------

## 23. Operational runbook

Document these procedures in the repository README or an operations
document:

**Backend restart** - Confirm Railway service health. - Check whether a
job was left `RUNNING`. - Confirm lease recovery requeues it or marks it
failed.

**Queue backlog** - Inspect queued/running/failed counts. - Inspect
oldest queued job age. - Check worker logs and storage connectivity. -
Do not blindly delete jobs.

**Failed generation** - Search logs by `generationId` and `jobId`. -
Inspect sanitized `error_code` and attempt count. - Determine transient
vs permanent failure. - Retry only through a controlled operation or new
generation.

**Bucket upload failure** - Check presigned URL expiry, CORS, required
content type, bucket endpoint, and credentials. - Verify object metadata
from the backend. - Do not mark an asset uploaded based only on frontend
success.

**Rate-limit false positives** - Inspect operation, window, principal
hash, and reset time. - Do not disable all rate limiting to resolve a
single-user issue.

**Database migration** - Back up data. - Run migration once. - Verify
schema and API health. - Roll forward with a corrective migration where
possible.

------------------------------------------------------------------------

## 24. Definition of done

The project is complete when all of the following are true:

-   [ ] Parent repository contains `backend/` and `frontend/` as git
    submodules, each pointing at a pushed commit in its own repository.
-   [ ] Next.js frontend deployed to Vercel from the `frontend/`
    submodule repository.
-   [ ] Bun/Elysia API deployed to Railway from the `backend/` submodule
    repository.
-   [ ] Railway PostgreSQL configured and migrated.
-   [ ] Railway private Buckets configured.
-   [ ] Demo authentication works.
-   [ ] Direct browser-to-bucket image upload works.
-   [ ] Upload progress is visible.
-   [ ] Upload completion is verified by backend.
-   [ ] All five platform presets work.
-   [ ] Generation is persisted and enqueued transactionally.
-   [ ] Background worker runs inside the same backend service.
-   [ ] PostgreSQL job claiming is concurrency-safe.
-   [ ] Job retries and stale-job recovery work.
-   [ ] Sharp output has exact target dimensions.
-   [ ] Frontend polls job status and stops at terminal state.
-   [ ] Preview and download use short-lived signed URLs.
-   [ ] Rate limits and quotas are enforced.
-   [ ] Ownership checks prevent cross-user access.
-   [ ] Structured logs include request, asset, generation, and job
    identifiers.
-   [ ] Health checks work.
-   [ ] Tests cover critical success and failure paths.
-   [ ] README includes local setup, deployment, environment variables,
    and limitations.
-   [ ] Demo video and live URL are ready for assessment.

------------------------------------------------------------------------

## 25. Instructions to the autonomous coding agent

1.  Read this document fully before editing code.
2.  Inspect the existing repository before creating or replacing files.
3.  Preserve existing working code unless a change is required by this
    architecture.
4.  Respect the repository topology in section 4: `backend/` and
    `frontend/` are separate git repositories mounted as submodules.
    Never move application code into the parent repository, and never
    commit a submodule pointer to an unpushed commit.
5.  Implement one milestone at a time in the order specified.
6.  Do not silently substitute infrastructure:
    -   Railway Buckets, not S3/Cloudflare/Supabase Storage.
    -   Railway PostgreSQL, not Supabase.
    -   Bun + Elysia API.
    -   Same-process background job loop.
    -   PostgreSQL-backed queue, not Redis or Graphile Worker.
    -   Vercel frontend.
7.  Verify current Railway Bucket S3-compatible connection details and
    presigned URL behavior from Railway's current
    documentation/dashboard. Do not guess endpoint or credential
    variable names.
8.  Verify browser CORS behavior for direct presigned PUT uploads.
9.  Do not put secret values in frontend environment variables.
10. Do not implement video or AI generation in this MVP.
11. Do not claim a feature works until it has been run and tested.
12. After each milestone, report:
    -   Files created/changed.
    -   Design decisions made.
    -   Commands executed.
    -   Tests and results.
    -   Known issues and next milestone.
13. If a required external credential or Railway resource is
    unavailable, implement a clean interface and local test adapter,
    document the missing configuration, and continue with other work.
14. Avoid speculative abstractions. Keep the implementation small,
    typed, observable, and testable.
15. Do not weaken authentication, ownership checks, rate limits, or file
    validation to make the demo pass.

------------------------------------------------------------------------

## 26. Final architecture summary

``` text
Repository topology:
  Parent repository (this repo)
  backend/  -> git submodule, independent repository
  frontend/ -> git submodule, independent repository
  Shared contracts distributed as a versioned package, not a workspace

Frontend:
  Next.js + React + TypeScript
  Hosted on Vercel
  Deployed from the frontend/ submodule repository

Backend:
  Bun + Elysia + TypeScript
  Hosted on Railway
  REST API + same-process background job loop
  Deployed from the backend/ submodule repository

Database:
  Railway PostgreSQL
  Drizzle ORM
  Application data + durable jobs + rate-limit counters

Storage:
  Railway Buckets
  Private original and generated media

Processing:
  Sharp
  Image resize/crop only
  Simulated/AI generation is not part of this MVP

Queue:
  PostgreSQL jobs table
  FOR UPDATE SKIP LOCKED
  Retry + lease + stale-job recovery

Frontend status:
  Browser upload progress events
  REST polling every ~2 seconds for generation status

Security:
  Demo-only server-issued session
  Ownership checks
  Signed URLs
  PostgreSQL rate limiting
  Daily and concurrency quotas
  File type/size/pixel validation

Observability:
  Structured JSON logs
  Request/generation/job correlation
  Metrics
  Optional Sentry + OpenTelemetry

Deployment:
  Vercel frontend (from frontend/ submodule repo)
  Railway API + PostgreSQL + Buckets (from backend/ submodule repo)
  Parent repository is orchestration and documentation only
```

**MVP end-to-end milestone:**

> Enter an access code → receive a JWT → upload an image directly to Railway Bucket →
> choose Instagram/TikTok/YouTube preset → create generation →
> PostgreSQL job is claimed by the background loop in the Elysia process
> → Sharp resizes/crops the image → output is uploaded to Railway Bucket
> → frontend polls status → user previews and downloads the result.
------------------------------------------------------------------------

## 27. Implementation status (living document)

> **Keep this section current.** Whenever agent implementations, module
> boundaries, or operational behaviour change, update it here rather than
> letting this document drift from the code.

**TypeScript version note:** `backend/tsconfig.json` deliberately has no
`baseUrl`. TypeScript 6.0 (and the 6.0 nightly shipped with the VS Code
TypeScript extension) reports `TS5101` against it, and it stops functioning in
7.0. `paths` resolves relative to the tsconfig since TS 4.4, so the `./`-prefixed
mappings are correct without it. Do not reintroduce `baseUrl`, and do not paper
over the diagnostic with `ignoreDeprecations`. Verified against TypeScript
5.9.3, 6.0.0-dev and the TS 7 native preview.

**Deployed:** 2026-11-05 — both halves are live and the full flow was
exercised in a real browser:

- Frontend: <https://blueberrylabs-frontend.vercel.app> (Vercel)
- Backend: <https://blueberrylabs-backend-production.up.railway.app> (Railway)
- PostgreSQL and two private Railway Buckets

Verified in the browser: demo login, direct upload to the Railway bucket,
generation, preview from a signed URL, download (27,975-byte JPEG) and
history with a signed thumbnail.

**Last verified:** 2026-11-05 — `lint`, `typecheck`, and 97 tests pass
(82 backend, 10 frontend) from a cold start with automatic PostgreSQL
provisioning; the full browser flow was exercised against a running stack.
All three CI pipelines are green (7 jobs). The production Docker image was
built with `--no-cache` and run against `postgres:16`, completing the full
upload → generate → download flow.

### 27.1 Milestone status

| Sprint | Scope | Status |
| --- | --- | --- |
| 0 | Repositories, runtime foundation, env validation, logging | Done |
| 1 | Database, demo auth, rate limiting, quotas | Done |
| 2 | Direct upload, presigned URLs, verification | Done |
| 3 | PostgreSQL queue, Sharp worker, retries, recovery | Done |
| 4 | Frontend upload/preset/polling/history UX | Done |
| 5 | Observability, hardening, deployment assets, CI | Done (see 27.7 for external gaps) |

### 27.2 Deviations from the original plan, and why

1. **`backend/contracts` replaces a published npm package.** The contracts are
   still one authoritative module and are still distributed as a versioned
   tarball, but packing happens locally (`scripts/sync-contracts.sh` →
   `frontend/vendor/`) instead of via a registry. This keeps the submodule
   boundary intact without requiring publish credentials.
2. **A `filesystem` storage driver exists alongside the S3 adapter.** Required by
   section 25.13 (no external credentials available). It mirrors the presigned
   URL contract exactly (`/__storage/:bucket/*?expires&signature`) and is
   **never** the production driver; `STORAGE_DRIVER=s3` is the default in
   `.env.example`.
3. **Each demo login creates a distinct principal.** Section 5.2 permits a shared
   demo principal, but per-login principals make ownership isolation real and
   testable (see `test/integration/auth.test.ts`).
4. **`@elysiajs/openapi` serves docs at `/api/docs`.** Named `openapi` in v1.x of
   the plugin; the route is unchanged from the plan's intent.
5. **The request context is stored per-`Request` (WeakMap + AsyncLocalStorage).**
   Elysia v1 has no `declare()` singleton hook, so `derive()` would have coupled
   every module to the composition root. Hooks read `getContext(request)`.
6. **The `Origin` check runs globally in `onBeforeHandle`.** It is not left to
   individual routes; a per-route check was measurably skippable on
   unauthenticated paths such as logout.
7. **Auth is a bearer JWT, not a cookie.** The token is verified statelessly
   (signature + `exp`) and then against its `auth_sessions` row, so logout is
   immediate. There is no CSRF token because browsers never attach an
   `Authorization` header on their own (section 5.2).
8. **`Worker.runOnce()` exists for deterministic testing and operational drain.**
   The production path is still the polling loop.

### 27.3 Backend module layout as built

```
backend/
├── contracts/                     # @social-resizer/contracts (authoritative)
│   └── src/{presets,errors,status,api,index}.ts
├── src/
│   ├── app.ts                     # composition root: CORS, docs, context, errors, metrics
│   ├── server.ts                  # boot probe, listen, worker, cleanup, graceful shutdown
│   ├── config/env.ts              # zod-validated environment (fail fast)
│   ├── db/{client,schema,migrate}  # drizzle + checked-in migrations
│   ├── middleware/                # auth, origin, rate-limit, request-context, error-handler
│   ├── modules/                   # auth (jwt.ts, session.ts, routes.ts), uploads(+assets),
│   │                              # generations, health
│   ├── cli/                       # issue-access-code.ts (operator tool)
│   ├── queue/                     # worker, claim-job, retry, handlers/process-image
│   ├── services/                  # storage/{interface,railway-bucket,filesystem},
│   │                              # image/sharp-processor, generation/{service,quota}
│   └── observability/             # logger, metrics, cleanup, error-tracking, tracing
├── test/{unit,integration}/       # bun:test; integration boots its own PostgreSQL
├── Dockerfile, docker-entrypoint.sh, drizzle.config.ts
```

Notable additions beyond the planned tree: `services/generation/quota-service.ts`
(daily + concurrency quotas and ownership checks live in one place),
`services/storage/local-routes.ts`, `observability/cleanup.ts`,
`middleware/origin.ts`, `modules/auth/jwt.ts`, and `cli/issue-access-code.ts`.

### 27.4 Behavioural contracts worth knowing before changing code

**Job claiming** — a single statement, executed with `FOR UPDATE SKIP LOCKED`:

```sql
WITH candidate AS (
  SELECT id FROM jobs
  WHERE status = 'QUEUED' AND run_at <= now() AND type = $2
  ORDER BY priority DESC, created_at ASC
  FOR UPDATE SKIP LOCKED
  LIMIT 1
)
UPDATE jobs SET status='RUNNING', locked_at=now(), locked_by=$1,
                attempts=jobs.attempts+1, updated_at=now()
WHERE jobs.id IN (SELECT id FROM candidate)
RETURNING id, type, payload, attempts, max_attempts;
```

**Retry schedule** (`computeRetry`): `base * 3^(attempt-1) ± jitter`, so
~5 s then ~15 s, terminal on attempt 3. `JobError.retryable=false` skips retries
entirely — used for corrupt images, unsupported presets, and missing sources.

**Leases** are refreshed every `leaseSeconds / 3`. `recoverStaleJobs(leaseSeconds)`
requeues or fails expired `RUNNING` jobs and reconciles the generation out of
`PROCESSING`, so no generation can be stuck in a non-terminal state after a crash.

The recovery sweep must be **one transaction** and must count only transitions
that actually matched a row (`UPDATE … RETURNING id`). An earlier implementation
ran in autocommit and counted intent, so six concurrent sweeps over ten stale
jobs reported 60 recoveries instead of 10 — inflating `jobs_recovered_total` and
risking the wrong number of generations being reconciled. Two safeguards now
cover it independently (transaction-scoped `SKIP LOCKED` locks, and
outcome-based counting), with a regression test in
`test/integration/queue.test.ts`.

**Idempotency** is layered: a unique `(user_id, idempotency_key)` partial index,
a payload comparison that returns `409 IDEMPOTENCY_CONFLICT` on mismatch, an
early return for terminal generations in the handler, and a deterministic output
object key per generation so a redelivered job overwrites instead of duplicating.

**Rate limiting** is one atomic `INSERT … ON CONFLICT DO UPDATE` inside the
`consume_rate_limit(key, limit, window)` SQL function. Keys are SHA-256 of
`secret:operation:dimension:value`, so raw IPs and user ids never reach the
database. Rules are configured in `middleware/rate-limit.ts::rules()`.

**Quotas** are checked inside the same transaction that inserts the generation,
under `pg_advisory_xact_lock(hashtext('generation-quota:<userId>'))`, so
simultaneous requests cannot both slip under the limit.

**Image output** — `fit: cover` + centre, `rotate()` before crop, JPEG for opaque
sources, PNG when alpha is present (`IMAGE_PRESERVE_TRANSPARENCY`), flattening
only onto a configured background colour, metadata stripped, `limitInputPixels`
mapped to the specific `IMAGE_TOO_LARGE` error.

### 27.5 Frontend module layout as built

```
frontend/
├── app/{layout,globals.css}
├── app/login/page.tsx
├── app/(app)/{layout,page}.tsx
├── app/(app)/generations/[id]/page.tsx
├── app/(app)/history/page.tsx
├── components/{session,upload,presets,generation,ui}/
├── hooks/{use-upload,use-generation-polling}.ts
├── lib/{api-client,auth,upload,validation}.ts
└── vendor/social-resizer-contracts-1.0.0.tgz
```

`useUpload` models the phases from section 11.3 as distinct states
(`SELECT_IMAGE → REQUESTING_UPLOAD → UPLOADING → VERIFYING_UPLOAD →
READY_TO_GENERATE`, plus `FAILED`), so browser upload progress is never
conflated with server processing progress.

`useGenerationPolling` enforces every rule in section 11.2: poll only while
non-terminal, single in-flight request, abort on unmount, 5 s cadence after 30 s,
10 s when the tab is hidden with an immediate refresh on return, exponential
backoff honouring `Retry-After`, and fatal stop on 401/404.

### 27.6 CI and deployment configuration

| Artifact | Repository | Purpose |
| --- | --- | --- |
| `.github/workflows/ci.yml` | parent | Submodule integrity, no application source in parent, no application dependencies in parent `package.json`, pinned-commit builds of both sides, contracts tarball content drift |
| `.github/workflows/ci.yml` | backend | Lint, typecheck, test against a `postgres:16` service; Docker image build |
| `.github/workflows/ci.yml` | frontend | Lint, typecheck, test, production `next build` |
| `railway.json` | backend | Dockerfile builder, `/health/ready` probe, restart-on-failure |
| `vercel.json` | frontend | Next.js preset, Bun install/build, `NEXT_PUBLIC_API_BASE_URL` from env |
| `.tool-versions` | both | Pins Bun 1.3.13 for local tooling and CI |

The contracts drift check compares per-entry sha256 of file **content**. A naive
comparison of `tar -t` output reported a match after a real source change and
was replaced. `scripts/sync-contracts.sh` deletes `frontend/bun.lock` before
reinstalling and then performs a `--frozen-lockfile` install, because
`bun install` alone silently reuses a stale integrity hash when `node_modules`
already exists.

Three defects were found by running CI rather than assuming it worked, and are
recorded here so they are not reintroduced:

1. A duplicated `token:` key made the parent workflow invalid, so it never
   started.
2. The Dockerfile installed dependencies with `--production`, which omits the
   `typescript` binary the contracts build needs; this was hidden locally by a
   cached layer.
3. The committed `frontend/bun.lock` carried a stale integrity hash for the
   vendored tarball, which only fails on a clean checkout.

### 27.7 External gaps (require credentials/infrastructure)

These are intentionally unimplemented rather than faked:

| Item | State |
| --- | --- |
| Railway Bucket presigned PUT/GET against live buckets | **Verified live** — presigned PUT 200, presigned GET 200, objects present in both buckets |
| Vercel ↔ Railway cross-site auth | **Resolved** — replaced cookies with bearer JWTs, so cross-site cookie policy no longer applies (see 5.2 and 27.8) |
| Sentry | Seam only (`SENTRY_DSN`); wiring the SDK is a follow-up |
| OpenTelemetry | Documented partial: correlation ids always emitted, OTLP exporter not attached |
| Multi-replica metrics | `/metrics` is per process; scraping must be per replica |

### 27.8 Railway deployment notes

Live resources (project `blueberrylabs`, environment `production`):

| Resource | Detail |
| --- | --- |
| `blueberrylabs-backend` | Dockerfile build, `/health/ready` probe, public domain |
| `Postgres` | `postgres-ssl:18`, referenced via `${{Postgres.DATABASE_URL}}` |
| `media-originals` | bucket `media-originals-rhkdzcsji`, region `iad` |
| `media-generated` | bucket `media-generated-iklbv0b92`, region `iad` |

Three things about Railway Buckets that the code must respect, each found by
deploying rather than by reading docs:

1. **Credentials are per bucket.** A key pair for `media-originals` returns
   `403 AccessDenied` against `media-generated`. The adapter builds one S3
   client per bucket.
2. **Addressing is virtual-host.** `railway bucket credentials` reports
   `urlStyle: virtual-host`; path-style signing yields URLs the bucket rejects.
   `RAILWAY_BUCKET_FORCE_PATH_STYLE` defaults to `false`.
3. **Bucket names are suffixed.** The dashboard name `media-originals` is not
   the S3 bucket name; use the `bucketName` field from
   `railway bucket credentials`.

CORS is not exposed by the CLI. It was applied with `PutBucketCors` (allowed
origins `https://blueberrylabs-frontend.vercel.app` and
`http://localhost:3000`, methods `PUT,GET,HEAD`) and verified with an `OPTIONS`
preflight returning `Access-Control-Allow-Origin`. Add any new frontend origin
to both buckets, or browser uploads will be blocked.

### Cross-site auth: why cookies were replaced

`*.vercel.app` and `*.up.railway.app` are **different registrable domains**, so
the browser treats every API call as cross-site. With the original cookie
session and the default `SameSite=Lax`, the session cookie was never sent and
every authenticated request returned 401 — with no error at login time, which
made it look like a backend bug. Working around it required
`SameSite=None; Secure` plus a CSRF token read from the response body, because
the API's `bl_csrf` cookie was unreadable from the frontend's origin.

That whole class of problem is gone now: the credential is a bearer JWT in an
`Authorization` header, which the browser never attaches automatically. There
are no cookies, no `SameSite` policy, and no CSRF token. See section 5.2 for the
reasoning and the `localStorage` XSS tradeoff.

Production therefore sets only:

```env
JWT_SECRET=<openssl rand -base64 48>
JWT_TTL_HOURS=24
```

`railway up` needs `--path-as-root`; without it the archive is prefixed by the
project directory and Railway falls back to Railpack, which fails with
"No start command detected". `railway.toml` is committed for this reason.

### 27.9 Verification commands

```bash
bun run verify          # lint + typecheck + test, both submodules
bun run contracts:sync  # after changing backend/contracts (self-verifies)
cd backend && bun test  # boots a throwaway PostgreSQL if none is configured

# Issue a login code
cd backend && bun run auth:code -- --label "alice"

# Reproduce what CI does for the container:
cd backend && docker build --no-cache -t blueberrylabs-backend:ci .
```

### 27.10 JWT auth: implementation map and test coverage

Files that make up the auth flow, in the order a request touches them:

| File | Role |
| --- | --- |
| `backend/src/modules/auth/jwt.ts` | HS256 sign/verify. Fixed algorithm, constant-time compare, `exp` enforced. |
| `backend/src/modules/auth/session.ts` | `loginWithCode`, `authenticate`, `revokeSession`, `createAccessCode`, `createDemoUserWithCode`, `deleteExpiredSessions`. |
| `backend/src/middleware/auth.ts` | `bearerToken()` parses the header; `requireSession()` verifies and populates the request context. |
| `backend/src/modules/auth/routes.ts` | `POST /login`, `GET /session`, `POST /logout`. |
| `backend/src/cli/issue-access-code.ts` | Operator CLI (`bun run auth:code`). |
| `backend/src/db/schema/index.ts` | `access_codes`, `auth_sessions`. |
| `backend/src/db/migrations/0002_jwt_auth.sql` | Creates both tables and their indexes. |
| `backend/src/db/migrations/0003_cleanup_jwt_auth.sql` | Extends `cleanup_expired_rows()` to prune both. |
| `frontend/lib/api-client.ts` | `getToken`/`setToken`/`readAuthToken`; attaches `Authorization` on every request. |
| `frontend/lib/auth.ts` | `loadSession`, `login`, `endSession`. |
| `frontend/components/session/session-provider.tsx` | `signIn(code)`, `signOut()`. |
| `frontend/app/login/page.tsx` | Access-code form. |

Test coverage added for this flow:

| Suite | What it pins |
| --- | --- |
| `backend/test/unit/jwt.test.ts` | Round-trip, TTL, HS256 header, wrong secret, tampered payload, expired, `alg:none` downgrade, malformed input, missing claims. |
| `backend/test/integration/auth.test.ts` | Code → token, 24h TTL, separator/case normalisation, unknown/expired/revoked code, single-use, **8 concurrent redemptions yield exactly 1 token**, raw code never stored, schema validation, Bearer accepted, missing/malformed/forged/tampered/wrong-secret/expired token rejected, deleted session row rejected, logout revokes immediately, logout does not affect sibling sessions, origin allow-list. |
| `frontend/test/token-storage.test.ts` | Read/write/clear, SSR returns `null`, storage that throws does not crash. |

Live end-to-end verification (14 checks, all passing) exercised the real HTTP
server against a real PostgreSQL database: login, 24h TTL, Bearer accepted,
no-token 401, tampered-signature 401, garbage-token 401 on a protected route,
valid token 200 on a protected route, code reuse 401, logout 204, token dead
after logout, raw code absent from the database, and CORS advertising
`Authorization`.

**Deliberate non-goals** (documented rather than hidden): no refresh token, no
token rotation, no per-device session listing, no rate limit on `/auth/session`
beyond the general limiter. A 24-hour token with immediate revocation was the
requested behaviour.
