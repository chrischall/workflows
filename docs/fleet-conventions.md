# Fleet conventions

The technical conventions shared across the `*-mcp` repos. This is the
canonical home: link here from a repo's `CLAUDE.md` rather than copying a
section into it. Repo `CLAUDE.md` files should carry only what is true of that
repo and nowhere else.

Policy (PR titles, merge/label rules, auto-review follow-ups) lives in
`~/.claude/CLAUDE.md`, not here. CI pipeline mechanics live in this repo's
`README.md`.

Most of what follows was learned the hard way in one repo and is recorded here
so the next repo doesn't relearn it. Attributions name where it was found.

---

## Releasing and publishing

**A green tag does not mean a green publish.** The release job and the publish
job are separate. `ofw-mcp` v2.6.0, v2.6.1 and v2.6.2 were all tagged with
GitHub Releases created while npm sat at 2.5.0 — three publish jobs failed
silently and the releases looked done. **After any release, confirm with
`npm view <pkg> version`.** To recover, re-run the failed `release-please.yml`
from the Actions UI: the npm step is idempotent, MCP Registry publish is
idempotent in practice, and `gh release upload --clobber` overwrites.

**A repo may ship several skills; they all publish.** `mcp-publish`
auto-discovers a root `SKILL.md`, else every `skills/*/SKILL.md`, packaging each
as its own `<slug>-<version>.skill` and publishing each to ClawHub under its own
slug. A single skill keeps the repo-level name, so those artifacts are unchanged.

`skill-path` is now only for deliberately publishing ONE skill out of several —
it is no longer required to avoid a failure. Repos that pinned it back when more
than one skill was a hard error (`ofw-mcp`, `resy-mcp`, `honeybook-mcp`,
`zola-mcp`) are publishing just the pinned skill and can drop the input to ship
the rest.

That hard failure was expensive: it exited before the npm publish, so a repo
that grew a second skill kept tagging releases that shipped nothing. zola-mcp
tagged 1.6.0, 1.6.1 and 1.6.2 while npm stayed at 1.5.0.

**The MCP Registry caps `server.json`'s `description` at 100 characters.** Over
that, `mcp-publisher publish` fails with HTTP 422 (`validation failed: expected
length <= 100, location: body.description`). The other description fields
(`manifest.json`, `.claude-plugin/plugin.json`,
`.claude-plugin/marketplace.json`) have no published length constraint. Check
before committing a description change:

```sh
jq -r '.description | length' server.json
```

**`--provenance` requires a public source repo.** It 422s on a private one, and
trusted publishing would attach it automatically — which is why a repo that
must stay private publishes with a classic npm token instead
(`musescore-mcp`).

**On an `ENEEDAUTH` publish failure, do not strip `_authToken` from `.npmrc`.**
That removes the registry entry npm needs to even attempt Trusted Publisher.
Strip only `always-auth` (deprecated in npm 11) and leave
`_authToken=${NODE_AUTH_TOKEN}` intact with `NODE_AUTH_TOKEN` unset, so the
placeholder is empty and npm takes the OIDC path. The real culprits are a
workflow-filename mismatch with the Trusted Publisher config on npmjs.com, a
missing `id-token: write` permission, or TP trust never having been configured.
(`fetchproxy` — an earlier version of its own doc described stripping it as the
fix; that was the bug.)

**`.claude-plugin/marketplace.json` is regenerated downstream.** The
`mcp-marketplace` catalog is produced by its `scripts/regen.py` reading each
repo's own file — a version bump here doesn't reach the marketplace until that
regen runs. Plugin `name`s must be unique across the whole catalog.

## Versioning

release-please owns every version. Never hand-bump, never hand-tag.

**Register every version-bearing file in `release-please-config.json`'s
`extra-files`, and tag the line with `// x-release-please-version`.** An
unregistered file drifts silently — release-please trusts its own bump logic
and there is no in-workflow guard. `ioffice-mcp` found
`.claude-plugin/marketplace.json` → `plugins[].source.version` lagging a full
minor version this way; that field is worth auditing repo by repo.

**Add the drift guard.** `versionSyncTest` from `@chrischall/mcp-utils/test`
fails CI when a `x-release-please-version` annotation diverges from
`package.json`. Repos with it: `opentable`, `setlist`, `skylight`, `ioffice`.
Repos without it are running unguarded.

