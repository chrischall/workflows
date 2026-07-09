# Onboarding a new app to Cloudflare Workers (OpenNext)

How to add a Next.js `web/` client to a fleet repo and ship it to Cloudflare
Workers via [OpenNext](https://opennext.js.org/cloudflare), deployed by the
reusable `reusable-cloudflare-deploy.yml` workflow.

Two live reference implementations:

- **[`allotmint-clients/web`](https://github.com/chrischall/allotmint-clients)** — has a KMP prebuild (`engine:build`) that needs a JDK, so its deploy passes `java-version`.
- **[`curtaincall/web`](https://github.com/chrischall/curtaincall)** — plain Next.js, no JVM toolchain, so `java-version` stays unset.

Copy from whichever matches your app.

## 1. Add the OpenNext scaffold to `web/`

Install the Cloudflare adapter and Wrangler as devDeps, and add `preview` /
`deploy` scripts:

```jsonc
// web/package.json
{
  "scripts": {
    "dev": "next dev",
    "build": "next build",
    "preview": "opennextjs-cloudflare build && opennextjs-cloudflare preview",
    "deploy": "opennextjs-cloudflare build && opennextjs-cloudflare deploy"
  },
  "devDependencies": {
    "@opennextjs/cloudflare": "^1",
    "wrangler": "^4"
  }
}
```

`open-next.config.ts` (repo `web/`):

```ts
import { defineCloudflareConfig } from "@opennextjs/cloudflare";

export default defineCloudflareConfig();
```

`wrangler.jsonc` (repo `web/`) — the worker name is the workers.dev subdomain;
add a `routes` block only when serving a custom domain (step 4):

```jsonc
{
  "$schema": "node_modules/wrangler/config-schema.json",
  "name": "my-app-web",
  "main": ".open-next/worker.js",
  "compatibility_date": "2025-03-01",
  "compatibility_flags": ["nodejs_compat"],
  "assets": { "directory": ".open-next/assets", "binding": "ASSETS" }
  // "routes": [{ "pattern": "app.example.com", "custom_domain": true }]
}
```

Wire the dev shim into `next.config.ts` so `next dev` sees the Cloudflare
bindings:

```ts
import type { NextConfig } from "next";

const nextConfig: NextConfig = {};
export default nextConfig;

import { initOpenNextCloudflareForDev } from "@opennextjs/cloudflare";
initOpenNextCloudflareForDev();
```

Add the OpenNext/Wrangler build artifacts to `web/.gitignore`:

```gitignore
# OpenNext / Cloudflare
/.open-next/
/.wrangler/
```

## 2. Add the `deploy-web.yml` stub

Copy [`templates/deploy-web.yml`](../templates/deploy-web.yml) to the app repo's
`.github/workflows/deploy-web.yml` and replace `__ACCOUNT_ID__` with the
Cloudflare account id (dashboard > Workers & Pages, or `wrangler whoami`; it is
non-secret). It calls
`chrischall/workflows/.github/workflows/reusable-cloudflare-deploy.yml@main`.

If the app assembles a JVM/Gradle artifact during install/prebuild (a shared KMP
engine, like AllotMint), uncomment `java-version: "21"` in the stub so a Temurin
JDK is set up before `npm ci`. Plain Next.js apps (CurtainCall) leave it out.

Release-please chains this stub after a release is cut (`workflow_call`);
`workflow_dispatch` is the manual re-deploy escape hatch.

## 3. Add the repo secret + account id

- **`CLOUDFLARE_API_TOKEN`** — a repo Actions secret (Settings > Secrets >
  Actions). Mint it in the Cloudflare dashboard (My Profile > API Tokens) with
  the **Edit Cloudflare Workers** template scoped to the target account. This is
  the only required secret; the deploy fails with an auth error without it.
- **account id** — the `__ACCOUNT_ID__` value in the stub (non-secret).

## 4. workers.dev vs custom domain

- With only a worker `name` in `wrangler.jsonc`, the app is served at the free
  `https://<name>.<your-subdomain>.workers.dev` URL.
- To serve a custom domain, add a `routes` entry pointing at a zone you own on
  this Cloudflare account (see the commented `routes` line above), then
  redeploy. This is a `wrangler.jsonc` change in the app repo — not a workflow
  input.

## GOTCHA: OAuth redirect URIs are domain-bound

> **Any "Sign in with Apple / Google" (or other OAuth) flow is bound to the
> exact host it was registered under.** A new Workers deploy that changes the
> host — the first `*.workers.dev` URL, or a later cutover to a custom domain —
> will break OAuth until you add the new origin + redirect URI to the provider
> configuration (Apple Developer Services ID / Google OAuth client). Update the
> provider **before** pointing users at the new host.

Also note the **build-time `NEXT_PUBLIC_*`** caveat: those vars are inlined into
the client bundle at build time on the CI runner, so a value set only as a
Cloudflare Worker secret/var is invisible to the already-built bundle. Expose
build-time public vars to the build step; keep server-only secrets in Cloudflare
(`wrangler secret put`), never in the client bundle.
