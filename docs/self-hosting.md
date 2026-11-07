# Self-hosting: web app and Sync server on Firebase

Ultracipher has no server of its own, and this project does not run a public one. If you want to sync your encrypted database through a plain REST service instead of GitHub, you run the small function in [`server/firebase/`](../server/firebase/) yourself. The same Firebase project can also serve the web app, which is the recommended setup: web app and server then share one origin, so the page's Content-Security-Policy and CORS need no changes.

The server only ever stores the encrypted file (the same bytes the GitHub file `<name>.txt` holds, without base64). It has no accounts and no authentication; read [Security notes](#security-notes) before you use it.

## Contents

1. [The fork model](#the-fork-model)
2. [Create the Firebase project](#1-create-the-firebase-project)
3. [Set up the deploy access (Workload Identity Federation)](#2-set-up-the-deploy-access-workload-identity-federation)
4. [Set the repository variables and deploy](#3-set-the-repository-variables-and-deploy)
5. [Use it in the app](#4-use-it-in-the-app)
6. [Alternative: deploying from your own machine](#deploying-from-your-own-machine)
7. [Updating your fork](#updating-your-fork)
8. [Variant: the function only, without Hosting](#variant-the-function-only-without-hosting)
9. [The protocol](#the-protocol-for-your-own-implementation)
10. [Security notes](#security-notes)
11. [Items to verify](#items-to-verify)

## The fork model

- `ultracipher` (upstream) contains everything: the app, the function, [`firebase.json`](../firebase.json) and the workflow [`.github/workflows/firebase.yml`](../.github/workflows/firebase.yml). The workflow does nothing unless the repository variable `DEPLOY_FIREBASE` is `true`, and it never runs for pull requests.
- You fork the repository (or push a copy to a repository of your own) and **change no code**. Everything that is yours lives in repository variables: your Firebase project ID and your deploy access. Because the fork has no changes of its own, it can be brought up to date without merge conflicts (see [Updating your fork](#updating-your-fork)).
- There are no repository secrets and no long-lived keys. The workflow signs in to Google Cloud with a short-lived token that GitHub issues for the run (Workload Identity Federation).
- The workflow is one of two equal ways to deploy. If you are the only user and do not want a fork, a deploy access and repository variables, deploy from your own machine with the Firebase CLI instead ([Deploying from your own machine](#deploying-from-your-own-machine)); `DEPLOY_FIREBASE` then stays unset. Steps 2 and 3 are only for the workflow.
- The Pages workflow (`pages.yml`, variable `DEPLOY_PAGES`) stays as it is, for forks that do not use Firebase (the web app then supports GitHub sync only, or a self-built function host, see [the variant below](#variant-the-function-only-without-hosting)).

## 1. Create the Firebase project

1. In the [Firebase console](https://console.firebase.google.com/) create a project (or add Firebase to an existing Google Cloud project). Note the **project ID**.
2. Switch the project to the **Blaze** (pay as you go) plan. Cloud Functions 2nd generation, and with it this server, needs it, and billing requires a payment method. Usage of one person's password database is tiny, but nothing caps the bill by itself.
3. Set a **budget alert** right away: Google Cloud console, Billing, Budgets & alerts, create a budget with a small amount and thresholds (for example 50 % and 100 %). Or with the CLI:

   ```bash
   gcloud billing budgets create \
     --billing-account=BILLING_ACCOUNT_ID \
     --display-name="ultracipher" \
     --budget-amount=5EUR \
     --threshold-rule=percent=0.5 \
     --threshold-rule=percent=1.0
   ```

   A budget only sends a notification; it does not stop spending. The function additionally limits itself: at most 2 instances, 16 MiB per file, 60 s per request.
4. Create the default Cloud Storage bucket: Firebase console, Build, Storage, **Get started**. Choose **production mode** (locked security rules). The function reaches the bucket with its own service account and does not depend on the rules, so leave them closed: the deploy does not touch Storage rules, and "test mode" rules would open the bucket to everyone. The function stores the files as `ucdb/<name>` in this default bucket.
   - **Do this even if the project already has a bucket.** Old Google Cloud or App Engine projects often have a `<project-id>.appspot.com` bucket. Firebase does not use it: it hands the function `<project-id>.firebasestorage.app` as the default bucket (you can check the value with the Firebase Management API, `GET https://firebasemanagement.googleapis.com/v1beta1/projects/<project-id>/adminSdkConfig`, field `storageBucket`). Until "Get started" has created that bucket, the bucket does not exist, `PUT` fails with `500`, and the function answers `GET` with `500` and the log line `ucdb GET bucket-missing` (an older version of the function answered `404`, which the app shows as "remote file missing").
   - Choose the bucket location with care, it cannot be changed later. The function runs in `europe-west1`; the best choice is the same region. The free tier for new buckets applies only to US regions; for the amount of data of a password database, any other region costs a few cents.
   - You do not need to deploy again after creating the bucket (observed): the function reads the bucket name from its configuration and finds the bucket on the next request.
5. Optional: enable Hosting in the console (Build, Hosting, Get started; the console wizard can be skipped, the deploy creates the site). The web app is then served at `https://<project-id>.web.app/` and `https://<project-id>.firebaseapp.com/`. A custom domain can be added in the console.

Enable the APIs the deploy uses (the deploy tries to enable missing ones itself, which needs more permissions than the deploy access below gets):

```bash
PROJECT=your-project-id
gcloud services enable --project="$PROJECT" \
  cloudfunctions.googleapis.com cloudbuild.googleapis.com \
  artifactregistry.googleapis.com run.googleapis.com \
  firebasehosting.googleapis.com firebase.googleapis.com \
  storage.googleapis.com cloudresourcemanager.googleapis.com \
  serviceusage.googleapis.com iam.googleapis.com \
  iamcredentials.googleapis.com sts.googleapis.com
```

## 2. Set up the deploy access (Workload Identity Federation)

GitHub Actions gets an OIDC token for every run. Google Cloud trusts it for exactly your repository and lets the run act as a service account that may deploy. Replace the upper-case values; `OWNER/REPO` is your fork, for example `alice/ultracipher`.

```bash
PROJECT=your-project-id
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')
REPO=OWNER/REPO
# Numeric ID of the account that owns the repository (user or organisation);
# the ID stays the same if the account is renamed, so a renamed or re-registered
# name cannot take over the trust
OWNER_ID=$(gh api users/OWNER --jq .id)   # or: curl -s https://api.github.com/users/OWNER

# Service account for the deploy
gcloud iam service-accounts create github-deploy --project="$PROJECT" \
  --display-name="GitHub Actions deploy"
SA="github-deploy@${PROJECT}.iam.gserviceaccount.com"

# Pool and provider; the attribute condition lets only your repository (and
# its owner account) on the branch master in
gcloud iam workload-identity-pools create github --project="$PROJECT" \
  --location=global --display-name="GitHub Actions"
gcloud iam workload-identity-pools providers create-oidc github --project="$PROJECT" \
  --location=global --workload-identity-pool=github \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref" \
  --attribute-condition="assertion.repository=='${REPO}' && assertion.repository_owner_id=='${OWNER_ID}' && assertion.ref=='refs/heads/master'"

# Let runs of your repository act as the service account
gcloud iam service-accounts add-iam-policy-binding "$SA" --project="$PROJECT" \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/attribute.repository/${REPO}"

# The value for GCP_WORKLOAD_IDENTITY_PROVIDER
gcloud iam workload-identity-pools providers describe github --project="$PROJECT" \
  --location=global --workload-identity-pool=github --format='value(name)'
```

`assertion.repository_owner_id` is the numeric ID of the owning account, as a string, from the GitHub OIDC token. The condition on `assertion.ref` means only runs on `master` can deploy, also when someone starts the workflow by hand on another branch. If your default branch has another name, change it there.

Roles for the service account (the first deploy creates Cloud Run services, an Artifact Registry repository and a source bucket):

```bash
for ROLE in \
  roles/firebasehosting.admin \
  roles/firebase.viewer \
  roles/cloudfunctions.admin \
  roles/run.admin \
  roles/artifactregistry.admin \
  roles/storage.admin \
  roles/serviceusage.serviceUsageConsumer \
  roles/iam.serviceAccountUser; do
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="serviceAccount:${SA}" --role="$ROLE" --condition=None
done
```

This list is broad on purpose so that the first deploy works; it is **not** a verified least-privilege set (see [Items to verify](#items-to-verify)). If a deploy fails, the error names the missing permission. The deploy access can deploy code that runs in your project, so protect your repository and its `master` branch accordingly (for example, require two-factor authentication, and do not give write access to people you do not trust).

## 3. Set the repository variables and deploy

In your fork: Settings, Secrets and variables, Actions, **Variables** (not Secrets), create:

| Variable | Value |
|---|---|
| `DEPLOY_FIREBASE` | `true` |
| `FIREBASE_PROJECT_ID` | your project ID |
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | the value printed by the last `describe` command (`projects/<number>/locations/global/workloadIdentityPools/github/providers/github`) |
| `GCP_SERVICE_ACCOUNT` | `github-deploy@<project-id>.iam.gserviceaccount.com` |

Also enable Actions in the Actions tab of the fork (GitHub disables workflows in new forks). Then start the workflow "Firebase deploy" by hand (Actions tab, Run workflow, branch `master`). Later pushes to `master` deploy automatically.

The workflow runs analysis and tests, the function's tests, builds the web app (`flutter build web --wasm --no-web-resources-cdn --base-href "/"`), installs the function's dependencies (`npm ci`) and runs `firebase deploy --only hosting,functions --project <id>`. [`firebase.json`](../firebase.json) serves the build from Hosting and rewrites `/ucdb/**` to the function `ucdb` (region `europe-west1`); there is no `.firebaserc` in the repository, the project ID comes from the variable. The same file sets `Content-Security-Policy: frame-ancestors 'none'` and `X-Frame-Options: DENY` on the web app, so it cannot be embedded in a frame (clickjacking).

## 4. Use it in the app

Open a database, menu **Sync server**, choose **Sync server (REST)** and enter

```
https://<project-id>.web.app/ucdb
```

with no trailing slash. The native apps and the web app use the same URL. The URL is stored encrypted inside the database and travels to your other devices with the sync, like the GitHub settings.

## Deploying from your own machine

This is an equal and simpler alternative to the GitHub workflow, for example for a single person: no fork, no Workload Identity Federation, no repository variables. Skip steps 2 and 3 above (do step 1 and use the app as in step 4). `DEPLOY_FIREBASE` stays unset, so the workflow does nothing.

Prerequisites:

- Flutter in the version that `.github/workflows/pages.yml` pins (`flutter-version`, currently 3.47.8), for the web build.
- Node 22 (the function's runtime; `engines` in `server/firebase/functions/package.json`).
- The Firebase CLI (`firebase-tools`; the workflow uses `15.35.0`, for example `npm install -g firebase-tools@15.35.0`), and `firebase login` once. The account needs deploy rights in the project (Owner or Editor is enough for your own project).

From the repository root:

```bash
cd ultracipher_flutter && flutter pub get && flutter build web --wasm --no-web-resources-cdn --base-href "/" && cd ..
cd server/firebase/functions && npm ci && cd ../../..
firebase deploy --only hosting,functions --project <project-id>
```

[`firebase.json`](../firebase.json) is read from the repository root and expects the build in `ultracipher_flutter/build/web`. The first deploy can end with an error about the cleanup policy; see below.

### First deploy: the cleanup policy

The first functions deploy of a project ends with the error `Functions successfully deployed but could not set up cleanup policy`, although the function **is** deployed. The Firebase CLI wants a policy that deletes old container images (otherwise images pile up and cost a small monthly amount) and cannot ask for it in a non-interactive run. Because the deploy stops there, Hosting may not have been published. Set the policy once, and finish Hosting if needed:

```bash
firebase functions:artifacts:setpolicy --project <project-id> --location europe-west1   # deletes images older than 1 day
firebase deploy --only hosting --project <project-id>
```

Later deploys do not ask again. In an interactive run (the commands above, in a terminal) the CLI asks for the number of days instead; `--force` accepts the default (1 day) without asking.

The GitHub workflow runs `firebase deploy --non-interactive` without `--force`, so its first run in a new project ends the same way: the step fails (the run is red) after the function was deployed, and Hosting may not have been published. Run the `setpolicy` command once (it needs a login with rights on Artifact Registry, for example your own) and start the workflow again; from then on it is green.

## Updating your fork

Your fork contains no changes of its own, so updating is a fast-forward.

- On GitHub: open your fork, "Sync fork", "Update branch". The next push to `master` deploys.
- Or locally:

  ```bash
  git remote add upstream https://github.com/pburlov/ultracipher.git   # once
  git pull upstream master
  git push
  ```

  Pushing changes under `.github/workflows/` needs a token with the `workflow` scope (or an SSH key); the "Sync fork" button does not.

If your repository is a copy and not a GitHub fork (for example because you already had a repository), the `upstream` remote works the same way.

## Variant: the function only, without Hosting

If you host the web app elsewhere (for example with the Pages workflow) or only use the native apps, you can deploy the function alone. Nothing in the repository changes for the native apps.

```bash
cd ultracipher/server/firebase/functions && npm ci && cd ../../..
npx firebase-tools@15.35.0 login
npx firebase-tools@15.35.0 deploy --only functions --project your-project-id
```

The URL for the app is then the function's own address, which the deploy prints: either `https://europe-west1-<project-id>.cloudfunctions.net/ucdb` or `https://ucdb-<hash>-ew.a.run.app` (both observed; the function itself sits at the root of its address, so the second form has no `/ucdb` suffix). Enter it under "Sync server" without a trailing slash; the function accepts `/<name>` directly.

For the **web** app the page's Content-Security-Policy must allow this host. Add it to `connect-src` in [`ultracipher_flutter/web/index.html`](../ultracipher_flutter/web/index.html), for example:

```
connect-src 'self' https://api.github.com https://europe-west1-<project-id>.cloudfunctions.net
```

This is the only code change a fork ever needs, and it makes the fork differ from upstream (you then merge on updates instead of fast-forwarding). The function answers CORS preflight requests and exposes the `ETag` header, so no change is needed there. The native apps are not subject to the Content-Security-Policy.

## The protocol (for your own implementation)

Anything that implements this can serve as a sync server; the Firebase function is one implementation. `<url>` is the base URL entered in the app, without trailing slash; `<name>` is the database name, 43 characters of base64url (`[A-Za-z0-9_-]`), which needs no escaping. The body is the raw encrypted file (`application/octet-stream`), exactly what the app's "Export encrypted" shows as base64 text, decoded.

| Request | Meaning | Responses |
|---|---|---|
| `GET <url>/<name>` | read | `200` raw bytes with `ETag`; `404` does not exist |
| `PUT <url>/<name>` with `If-None-Match: *` | create | `201` with `ETag`; `412` already exists |
| `PUT <url>/<name>` with `If-Match: "<etag>"` | replace | `200` with the new `ETag`; `412` other version or does not exist |
| `DELETE <url>/<name>` with `If-Match: "<etag>"` | delete (passphrase change) | `204`; `412` other version or does not exist |

- **ETag** is an opaque version of the stored file, in quotes (the Firebase function uses the Cloud Storage object generation). It must change with every write. **All** responses carry `Cache-Control: no-store` (a cached version would defeat the conflict detection). Also send `X-Content-Type-Options: nosniff` on every response, and on `GET` `Content-Security-Policy: default-src 'none'; sandbox` and `Content-Disposition: attachment`: the bytes are not a web page, and they must never be executed if the server shares the web app's origin.
- **Conditions are mandatory and atomic.** Two devices that read the same version and both write must not both succeed: exactly one gets `200`/`201`, the other `412` and then reads, merges and writes again. Creating is separate from replacing so that a device cannot silently re-create a file that another device deleted after a passphrase change.
- `PUT` without `If-Match` and without `If-None-Match: *`, and `DELETE` without `If-Match`: `428`. `PUT` with both headers: `400`.
- Send `PUT` with `Content-Type: application/octet-stream`. The Firebase function runs behind the Functions Framework, which parses bodies by content type before the function sees them: `application/json`, `application/x-www-form-urlencoded` and `text/*` are parsed, and a body that is not valid for that type is rejected with `400` or `413` (for example, `curl --data-binary` without a `Content-Type` header sends `application/x-www-form-urlencoded`, which fails for files from about 400 KB on). The function reads a request without any `Content-Type` itself, but do not rely on that: always send `application/octet-stream`.
- Empty `PUT` body: `400`. Body over 16 MiB (16 * 1024 * 1024 bytes): `413`.
- A name that does not match `^[A-Za-z0-9_-]{43}$`: `404`. Other methods: `405`. There is no endpoint that lists names.
- `429` with `Retry-After` is understood as rate limiting by the app; any other status is "not synced" and is tried again later.
- Browsers: answer the preflight, allow `If-Match` and `If-None-Match`, and send `Access-Control-Expose-Headers: ETag`, otherwise the web app cannot read the version. (Not needed if the server shares the web app's origin.)
- The Firebase function additionally answers `503` with `Retry-After: 1` on `GET` if the file was overwritten three times in a row while it was being read, and accepts the path `/ucdb/<name>` besides `/<name>` (the Hosting rewrite keeps the `/ucdb` prefix).
- Never log names or contents.

Examples:

```bash
URL=https://<project-id>.web.app/ucdb
NAME=<43 characters>

CT='Content-Type: application/octet-stream'

curl -i -X PUT -H "$CT" -H 'If-None-Match: *' --data-binary @file.bin "$URL/$NAME"   # 201, ETag: "..."
curl -i "$URL/$NAME"                                                                  # 200
curl -i -X PUT -H "$CT" -H 'If-Match: "<etag>"' --data-binary @file.bin "$URL/$NAME"  # 200 or 412
curl -i -X DELETE -H 'If-Match: "<etag>"' "$URL/$NAME"                                # 204 or 412
```

## Security notes

The server has **no authentication**, by design: the only configuration in the app is the URL.

- **Reading** is harmless: the file is encrypted, and the name has 256 bits and cannot be guessed. There is no listing.
- **Overwriting and deleting**: anyone who knows the URL and the database name can overwrite or delete the server copy. That includes everyone who has ever seen an export or a sync log that contained the name (the app never puts the full name into its log). The encryption and the two MACs detect any manipulation: the app then shows "not synced", writes nothing, and your **local copy stays intact**. The server copy is lost, though; sync again from a device that has the data (create the file again under "Sync server").
- **Storage costs**: anyone can store data under any valid name, up to 16 MiB each, and so fill your bucket. Counter-measures: the budget alert, `maxInstances: 2`, the 16 MiB limit. Check the bucket from time to time (`ucdb/` in the default bucket) and delete what you do not recognise.
- **Optional secret path part** (not built in, only described): a random segment in the URL, for example `https://<project-id>.web.app/ucdb/<random>/<name>`, keeps out everyone who does not know it, and costs nothing in the app, which only takes the URL. It protects only as long as the URL stays secret; the URL is stored encrypted in the database, but it shows up in your browser history, in server logs and anywhere you paste it. The function as shipped accepts only `/<name>` and `/ucdb/<name>`, so this variant needs a change in `nameFromPath` in `handler.js` and in the rewrite in `firebase.json`, that is, a code change in your fork.
- **Transport**: use `https://` (the app accepts `http://` only for `localhost`, for the Firebase emulator).
- **Deploy access**: the service account can deploy code into your project. The attribute condition in step 2 restricts it to your repository and `master`. Review what you merge from upstream before it deploys, as you would with any dependency.
- **Which web app?** A web page is delivered fresh on every visit, so whoever serves it controls the code that sees your passphrase. Serve it from your own project (this setup), not from someone else's. See [security.md](security.md#8-trust-and-builds).

## Items to verify

Confirmed on 2026-11-07 against a real deploy (Firebase CLI 15.35.0, 2nd-generation function in `europe-west1`, Hosting rewrite `/ucdb/**`):

- **Header forwarding through Hosting.** The rewrite passes `If-Match`, `If-None-Match` and `ETag` through unchanged and does not cache: responses showed `x-cache: MISS` and `Cache-Control: no-store`.
- **Request body limit through the rewrite.** A 16 MiB upload through the Hosting rewrite works (`201`); 17 MiB is answered with `413`.
- **Function address.** A 2nd-generation deploy is reachable at `https://europe-west1-<project-id>.cloudfunctions.net/ucdb` and at `https://ucdb-<hash>-ew.a.run.app` (the latter without a `/ucdb` suffix; see [the variant](#variant-the-function-only-without-hosting)).

Still open; check these against the current Firebase and Google Cloud documentation before relying on them:

- **Least-privilege deploy roles.** The role list in step 2 is broad. The minimum set (in particular for the Artifact Registry cleanup policy, see [above](#first-deploy-the-cleanup-policy), and for the source bucket) is not verified.
- **Billing and free tier.** Which Cloud Storage, Cloud Functions and Hosting usage stays free depends on region and current terms (new buckets: free tier only in US regions).
- **Concurrency and memory.** The function is configured with 512 MiB and a concurrency of 4 per instance (at most 2 instances); whether four simultaneous 16 MiB uploads fit into 512 MiB (body, upload copy and buffers) is estimated, not measured. Realistic databases are far smaller (well under a megabyte).