Prefer a single `src/version.ts` over scattering the constant. Repos that did
this (`booli`, `etix`, `easytable`, `setlist`) don't have a "version appears in
SEVEN places" list to keep accurate — and the ones that do have miscounted
their own lists more than once.

## Bundling and the `.mcpb`

**The `.mcpb` ships no `node_modules`.** Everything follows from that.

**Externalized ⇒ the import must be lazy.** If a dependency is in the bundle
script's `--external` list, import it with `await import()`, never at the top
level, or the bundled server crashes at load. If it's bundled in, an eager
static import is fine. Both halves of this rule are live in the fleet and read
as contradictory out of context: `artsonia` externalizes
`@chrischall/mcp-utils/fetchproxy` and requires lazy; `booli` bundles
`@fetchproxy/server` and uses eager imports. The invariant is *externalized ⇒
lazy*, not one or the other.

**Watch for deps that read data files relative to `__dirname`.** They work in
dev and break once bundled. `musescore-mcp` imports PDFKit's *standalone* build
(`pdfkit/js/pdfkit.standalone.js`), which embeds font data in a virtual FS; the
bare `pdfkit` entry reads `.afm` files from disk on construction and crashes in
any environment without an adjacent `node_modules`.

**Add `tests/server-boot.test.ts`.** Spawn the real `dist/bundle.js` with no
`node_modules` and assert the `initialize` + `tools/list` handshake. It is the
only test that catches an eager-import crash or a broken bundle, and several
repos rely on the deferred-config pattern *specifically so* the install-time
`tools/list` probe succeeds without ever testing that it does. Precedent:
`setlist`, `etix`, `tripadvisor`, `musicbrainz`.

## stdio

**stdout is the JSON-RPC channel.** A stray write corrupts the framing.

Node routes `console.log`, `console.debug` **and** `console.info` to stdout —
`debug`/`info` are the ones people miss. Use `console.error` / `console.warn`.
`fetchproxy` PR #68 shipped a `console.debug` keep-alive log that wedged stdio
in the field. In Swift, the same rule applies to `print`.

Load dotenv with `quiet: true` for the same reason.

## Environment variables

**Treat blank, `"undefined"`, `"null"`, and unsubstituted `${FOO}` placeholders
as unset.** This is the canonical defense against MCP hosts forwarding a
`.mcp.json` env block through unexpanded — Claude Desktop does this for unset
`user_config` refs. Use `readEnvVar` from `@chrischall/mcp-utils`. The `.mcpb`
variant is `${user_config.xxx}`.

**Defer the missing-config error; don't throw at startup.** Construct the
client as a module singleton that stores a `configError` instead of throwing,
and re-raise at first tool call. This lets the server boot and answer the
host's install-time `tools/list` probe with no credentials configured. Don't
"fix" it by throwing at startup.

