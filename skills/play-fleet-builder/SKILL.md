---
name: play-fleet-builder
description: "Ship a nullnet app to Google Play — adding an app to the existing fleet, porting an existing iOS app onto a shared Kotlin Multiplatform core, or building Android alongside iOS from the start. Covers the one-way doors (package name, signing key, versionCode floor), the fleet's SHARED upload keystore and service account, Play App Signing, the R8/kotlinx.serialization trap that ships silently broken builds, adaptive icons, the Play Console bootstrap the API cannot do for you (and its 404/403/200 status ladder), and deploy-play.yml. Companion to mcp-fleet-builder."
---

# Shipping a nullnet app to Google Play

Companion to **mcp-fleet-builder**. Same house rules; different fleet. Two launches feed this file, both 2026-07: **encore** (`nullnet-app/encore`) — a shipping SwiftUI app rebuilt on a Kotlin Multiplatform core, then launched on Play alongside iOS — and **allotmint** (`nullnet-app/allotmint`), the *second* app onto the same Play account, which is where the fleet-level facts (shared keystore, per-app grants, the bootstrap ladder) surfaced. Everything below that says *hard-won* cost real time; none of it is theory. Where the two apps diverge, both are shown — the divergence is usually the lesson.

**Going forward, build Android alongside iOS from the start.** The port is the expensive path; it is documented here because it is what encore did, and because "alongside" is really "port, minus the archaeology".

## Architecture: one Kotlin core, native UI per platform

`shared/` (Kotlin: models, clients, matchers, view models as plain classes exposing `StateFlow<Phase>`) + `android/` (Compose) + `ios/` (SwiftUI over the framework via **SKIE**). Never Compose Multiplatform — UI stays native per platform; only logic and state are shared. Platform services (location, geocode, POI, secrets, files) are injected impls of common interfaces, assembled by a Kotlin factory.

The interop facts that cost the most time:

- **Swift cannot implement Kotlin `suspend` members.** Declare a non-suspend `*Callback` interface in commonMain, implement that in Swift, and wrap it in a Kotlin `suspendCancellableCoroutine` adapter. There is no way around this; discover it before designing the seam, not after.
- **Kotlin default args are not bridged** to Swift — pass every parameter explicitly. `() -> Long` arrives as `() -> KotlinLong` (`KotlinLong(value: Int64(...))`). Kotlin `object` → `.shared`; top-level funcs → `<FileName>Kt.func()`.
- **commonMain must never import `java.*`** — it compiles for iOS. JVM-only tests miss it; the *link* step catches it. Gate every shared change on `:shared:testDebugUnitTest :shared:linkDebugTestIosSimulatorArm64`.
- `runBlocking` doesn't exist in commonTest (JVM+Native) — real-time tests go in androidUnitTest.
- During a port, `shared.`-qualify types that collide with same-named local Swift types. The collisions vanish once the duplicated Swift is deleted.
- SKIE needs `skie { features { enableSwiftUIObservingPreview = true } }` for the SwiftUI `Observing` API. Check SKIE's supported Kotlin range *before* touching versions.
- iOS consumes the framework by direct integration: an XcodeGen `preBuildScripts` entry running `:shared:embedAndSignAppleFrameworkForXcode` (`basedOnDependencyAnalysis: false`), plus `FRAMEWORK_SEARCH_PATHS`, `OTHER_LDFLAGS: -framework shared`, `ENABLE_USER_SCRIPT_SANDBOXING: NO`. It lives in `project.yml`, never the gitignored `.xcodeproj`.

