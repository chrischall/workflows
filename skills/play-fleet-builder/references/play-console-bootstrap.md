# Play Console + service account bootstrap

The part that cannot be automated, and the exact order that works. Run once per
app; the GCP project and service account are fleet-wide and reused.

## 1. The app record + the manual first upload

The Play Developer API **cannot create a package**. It only operates on an app
that already has a bundle. So:

1. Play Console → **Create app**. Name, free/paid, declarations.
2. Build the bootstrap AAB at **versionCode 1** (CI starts at `run_number +
   1000`; a hand-upload above that locks CI out permanently — Play only accepts
   strictly increasing codes and never forgets one).
3. Upload it by hand to **Internal testing**. This locks the package name
   forever and enrols Play App Signing.

The bootstrap build exists to claim the package and prove signing. If it was
built without API keys it will run with the app's no-key fallback — fine for
that purpose, wrong for testers. Ship a keyed build over it immediately (CI
does this; the new versionCode replaces it on the track).

## 2. GCP project + service account (once for the fleet)

```bash
gcloud projects create nullnet-play --name="nullnet Play publishing"
gcloud services enable androidpublisher.googleapis.com --project nullnet-play
gcloud iam service-accounts create play-publisher --project nullnet-play \
  --display-name="Play publisher (CI)"
gcloud iam service-accounts keys create key.json \
  --iam-account=play-publisher@nullnet-play.iam.gserviceaccount.com \
  --project nullnet-play
```

**Grant it no GCP IAM roles.** Play permissions come from Play Console, not
GCP, so the account has no reach into anything else in the cloud. No billing
needed — the Play Developer API is free.

## 3. The Console grant

Play Console → **Users and permissions** → **Invite new user** →
`play-publisher@nullnet-play.iam.gserviceaccount.com` → grant **Release to
testing tracks** (add production later if wanted). App-level permission is
enough; account-wide admin is not.

## 4. Probe before spending a workflow run

Confirm authorisation directly instead of discovering it in a red CI run. Use an
isolated gcloud config so the normal login is untouched:

```bash
export CLOUDSDK_CONFIG=$(mktemp -d)
gcloud auth activate-service-account --key-file=key.json --quiet
TOKEN=$(gcloud auth print-access-token \
  --scopes="https://www.googleapis.com/auth/androidpublisher")
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/<pkg>/edits"
```

Read the answer carefully — the two 403s mean opposite things:

- `PERMISSION_DENIED — the caller does not have permission` → **the key works.**
  Authentication succeeded; only the Console grant (or the app) is missing. This
  is the correct pre-grant answer.
- `PERMISSION_DENIED — Request had insufficient authentication scopes` → **your
  probe is wrong, not the key.** `gcloud print-access-token` defaults to
  `cloud-platform`; the Play API needs the `androidpublisher` scope.
- `200` + an edit id → CI will publish. `DELETE` the edit; don't leave it open.

## 5. Secrets

```bash
base64 -i key.json | tr -d '\n' \
  | gh secret set PLAY_SERVICE_ACCOUNT_JSON_B64 --org <org> --visibility all
```

**Validate the source before every write.** `gh secret set` stores whatever it
is handed, including nothing: `base64 -i key.json` from the wrong directory
writes a garbage secret that fails only at deploy time, with a confusing error.
Parse the JSON / open the keystore with its password first, and re-set from a
verified source rather than reasoning about `updated_at` timestamps.

**A repo secret shadows an org secret of the same name** — delete repo copies
when moving to org scope, or nothing changes.

## 6. Reading Play's actual state

Trust Play over the workflow's summary:

```bash
EID=$(curl -s -X POST -H "Authorization: Bearer $TOKEN" "$API/edits" | jq -r .id)
curl -s -H "Authorization: Bearer $TOKEN" "$API/edits/$EID/bundles"        # versionCodes
curl -s -H "Authorization: Bearer $TOKEN" "$API/edits/$EID/tracks/internal" # releases
curl -s -X DELETE -H "Authorization: Bearer $TOKEN" "$API/edits/$EID"
```

The `bundles` response carries each bundle's `sha256` — compare it against the
local AAB to know exactly which build is live (this is how encore confirmed a
blank-key bootstrap was on the track).

## Still Console-only

Data safety, content rating, target audience, privacy policy URL — required
before rollout, even for internal testing. No API.
