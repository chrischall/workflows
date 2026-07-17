---
name: play-fleet-builder
description: "Ship a nullnet app to Google Play — porting an existing iOS app onto a shared Kotlin Multiplatform core, or building the Android app alongside iOS from the start. Covers the one-way doors (package name, signing key, versionCode floor), Play App Signing, the R8/kotlinx.serialization trap that ships silently broken builds, adaptive icons, the Play Console + service-account bootstrap the API cannot do for you, and deploy-play.yml. Companion to mcp-fleet-builder."
---

# Shipping a nullnet app to Google Play

Companion to **mcp-fleet-builder**. Same house rules; different fleet. Canonical example: **encore** (`nullnet-app/encore`) — a shipping SwiftUI app rebuilt on a Kotlin Multiplatform core, then launched on Play alongside iOS. Everything below that says *hard-won* cost real time in that launch (2026-07); none of it is theory.

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
- **Give that manual bootstrap AAB a LOW versionCode (1).** CI issues `run_number + 1000`, and Play only accepts strictly increasing codes — a hand-upload at 1042 permanently locks CI out below it.

## Signing — Play App Signing

The keystore in the repo is the **upload key only**; Google holds the app signing key devices verify. Losing it is a Console reset, not a dead app — the opposite of an Apple distribution cert. Say so in the example file, or someone will over-protect it and under-back-it-up.

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
3. Invite the service-account email in Console and grant *Release to testing tracks*. App-level is enough; account-wide admin is not needed.
4. **Probe before spending a workflow run.** Mint a token and `POST /edits`:
   - `PERMISSION_DENIED — the caller does not have permission` → auth works, the Console grant is missing. This is the expected pre-grant answer.
   - `insufficient authentication scopes` → *your probe* is wrong, not the key: use `--scopes=https://www.googleapis.com/auth/androidpublisher`, not the default `cloud-platform`.
   - `200` + an edit id → CI will publish. Delete the probe edit.

## CI — deploy-play.yml

Start from `references/deploy-play.yml`. Mirrors `deploy-testflight.yml`: `v*` tag or manual dispatch with a track/status choice (`draft` for a cautious first run).

- Run it on the **self-hosted macOS runner**, same as CI: the shared module declares Apple targets and applies SKIE, so its Gradle configuration is only proven there. (`:android:bundleRelease` never builds an Apple target — Linux may well work; it just isn't proven.)
- Pin the Play upload action to a **commit SHA** — it receives the service-account key, so a moving tag is an unreviewed change with access to it.
- **Verify the AAB is signed before uploading.** Play only rejects an unsigned bundle after the upload.
- Store the service-account JSON base64 (`PLAY_SERVICE_ACCOUNT_JSON_B64`), matching `ASC_PRIVATE_KEY_B64` — it keeps a multi-line blob single-line. Decode to a file and validate it parses as JSON, so a mis-stored secret fails with a clear message instead of deep inside the action.

Org secrets (visibility `all`, matching the Apple signing material), named in the fleet's `<SCOPE>_<THING>_<FORMAT>` style: `PLAY_UPLOAD_KEYSTORE_JKS_B64` (cf. `DIST_CERT_P12_B64`), `PLAY_UPLOAD_KEYSTORE_PASSWORD` (cf. `DIST_CERT_PASSWORD`), `PLAY_UPLOAD_KEY_PASSWORD`, `PLAY_SERVICE_ACCOUNT_JSON_B64`. Reuse the existing app-key secrets.

## Gotchas (hard-won — the encore launch, 2026-07)

- **`gh secret set` stores whatever it's given, including nothing.** `base64 -i missing.jks | gh secret set …` from the wrong directory silently writes a garbage secret that fails only at deploy time. **Validate every source before writing** — open the keystore with its password, parse the JSON — and re-set from a verified source rather than reasoning about timestamps.
- **A repo secret silently shadows an org secret of the same name.** Moving to org scope means *deleting* the repo copies, or nothing changes.
- **Auto-merge can merge a PR out from under you mid-work.** A `warn` verdict arms `ready-to-merge`; CI goes green; the squash lands whatever was pushed *at that moment*. Encore's package rename missed its own PR this way and sat broken on `main`. **Push every commit before opening the PR**, and check what `main` actually contains before trusting a merge.
- **A single-commit PR squashes with the COMMIT subject, not the PR title.** CLAUDE.md's "the PR title becomes the squash subject" is only true with ≥2 commits. A lone commit reading `refactor(android)!:` cut **1.0.0** from what was titled `fix(…)`. On a one-commit PR the commit subject *is* the release decision; never use `!` as shorthand for "notable".
- **release-please runs on a PAT, so its tag DOES trigger workflows.** (A `GITHUB_TOKEN` tag wouldn't.) Merging the release PR ships to TestFlight *and* Play with no further confirmation. Merging is shipping; say so before someone clicks it.
- **One self-hosted runner serialises everything.** A queued deploy behind two CI runs looks broken and isn't. Check `busy=true` before debugging.
- AGP nests native libs under the task name (`merged_native_libs/release/mergeReleaseNativeLibs/out/lib`) — verify any path you put in a workflow rather than assuming.
- `aapt2` cannot read an AAB; use `bundletool dump manifest`.
- Resource shrinking keeps manifest-referenced resources, so adaptive icons survive — verified, not assumed.

## New Play app — fast path

1. Settle the package name (`app.nullnet.<app>`) and confirm the iOS bundle id's fate. **Before anything is uploaded.**
2. Generate the upload keystore; gitignore it first; verify with `git check-ignore`.
3. `applicationId`, release signing from `keystore.properties`, `versionName` via release-please marker, `versionCode` via `-PandroidVersionCode`, R8 + `isShrinkResources`, keep rules from `references/`.
4. Adaptive icon + `android:icon` in the manifest. Render-check both masks.
5. Build the bootstrap AAB at **versionCode 1**; create the app in Console; upload by hand.
6. GCP project + service account + Console grant; probe with `POST /edits` until it returns 200.
7. Org secrets from **validated** sources; `deploy-play.yml`; wire the serializer guard.
8. Prove it: minified build + real keys + live API call against the deepest model graph.