**Cache a genuine missing-config error as permanent, but never cache a
transient one.** A network/5xx/rate-limit failure must retry on the next call;
only a real config error should be sticky. Caching a transient failure as
permanent is the bug this distinction prevents (`skylight`'s
`isPermanentError`; `artsonia`'s `CONFIG_ERROR_MARKER`).

**Never let a credential reach an error message.** `formatApiError` /
`errorResult` in `@chrischall/mcp-utils` run upstream bodies through
`redactSecrets` *before* truncating. Repos with hand-rolled clients that bypass
`createApiClient` are exactly the ones that can regress this. Better still,
keep the key out of the URL entirely, so cache keys and error strings are
key-free by construction (`tripadvisor`).

## Writes

**A 302, a 200, or an echo of your own payload is not proof a write
persisted.** Re-read authoritative state and compare — containment, not
equality. Report `verified: true/false` honestly rather than assuming.
`artsonia` 302s even on payloads it silently drops. OFW's update-in-place
endpoint silently no-ops on subsequent updates *while echoing the posted body
back*, which is why `ofw_save_draft` creates a fresh draft and deletes the old
one instead.

**Read-after-write can return a stale cached body.** Observed independently in
`musicbrainz` (`/ws/2` GETs are cached — bust with a nonce query param) and
`vibo` (a section note read back the old value immediately after a write that
had applied). When verifying a write by re-reading, expect staleness; don't
conclude the write failed from a single immediate read.

**Validate downloaded bytes before writing them.** A paywalled or gated
resource can serve an HTML error page with HTTP 200 that a download API saves
happily. Magic-byte-check, delete the temp, and throw a typed error rather than
writing HTML as a `.pdf` and reporting success (`musescore`).

**Prefer structural gating to runtime checks.** A write mode that simply
*doesn't register* the gated tools cannot be invoked by any host setting or
injected instruction. A runtime `confirm: true` flag is defeatable by an
instruction that passes `confirm: true`. Fail closed on unrecognized mode
values. (`ofw`'s `OFW_WRITE_MODE`.)

**Sandboxed hosts often can't read files under `~/.cache`.** Default downloads
to `~/Downloads/<repo>/`, and offer an inline mode returning bytes as MCP
content blocks.

## Transport archetypes

Name these consistently — the fleet currently uses five names for two patterns,
and `zillow` and `fetchproxy` use "Pattern A" to mean *opposite* things.

- **Pattern A — every call rides through fetchproxy.** Use when the target
  revalidates each request at the session/edge level, so a token or cookie
  lifted out of the browser won't work from Node. (`zillow`, `redfin`,
  `homes`, `hemnet`.)
- **Pattern B — one bootstrap call through fetchproxy, then direct fetch from
  Node.** Use when the site has an endpoint that hands back a usable token, and
  no per-request edge revalidation. (`resy`, `ofw`, `signupgenius`, `zola`.)

The decision rule: **does the edge revalidate every request?** If yes, A. If
no, B — and don't add a transport layer B doesn't need (`signupgenius` removed
one it didn't).

**Anti-bot walls fingerprint the HTTP client itself (TLS/JA3), not the
headers.** A cookie captured from the browser and replayed from Node gets 403'd
while the identical same-origin fetch inside the signed-in tab returns 200
(`alltrails`, verified live; also `booli`, `hemnet`, `musescore`). This is the
load-bearing justification for the whole fetchproxy design.

**So don't reach for IP rotation, TLS impersonation, cycletls,
curl-impersonate, or Playwright.** They replace the user's own session with a
stand-in identity, which defeats the design and adds surface. Detect the wall
and surface an actionable error instead.

**Detect interstitials with a size guard.** Match the marker *and* a body-size
bound (e.g. `captcha-delivery` AND body < 80 KB) so a large SSR page that
merely mentions the string doesn't false-positive. Never body-match a string
that appears in normal signed-in pages — `zillow` deliberately does not match
`/user/login`, because every signed-in page has a "Sign in" nav link.

**A 2xx non-JSON body is an interstitial, not a parse bug.** Surface it as an
actionable error, never a bare `SyntaxError`.

**Multi-domain fetchproxy needs `storageDomain`.** A repo declaring
`domains: ['x.com', 'y.com']` that calls `readLocalStorage` must say which
declared domain to read from or `resolveBaseDomain` throws. Tab matching for
storage reads is host-or-subdomain (`isTabUrlOnOrigin`), not strict prefix.
Note `ensureDomainTab` only opens a tab for the *first* declared domain.

**The declared cookie key list is the security boundary, not HttpOnly status** —
`chrome.cookies.get` sees HttpOnly cookies.

**Changing a capability requires re-pairing the extension.** Until the user
re-pairs, the new capability path errors.

## Testing

**CI mocks the client, so upstream endpoint retirement never surfaces in
tests.** `alltrails` lost a whole endpoint family (retired upstream) and the
breakage was invisible to a green suite. Every repo in the fleet mocks at the
client boundary and has this blind spot. Date live-verification claims, and
give them an expiry action — "re-verify against a real 200 before treating as
confirmed" — rather than asserting them timelessly.

**Some bug classes are structurally unmockable and need a live probe.** Mocked
tests that assert an arg array pass while the live command fails: `gogcli-mcp`
found missing `--force` flags this way (gog gates destructive commands and the
runner injects `--no-input`). Probe with fake IDs — but beware commands that
resolve names via the API first, which error on fake IDs even when gated.

**Record what you tried and what failed, not just what works.** `skylight` tags
each write payload `LIVE-VERIFIED` / `(inferred)` / `not CI-live-verified` and
notes that the old `POST /complete` 404s and a prior `PATCH` was a silent
no-op. `vibo` keeps an explicit "not yet live-round-tripped" list. This is the
single highest-leverage documentation habit in the fleet.

**Vitest, two real traps** (`setlist`):

- An *eager* `mockRejectedValue` combined with a `beforeEach(mockClear)` loses
  vitest's settled-result tracking and mis-reports the rejection as unhandled,
  failing a test whose handler caught it correctly. Reject lazily:
  `mockRequest.mockImplementationOnce(() => Promise.reject(new Error(...)))`.
- A `beforeEach(() => mock.mockReset())` hook plus a fake-timer test whose mock
  returns a never-settling promise wedges into a 10s "Hook timed out" failure
  *after* the assertion passes. Reset inline at the top of the test instead.

**Exclude agent worktrees from test discovery.** Add `**/.claude/**` and
`**/dist/**` to `vitest.config.ts` excludes, or stale worktrees poison
discovery (`fetchproxy`).

**Don't register a tool that can't be driven by a mock client.** Keep tool
logic behind `fetchJson`/`fetchHtml` so tests can exercise it without a live
bridge (`zillow`, `homes`). `@fetchproxy/test-helpers` publishes a drop-in
`FetchproxyServer` mock for exactly this — several repos hand-roll it instead.

## Parsing

**Parse with an entity-decoding parser, never a regex.** homes.com SSR emits
`<script type="application/ld&#x2B;json">` — the literal `application/ld+json`
never appears in the raw bytes, so a naive regex silently misses every JSON-LD
block (`homes`).

**Check whether the page is hydrated client-side before writing DOM
selectors.** MuseScore's fetched HTML has no cards at all; the data is an
entity-encoded JSON store embedded in the markup (`musescore`).

**Never surface fields you incidentally parsed from a state blob** — bot-manager
fields (`bm_*`, `client_ip`, `ja3`/`ja4`) live alongside the real data. Target
only what you need.

**Schemas are `z.looseObject(...)` covering only the fields the code reads**,
validated at the call site via `parseLenient` from `@chrischall/mcp-utils`. Two
modes, split by boundary:

- **lenient** (default) on all read/sync paths: a mismatch warns to stderr and
  the raw response flows on through the existing `??` fallbacks, so a backend
  change degrades gracefully but never silently.
- **strict** at write boundaries: a mismatch throws, because proceeding on an
  unverifiable response risks deleting a draft or mis-reporting a send.

On drift, fall back to the raw response — never an empty projection.

## Rate limits

**One chokepoint, or the invariant is unenforceable.** MusicBrainz allows 1
req/s and 503s (and can IP-block) beyond it; every call funnels through one
serialized `createThrottle` queue spacing request *starts* ≥1.1s apart, so
concurrent tool calls line up instead of bursting. A code path that reaches
upstream outside the client bypasses the throttle entirely.

Throttle **proactively** rather than retrying reactively. Authenticated writes
against a website session can get the session invalidated by a burst — the
symptom is the first few succeeding and everything after failing (`setlist`).

Retry and fallback branches must key on `ApiError.status`, never on the error
message.

## Documenting an API you reverse-engineered

Keep a `docs/<VENDOR>-API.md` and record **where the knowledge came from**, so
the next drift is cheap to chase. `infinitecampus` names an external upstream
(`schwartzpub/ic_parent_api`) to re-check when the portal updates — the only
repo that does, and the most useful version of this habit.

Some cheap techniques worth knowing:

- **Param validation often runs before auth**, so the whole request surface can
  be verified without a key (`getyourguide`).
- **Validate a GraphQL document unauthenticated**: an auth error means the
  document is valid; a field-validation error means it isn't (`vibo`).
- **Apollo's `documentId` *is* the persisted-query sha256Hash** — read
  `window.__APOLLO_CLIENT__.queryManager` in DevTools rather than logging XHRs
  (`opentable`).
- Read the **live tab**, not the obfuscated bundle, for storage key names —
  `vibo` shipped `token`/`refreshToken` from the bundle when the real keys were
  `x-token`/`x-refresh-token`.
- Apollo's `@rest` directive is client-side; POSTing such a document to
  `/graphql` fails with `UnknownDirective 'rest'` (`onehome`).