**Android has no analog for some Apple services.** MapKit POI → `Geocoder` reverse-geocode (lower fidelity; acceptable if the app's fallback chain degrades gracefully). MetricKit → `ApplicationExitInfo`. Decide the fidelity gap is acceptable *before* porting the feature.

## One-way doors — settle these before the first upload

- **The Play package name is permanent from the first upload.** Not "hard to change": permanent. Settle it while nothing is uploaded. Fleet convention is reverse-DNS of the org domain: `app.nullnet.encore`, `app.nullnet.allotmint`, `app.nullnet.storymint`. (`com.nullnet.passmint` is an older variant; `fm.curtaincall.app` has its own product domain.)
- **The iOS bundle id may legitimately differ.** A bundle id already live on App Store Connect cannot be renamed without a new app record and losing TestFlight history — so encore is `app.nullnet.encore` on Play and `com.chrischall.encore` on iOS, deliberately. Document the divergence in CLAUDE.md or someone will "fix" it. The Kotlin namespace is a *third*, independent thing (`com.chrischall.encore.android`) — invisible to Play, so the launch component reads `app.nullnet.encore/com.chrischall.encore.android.MainActivity`.
- **The first upload must be manual through the Play Console.** The Developer API cannot create a package; it only works once a bundle exists. Every "just automate it" plan dies here.
- **A Play app record has NO package name until that first upload.** You only name the *app* in Console; the package is bound by the first bundle. So the API cannot see the app at all beforehand — see the status ladder below. This reads exactly like a permissions bug and isn't.
- **Don't hand-build the bootstrap AAB — let CI build it and download the artifact** (allotmint). `deploy-play.yml` uploads the `.aab` as an artifact *before* the publish step, so the first run — which is *expected* to fail at publish with `404 Package not found` — still hands you the bundle to upload by hand. This kills two problems at once: nobody needs the keystore password on a laptop, and the bootstrap versionCode is already inside CI's own monotonic sequence, so there is no floor to collide with.
- **If you do hand-build it, give it a LOW versionCode (1).** Play only accepts strictly increasing codes, so a hand-upload at 1042 permanently locks CI out below it. (encore's CI issues `run_number + 1000`; allotmint's `run_number*100 + run_attempt` — either is fine, but the bootstrap must sit *below* the next CI value, which the artifact route guarantees for free.)

## Signing — Play App Signing

The keystore in the repo is the **upload key only**; Google holds the app signing key devices verify. Losing it is a Console reset, not a dead app — the opposite of an Apple distribution cert. Say so in the example file, or someone will over-protect it and under-back-it-up.

**The fleet shares ONE upload keystore across every app — do not generate a second one** (learned on allotmint, the second app). Play links the upload certificate *per-app at enrolment*, so one key legitimately signs every nullnet app, and the org secrets are singular and `visibility: all`. Consequences that look alarming and are not:

- The alias is **`encore-upload`** for every app, named for whichever app created the key first. An alias is just a label — it is **not** secret, so it belongs in the workflow's `env:`, not a fifth org secret.
- A new app's bundle is therefore signed `CN=Chris Hall, OU=Encore, O=nullnet` even though it isn't encore. Expected. Verify the **package name** in the bundle instead — that's the thing the first upload makes permanent.
- The trade is deliberate: one compromised upload key affects every app, in exchange for a bootstrap with no new key material. Play App Signing makes an upload-key reset survivable, which is what tips the balance.

Only for the **first** app in a fleet (or a deliberately isolated one):

```bash
keytool -genkeypair -v -keystore android/upload-keystore.jks \
  -alias <app>-upload -keyalg RSA -keysize 4096 -validity 10950
```

- Gitignore `*.jks`, `*.keystore`, `android/keystore.properties` **before** generating. Verify with `git check-ignore -v`, not by eye.
- Config reads a gitignored `android/keystore.properties`; commit a `.example`.
- **Absent the keystore, the release must build UNSIGNED** (`signingConfig = null`), never fall back to the debug key. An unsigned AAB fails loudly at upload; a debug-signed one fails confusingly.
- CI writes that same `keystore.properties` from org secrets, then deletes it — self-hosted runners keep their workspace between jobs.

## Versioning

- `versionName` is release-please's (`// x-release-please-version` marker in `android/build.gradle.kts`, listed in `release-please-config.json` → `extra-files` beside `ios/project.yml`). Both platforms bump in step from one manifest.
- `versionCode` comes from `-PandroidVersionCode`, **not** the semver: Play needs a strictly increasing value per upload, and any one version may be re-uploaded (a bad build, a signing fix). CI passes `run_number + 1000`; local default 1.

## R8 — the trap that ships silently broken builds (hard-won)

**Release is minified; debug is not. This is where Android bites.** kotlinx.serialization reaches its generated `$$serializer` classes reflectively through the Companion, so R8 sees no call site and strips them. The result compiles, installs, **launches fine**, and then throws `SerializationException` on the first API response. Un-minified unit suites cannot catch it. Neither can a smoke test that never makes a network call.

Ship `references/proguard-rules.pro` (keep rules for kotlinx.serialization / Ktor / OkHttp / coroutines) and `scripts/verify-minified-serializers.sh`, which asserts against the actual DEX. Wire the guard into the deploy workflow, not just CI.

**Never copy another app's keep rules verbatim — scope them to *this* app's packages first (hard-won, allotmint).** encore's rules keep `com.chrischall.encore.shared.**`, because all its `@Serializable` types live in the shared module. allotmint's live in **two** modules — `app.allotmint.engine` (`:shared`) *and* `app.nullnet.allotmint.{store,auth}` (the app itself, i.e. its entire store and auth layer). Copying encore's rules across would have kept the shared ones, stripped the app-side ones, and said **nothing at build time**. Before writing rules, enumerate where `@Serializable` actually lives:

```bash
grep -rl "@Serializable" --include="*.kt" <each source root> | xargs -I{} grep -m1 "^package" {} | sort -u
```

Then keep every root the scan returns, and point the guard's scanner at all of them. Also drop rules for stacks the app doesn't use: allotmint uses OkHttp directly and has no Ktor, so encore's Ktor/atomicfu keeps are noise that implies coverage it doesn't have.

**Count declarations by parsing, not grepping.** `grep -c "@Serializable"` counted 35 in allotmint; 2 were prose mentions in KDoc, giving 33 real declarations — 29 requiring a `$$serializer` and 4 exempt. A plan built on the grep number sends the guard hunting for serializers that were never generated.

**`androidx.security:security-crypto` (EncryptedSharedPreferences → Tink) needs NO custom keep — but confirm this, don't assume it.** Tink resolves key templates and protobuf types reflectively, the same shape as the serialization trap: strip it and the **token store fails at runtime**, so sign-in breaks while everything compiles and launches. The reason no rule is needed (verified on allotmint, 2026-07-17, by unzipping the artifacts — not by reasoning): `security-crypto` 1.1.0 ships an **intentionally-empty** `proguard.txt` ("safe to shrink"), and `tink-android` 1.8.0 ships `META-INF/proguard/protobuf.pro` with `GeneratedMessageLite` field keeps that **AGP applies automatically**. So a hand-written blanket Tink keep would *contradict* upstream, not help. The only rule allotmint added near this is a scoped `-dontwarn com.google.errorprone.annotations.**` (Tink's compile-only annotations). **Proven at runtime**, which reasoning cannot substitute for: a minified build drove an `EncryptedSharedPreferences.create()` encrypt-write → cold-restart → decrypt-read round-trip through the token seam with no `GeneralSecurity`/`Tink` crash. If a future androidx.security/Tink version changes its shipped rules, re-verify — the empty-proguard fact is version-specific.

**Gitignore `__pycache__/` and `*.pyc` before shipping the Python guard.** The self-test gate imports the scanner on every run, so a `.pyc` lands in the tree — interpreter-version-specific, so a tracked one goes stale and every other machine gets untracked noise.

- **Only some shapes generate a `$$serializer`.** `data class`/`class` do. Enums (`EnumSerializer`), objects, sealed/abstract (polymorphic), and `@Serializable(with = …)` do **not** — demanding one for them fails the release for no reason. (The enum case is verified empirically against a real build; the rest follow the same rule. `value class` is deliberately *not asserted* rather than guessed at.)
- **A guard must never skip silently.** `serializable_scan.py` returns an `unrecognized` bucket that hard-fails; anything it can't place stops the release rather than passing quietly. A guard that quietly stops checking reports success while guarding nothing — strictly worse than never having guarded.
- **Test the guard in both directions.** Break the keep rules on purpose and confirm it fails *and names the type*. Doing this found a real defect: with every serializer stripped, `grep` matched nothing and `pipefail` killed the script before it could report — it "failed" only by accident, with no diagnostic.
- `-keepclassnames` is not an R8 directive (it's `-keepnames`). `kotlinx-coroutines-android` already ships consumer rules for the dispatcher factory; don't duplicate them.
- Upload `mapping.txt` or every Play Console crash report comes back as obfuscated one-letter frames. Skip `debugSymbols` unless there are *real* native libs — a prebuilt, already-stripped Compose `.so` is noise.

**The only real proof is a minified build hitting the live API.** Install the release AAB (`bundletool build-apks --mode=universal` → `install-apks`) with real keys and drive the deepest model graph the app has. DEX inspection is necessary, not sufficient.

## Launcher icon (hard-won)

**A missing `android:icon` in the manifest is silent** — the app just ships the stock green robot. iOS has no equivalent failure, so a port forgets it.

Build a real adaptive vector icon (`background` / `foreground` / `monochrome`), not a scaled iOS bitmap. See `references/adaptive-icon.md`. The two facts that matter:

- **Only the centre 66dp circle of the 108dp canvas is guaranteed visible** on every launcher mask. Fit the artwork inside it and check the maths, then render under both a circle and a squircle before believing it.
- **The monochrome (themed) layer is tinted a single colour**, so a check knocked out of a filled disc vanishes. Redraw such shapes as open rings — do not reuse the foreground layer.
- Verify by rendering: **ImageMagick's internal SVG renderer silently drops strokes** — use `rsvg-convert`. A launcher may draw a ring around a *newly installed* app; that's a launcher treatment, not your background. Check in the app drawer before "fixing" it.
- Play's listing needs a separate **512×512 icon** and **1024×500 feature graphic**, uploaded in Console, not bundled. Generate them from the same vector so they can't drift.

## Play Console + service account (the API cannot bootstrap itself)

See `references/play-console-bootstrap.md`. Shape:

1. Create the app record in Console, upload the bootstrap AAB by hand (locks the package, enrols Play App Signing).
2. A dedicated GCP project (`nullnet-play`) with `androidpublisher.googleapis.com` enabled; service account `play-publisher@…`; JSON key. **Grant it no GCP IAM roles** — Play permissions come from Console → *Users and permissions*, so the account can't touch anything else in the cloud.
3. Invite the service-account email in Console and grant *Release to testing tracks*. App-level is enough; account-wide admin is not needed. **Every app needs its own grant** — an SA that already publishes one fleet app is *not* automatically granted the next one (allotmint 403'd until granted explicitly). Granting at **account level** instead costs nothing extra and spares every future app this step.
4. **Probe before spending a workflow run.** Mint a token and `POST /edits`. The status code tells you exactly where you are — this ladder is the fastest diagnostic in the whole setup, and each rung is a *different* fix:
   - **`404 Package not found`** → the app record exists but has **never been uploaded to**, so the package name isn't bound yet. Nothing is wrong; you simply cannot API-verify anything until the manual bootstrap upload. **Not a permissions problem, though it reads like one.**
   - **`403 PERMISSION_DENIED`** → the package is bound (the upload landed) and the SA is **not granted** on it. This is the expected answer between bootstrap and grant.
   - **`200` + an edit id** → CI will publish. Delete the probe edit.
   - `insufficient authentication scopes` → *your probe* is wrong, not the key: use `--scopes=https://www.googleapis.com/auth/androidpublisher`, not the default `cloud-platform`.

   allotmint walked `404 → 403 → 200` in that order, and each transition confirmed the previous step actually worked. If you see 403 where you expected 404, the bootstrap upload succeeded.
5. **Probe by impersonation — never download a key to check.** If you're `roles/owner` on the GCP project, grant *yourself* `roles/iam.serviceAccountTokenCreator` **on the SA** (this is a role for the human, not for the SA — the "no GCP IAM roles" rule above still holds), impersonate, probe, then revoke. No key material touches a laptop:

   ```bash
   SA=play-publisher@nullnet-play.iam.gserviceaccount.com
   gcloud iam service-accounts add-iam-policy-binding "$SA" \
     --member="user:<you>@gmail.com" --role="roles/iam.serviceAccountTokenCreator" --project nullnet-play
   # IAM propagation takes ~30s — retry rather than concluding it failed
   TOKEN=$(gcloud auth print-access-token --impersonate-service-account="$SA" \
     --scopes=https://www.googleapis.com/auth/androidpublisher)
   curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Length: 0" \
     "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/<pkg>/edits"
   gcloud iam service-accounts remove-iam-policy-binding "$SA" \
     --member="user:<you>@gmail.com" --role="roles/iam.serviceAccountTokenCreator" --project nullnet-play
   ```

## CI — deploy-play.yml

Start from `references/deploy-play.yml`. Mirrors `deploy-testflight.yml`: `v*` tag or manual dispatch with a track/status choice (`draft` for a cautious first run).

- **Runner: `ubuntu-latest` is now proven — but only without SKIE.** allotmint publishes from `ubuntu-latest` (build + sign + reach the Play API, 2026-07-17): its shared module declares Apple targets but **mac-gates** them and does **not** apply SKIE. encore does apply SKIE, so its need for the self-hosted macOS runner stands unresolved — `:android:bundleRelease` still never builds an Apple target, but SKIE's effect on *configuration* is the untested part. Rule: no SKIE → ubuntu; SKIE → stay on macOS until someone proves otherwise.
- **Android CI can be free.** Gate the Android module on the SDK's presence (`ANDROID_HOME` set, or `sdk.dir` in `local.properties`) in `settings.gradle.kts`, and a plain `./gradlew build` picks it up on GitHub's ubuntu runners — which set `ANDROID_HOME` — while SDK-less machines and the mac lane stay green. allotmint needed **no** Android CI lane at all; check before building one.
- **Upload tool: either works, but AGP 9 forces the floor.** encore uses the `r0adkll/upload-google-play` action; allotmint uses **Gradle Play Publisher**, where **4.0.0 is a hard floor** — it is the first GPP release supporting AGP 9, and 3.x is AGP 8 only. With GPP, split `bundleRelease` from `publishReleaseBundle` so signing/guard checks can sit between them.
- Pin the Play upload action to a **commit SHA** — it receives the service-account key, so a moving tag is an unreviewed change with access to it.
- **Verify the AAB is signed before uploading.** Play only rejects an unsigned bundle after the upload. This matters *more* with a conditional signing config: a keystore secret that is missing or fails to decode yields a silently **unsigned** bundle that builds clean. Fail fast on an empty secret too, then assert the signature (`unzip -l "$AAB" | grep -qiE 'META-INF/.*\.(RSA|EC|DSA)'`) — verified to fire against a real unsigned bundle.
- **Upload the `.aab` as an artifact *before* the publish step.** Publish is the one step expected to fail on a virgin app, and the artifact is what you hand-upload to fix that. Ordering it first turns the failed bootstrap run into the thing that unblocks the bootstrap.
- Store the service-account JSON base64 (`PLAY_SERVICE_ACCOUNT_JSON_B64`), matching `ASC_PRIVATE_KEY_B64` — it keeps a multi-line blob single-line. Decode to a file and validate it parses as JSON, so a mis-stored secret fails with a clear message instead of deep inside the action.

Org secrets (visibility `all`, matching the Apple signing material), named in the fleet's `<SCOPE>_<THING>_<FORMAT>` style: `PLAY_UPLOAD_KEYSTORE_JKS_B64` (cf. `DIST_CERT_P12_B64`), `PLAY_UPLOAD_KEYSTORE_PASSWORD` (cf. `DIST_CERT_PASSWORD`), `PLAY_UPLOAD_KEY_PASSWORD`, `PLAY_SERVICE_ACCOUNT_JSON_B64`. **Exactly four, shared by every app — a new app adds none.** There is deliberately no alias secret: the alias (`encore-upload`) isn't secret, so it lives in the workflow's `env:`. Both `_B64` suffixes are load-bearing — the SA key is base64, not raw JSON, and a workflow that writes it out verbatim fails at the first deploy.

## Gotchas (hard-won — the encore launch, 2026-07)

- **`gh secret set` stores whatever it's given, including nothing.** `base64 -i missing.jks | gh secret set …` from the wrong directory silently writes a garbage secret that fails only at deploy time. **Validate every source before writing** — open the keystore with its password, parse the JSON — and re-set from a verified source rather than reasoning about timestamps.
- **A repo secret silently shadows an org secret of the same name.** Moving to org scope means *deleting* the repo copies, or nothing changes.
- **Auto-merge can merge a PR out from under you mid-work.** A `pass`/`warn` verdict arms `ready-to-merge`; CI goes green; the squash lands whatever was pushed *at that moment*. Encore's package rename missed its own PR this way and sat broken on `main`. **It happened again on allotmint** (#247: opened, armed 3 min later, squashed at ~14 min; the fix pushed after that missed the merge and `main` shipped a `deploy-play.yml` referencing secrets that don't exist). Twice is a pattern, so know the tells:
  - **`git push` printing `Create a pull request for '<branch>'` means the branch has NO open PR** — i.e. it already merged. That hint is a **STOP signal**, not noise. It is the cheapest available warning and it is easy to read straight past.
  - **Push every commit before opening the PR.** Treat `gh pr create` as the last step, not a checkpoint.
  - **Verify what `main` actually contains** (`git diff main..<branch>`), never what the PR *intended* to contain.
- **Never reuse a squash-merged branch for the follow-up PR.** Squash means the branch's commits aren't ancestors of `main`, so re-opening from it re-applies everything atop the squashed copy and conflicts immediately (allotmint #249). Cherry-pick the missed commit onto a **fresh branch cut off the updated `main`** (#250).
- **A single-commit PR squashes with the COMMIT subject, not the PR title.** CLAUDE.md's "the PR title becomes the squash subject" is only true with ≥2 commits. A lone commit reading `refactor(android)!:` cut **1.0.0** from what was titled `fix(…)`. On a one-commit PR the commit subject *is* the release decision; never use `!` as shorthand for "notable".
- **release-please runs on a PAT, so its tag DOES trigger workflows.** (A `GITHUB_TOKEN` tag wouldn't.) Merging the release PR ships to TestFlight *and* Play with no further confirmation. Merging is shipping; say so before someone clicks it.
- **One self-hosted runner serialises everything.** A queued deploy behind two CI runs looks broken and isn't. Check `busy=true` before debugging.
- AGP nests native libs under the task name (`merged_native_libs/release/mergeReleaseNativeLibs/out/lib`) — verify any path you put in a workflow rather than assuming.
- `aapt2` cannot read an AAB; use `bundletool dump manifest`.
- Resource shrinking keeps manifest-referenced resources, so adaptive icons survive — verified, not assumed.

## New Play app — fast path

**Adding an app to the existing fleet** (the common case — allotmint, 2026-07):

1. Settle the package name (`app.nullnet.<app>`) and confirm the iOS bundle id's fate. **Before anything is uploaded.**
2. **Do NOT generate a keystore or a service account.** Reuse the org secrets and the `encore-upload` alias; the SA is already created. Only step 6's per-app Console grant is new.
3. `applicationId`, release signing from the shared keystore, `versionName` via release-please marker, `versionCode` from CI, R8 + `isShrinkResources`, keep rules **scoped to this app's own packages** (enumerate them; don't copy).
4. Adaptive icon + `android:icon` in the manifest. Render-check both masks.
5. `deploy-play.yml` (artifact **before** publish) → create the app record in Console → dispatch → the run fails at publish with `404`, which is correct → download the artifact → upload by hand → enrol Play App Signing.
6. Grant the SA on the new app in Console (or account-wide once, and skip this forever). Probe: `403` → grant → `200`.
7. Prove it: minified build + real keys + live API call against the deepest model graph.

**First app in a new fleet** — as above, plus: generate the upload keystore (gitignore it first; verify with `git check-ignore`), create the GCP project + service account + org secrets from **validated** sources, and hand-build the bootstrap AAB at **versionCode 1** if CI isn't wired yet.
