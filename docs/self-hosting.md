# Self-hosting: web app and Sync server on Firebase

Ultracipher has no server of its own, and this project does not run a public one. If you want to sync your encrypted database through a plain REST service instead of GitHub, you run the small function in [`server/firebase/`](../server/firebase/) yourself. The same Firebase project can also serve the web app, which is the recommended setup: web app and server then share one origin, so the page's Content-Security-Policy and CORS need no changes.

The server only ever stores the encrypted file (the same bytes the GitHub file `<name>.txt` holds, without base64). It has no accounts and no authentication; read [Security notes](#security-notes) before you use it.

## Contents

1. [The fork model](#the-fork-model)
2. [Create the Firebase project](#1-create-the-firebase-project)
3. [Deploy from your own machine](#2-deploy-from-your-own-machine)
4. [Use it in the app](#3-use-it-in-the-app)
5. [Updating your fork](#updating-your-fork)
6. [Variant: the function only, without Hosting](#variant-the-function-only-without-hosting)
7. [The protocol](#the-protocol-for-your-own-implementation)
8. [Abuse limits and a secret path](#abuse-limits-and-a-secret-path)
9. [Security notes](#security-notes)
10. [Items to verify](#items-to-verify)

## The fork model

- `ultracipher` (upstream) contains everything: the app, the function and [`firebase.json`](../firebase.json). There is no deploy workflow: **everyone deploys from their own machine** with the Firebase CLI (step 2), so no deploy credentials ever sit in a repository.
- You fork the repository (or clone it) and **change no code**. Everything that is yours lives in your Firebase project and in a local, uncommitted file `server/firebase/functions/.env.<project-id>` (secret path prefix and limits, see [Abuse limits and a secret path](#abuse-limits-and-a-secret-path)). Because the fork has no changes of its own, it can be brought up to date without merge conflicts (see [Updating your fork](#updating-your-fork)).
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

Enable the APIs the deploy uses (the deploy tries to enable missing ones itself; doing it once up front avoids a failed first run):

```bash
PROJECT=your-project-id
gcloud services enable --project="$PROJECT" \
  cloudfunctions.googleapis.com cloudbuild.googleapis.com \
  artifactregistry.googleapis.com run.googleapis.com \
  firebasehosting.googleapis.com firebase.googleapis.com \
  storage.googleapis.com cloudresourcemanager.googleapis.com \
  serviceusage.googleapis.com iam.googleapis.com
```

## 2. Deploy from your own machine

Prerequisites:

- Flutter in the version that `.github/workflows/pages.yml` pins (`flutter-version`, currently 3.47.8), for the web build.
- Node 22 (the function's runtime; `engines` in `server/firebase/functions/package.json`).
- The Firebase CLI (`firebase-tools`; tested with `15.35.0`, for example `npm install -g firebase-tools@15.35.0`), and `firebase login` once. The account needs deploy rights in the project (Owner or Editor is enough for your own project).
- Optional: your settings in `server/firebase/functions/.env.<project-id>` (secret path prefix, limits), see [Abuse limits and a secret path](#abuse-limits-and-a-secret-path).

From the repository root:

```bash
cd ultracipher_flutter && flutter pub get && flutter build web --wasm --no-web-resources-cdn --base-href "/" && cd ..
cd server/firebase/functions && npm ci && npm test && cd ../../..
firebase deploy --only hosting,functions --project <project-id>
```

[`firebase.json`](../firebase.json) is read from the repository root and expects the build in `ultracipher_flutter/build/web`. It serves the build from Hosting and rewrites `/ucdb*/**` (the path prefix `ucdb` or `ucdb-<anything>`, see [Abuse limits and a secret path](#abuse-limits-and-a-secret-path)) to the function `ucdb` (region `europe-west1`); there is no `.firebaserc` in the repository, the project ID comes from `--project`. The same file sets `Content-Security-Policy: frame-ancestors 'none'` and `X-Frame-Options: DENY` on the web app, so it cannot be embedded in a frame (clickjacking). The first deploy can end with an error about the cleanup policy; see below.

### First deploy: the cleanup policy

The first functions deploy of a project ends with the error `Functions successfully deployed but could not set up cleanup policy`, although the function **is** deployed. The Firebase CLI wants a policy that deletes old container images (otherwise images pile up and cost a small monthly amount) and cannot always ask for it. Because the deploy stops there, Hosting may not have been published. Set the policy once, and finish Hosting if needed:

```bash
firebase functions:artifacts:setpolicy --project <project-id> --location europe-west1   # deletes images older than 1 day
firebase deploy --only hosting --project <project-id>
```

Later deploys do not ask again. In an interactive run (the commands above, in a terminal) the CLI asks for the number of days instead; `--force` accepts the default (1 day) without asking.

## 3. Use it in the app

Open a database, menu **Sync server**, choose **Sync server (REST)** and enter

```
https://<project-id>.web.app/<prefix>
```

with no trailing slash. `<prefix>` is the secret path prefix of your function: `ucdb` if you configured nothing, otherwise the value of `UCDB_PREFIX` (see [Abuse limits and a secret path](#abuse-limits-and-a-secret-path); the function accepts no other path). The native apps and the web app use the same URL. The URL is stored encrypted inside the database and travels to your other devices with the sync, like the GitHub settings.

## Updating your fork

Your fork contains no changes of its own, so updating is a fast-forward. Nothing deploys by itself: after updating, deploy again as in step 2.

- On GitHub: open your fork, "Sync fork", "Update branch", then `git pull` on your machine.
- Or locally:

  ```bash
  git remote add upstream https://github.com/pburlov/ultracipher.git   # once
  git pull upstream master
  git push
  ```

If your repository is a copy and not a GitHub fork (for example because you already had a repository), the `upstream` remote works the same way. Your `.env.<project-id>` is not committed and stays as it is. Review what you pull from upstream before you deploy it, as with any dependency.

## Variant: the function only, without Hosting

If you host the web app elsewhere (for example with the Pages workflow) or only use the native apps, you can deploy the function alone. Nothing in the repository changes for the native apps.

```bash
cd ultracipher/server/firebase/functions && npm ci && cd ../../..
npx firebase-tools@15.35.0 login
npx firebase-tools@15.35.0 deploy --only functions --project your-project-id
```

The URL for the app is then the function's own address, which the deploy prints, followed by the path prefix: either `https://europe-west1-<project-id>.cloudfunctions.net/ucdb/<prefix>` or `https://ucdb-<hash>-ew.a.run.app/<prefix>` (both forms of the address observed; the function itself sits at the root of its address, so in the second form `/ucdb` is not part of the address; in the first it is the function name). `<prefix>` is `ucdb` or your `UCDB_PREFIX`. Enter it under "Sync server" without a trailing slash.

**Breaking change for earlier "function only" setups:** the function used to accept the bare path `/<name>`. It no longer does (the secret prefix would be bypassable through the function's own address). If you entered `https://europe-west1-<project-id>.cloudfunctions.net/ucdb` or the `run.app` address in the app, append `/ucdb` (or your prefix) there, in the database's sync server settings of every device.

For the **web** app the page's Content-Security-Policy must allow this host. Add it to `connect-src` in [`ultracipher_flutter/web/index.html`](../ultracipher_flutter/web/index.html), for example:

```
connect-src 'self' https://api.github.com https://europe-west1-<project-id>.cloudfunctions.net
```

This is the only code change a fork ever needs, and it makes the fork differ from upstream (you then merge on updates instead of fast-forwarding). The function answers CORS preflight requests and exposes the `ETag` header, so no change is needed there. The native apps are not subject to the Content-Security-Policy.

## The protocol (for your own implementation)

Anything that implements this can serve as a sync server; the Firebase function is one implementation. `<url>` is the base URL entered in the app, without trailing slash (for the Firebase function that includes the path prefix, `https://<project-id>.web.app/<prefix>`); `<name>` is the database name, 43 characters of base64url (`[A-Za-z0-9_-]`), which needs no escaping. The body is the raw encrypted file (`application/octet-stream`), exactly what the app's "Export encrypted" shows as base64 text, decoded.

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
- `429` with `Retry-After` (seconds) is understood as rate limiting by the app, which shows "not synced" with the waiting time; any other status is "not synced" and is tried again later. The Firebase function uses it for its [abuse limits](#abuse-limits-and-a-secret-path).
- Browsers: answer the preflight, allow `If-Match` and `If-None-Match`, and send `Access-Control-Expose-Headers: ETag`, otherwise the web app cannot read the version. (Not needed if the server shares the web app's origin.)
- The Firebase function additionally answers `503` with `Retry-After: 1` on `GET` if the file was overwritten three times in a row while it was being read, and accepts only the path `/<prefix>/<name>` (the Hosting rewrite keeps the whole path, prefix included, see [Abuse limits and a secret path](#abuse-limits-and-a-secret-path)). A `PUT` body that does not look like an Ultracipher format v1 file is answered with `400` there. Your own implementation may skip all of this.
- Never log names or contents.

Examples:

```bash
URL=https://<project-id>.web.app/<prefix>
NAME=<43 characters>

CT='Content-Type: application/octet-stream'

curl -i -X PUT -H "$CT" -H 'If-None-Match: *' --data-binary @file.bin "$URL/$NAME"   # 201, ETag: "..."
curl -i "$URL/$NAME"                                                                  # 200
curl -i -X PUT -H "$CT" -H 'If-Match: "<etag>"' --data-binary @file.bin "$URL/$NAME"  # 200 or 412
curl -i -X DELETE -H 'If-Match: "<etag>"' "$URL/$NAME"                                # 204 or 412
```

## Abuse limits and a secret path

There is no login, so the function is public. Without further measures anyone who finds the URL could use your bucket as free storage, or run up the bill with many uploads (storage grows with every new name) and many downloads (egress: upload a 16 MiB file once, then read it over and over). The function therefore has four cheap protections. None of them needs a database or an account; they limit the cost, not the availability (see the end of this section).

**1. Secret path prefix.** The function only answers paths of the form `/<prefix>/<name>`; everything else, including the bare `/<name>`, is refused without touching the bucket: the function answers `404`; through Hosting a path that does not match the rewrite `/ucdb*/**` (such as the bare `/<name>`) never reaches the function and ends in the web app's fallback (`200` with `index.html`), so `404` is what you see on the function's own address. The prefix must match `^ucdb[A-Za-z0-9_-]{0,64}$` (it has to start with `ucdb` because the Hosting rewrite in `firebase.json` is `/ucdb*/**`). The default is `ucdb`, which is public knowledge (it is in this repository), so choose your own. A long random value works; `ucdb74` can be guessed. For example:

```bash
echo "UCDB_PREFIX=ucdb-$(openssl rand -base64 18 | tr '+/' '-_')"
```

The files in the bucket stay at `ucdb/<name>` whatever the prefix is, so changing the prefix does not orphan stored files. If the configured prefix is invalid, the function answers every request with `500` and logs `bad-prefix` (never the value).

The app URL is then `https://<project-id>.web.app/<prefix>` (or, for the function only, see [the variant](#variant-the-function-only-without-hosting)). The prefix is only as secret as the URL: the URL is stored encrypted in the database, but it appears in browser history, logs and wherever you paste it, and every device that syncs knows it. Rotating it means changing the value, deploying again and entering the new URL in the app on each device.

**2. Format check on upload.** A `PUT` body must look like an Ultracipher format v1 file, otherwise the answer is `400` before any storage access: magic `UCDB`, version 1, suite 1, KDF profile 1, flags 0 (16-bit big-endian fields at offsets 4, 6, 8 and 10 of the 44-byte header), and a total length of 44 + n + 96 bytes with n a multiple of 16 and at least 16 (so at least 156 bytes). This keeps out programs that just want to store arbitrary files. It is **not** authentication: the function has no key and cannot check the MACs, and anyone who builds a matching header in front of random bytes passes. Because of the length arithmetic, the largest accepted file is 16 MiB minus 4 bytes (16,777,212 bytes), not exactly 16 MiB.

**3. Rate limits and a file cap.** The limits are fixed time windows kept in memory per function instance, no external store. The function runs with at most 2 instances, so the effective limits are up to twice as large, and the counters start again whenever an instance is restarted (cold start, redeploy). Writes and reads are counted **per database name**: the 43-character name cannot be guessed, so a stranger cannot use up the allowance of your database. There is deliberately **no global cap for reading or writing**, because created files stay: an attacker could collect names of their own over the days and use any global cap up against you. What is global is only the creation of new files, and a hard cap on how many files exist at all.

A request counts only after it passed the earlier checks (path, prefix, name, size, format, conditions): rejected junk costs nothing against any budget, and no counter is created for it. Writes are counted per name only when the storage accepted them: a `PUT` or `DELETE` that the storage refuses (`412` stale or missing version, `404`, an error) gives its reservation back and leaves no counter behind for a made-up name, so requests with invented names cannot push the counter of a real name out of the bounded map. The global creation counter is different: a `PUT` with `If-None-Match: *` that the storage then answers with `412` (the file already exists) stays counted. A version header of `0` (or with leading zeros) is refused with `412` before anything else: for Cloud Storage `0` means "must not exist", which would otherwise be a way to create a file past the creation limit and the file cap. Over a limit the answer is `429` with `Retry-After` (seconds until the window ends); the app shows "not synced" with that waiting time and keeps your local copy.

| Setting | Default | Window | Scope | Counts |
|---|---|---|---|---|
| `UCDB_CREATES_PER_DAY` | 10 | 24 h | global | `PUT` with `If-None-Match: *` (new file) |
| `UCDB_WRITES_PER_HOUR_PER_NAME` | 60 | 1 h | per name | `PUT` (create and replace) and `DELETE` |
| `UCDB_READ_MIB_PER_HOUR_PER_NAME` | 32 | 1 h | per name | bytes of `GET` responses |
| `UCDB_MAX_FILES` | 20 | none | global | files under `ucdb/` in the bucket |

- **Read budget.** It is checked against the stored size before the file is read, so a refused read pulls nothing from storage. The function raises a smaller value to 16 MiB, because a stored file larger than a whole read budget could never be read (always `429`).
- **File cap (`UCDB_MAX_FILES`).** Before a new file is created (after all the checks above, before anything is stored), the function lists the objects under `ucdb/` (at most `max + 1` names, no paging; `UCDB_MAX_FILES` is limited to 999 because one list page of Cloud Storage holds at most 1000 entries). With `max` or more files the answer is `507 Insufficient Storage`, not `429`, because waiting does not help; the log line is `ucdb max-files` (no name). Replacing, reading and deleting existing files keep working at the cap. Two creations at the same moment can exceed the cap by a few files (there is no lock between counting and storing); that is accepted. The cap counts **all** files in the bucket under `ucdb/`, yours included: 20 is plenty for a few databases, raise it if you keep more. In the app a `507` is a general sync error (the sync shows "not synced"), not a waiting time.
- **Counter memory.** The per-name counters live in a map from name to window that is bounded (10,000 entries; expired windows are dropped, and above the bound the name that was least recently used is dropped, which only resets its counter, and only after a successful write or read of a real file). Requests with made-up names cannot fill the memory.

What an attacker can reach, and what not:

- **Your database's allowances are out of reach without its name** (writes and reads are per name).
- **The only good an attacker can use up globally is creating files** (10 a day, and the file cap). This affects you only when you create a new database or change the passphrase, which is rare. If the cap is full of foreign files, free it: list the objects and delete the ones that are not yours (the names are opaque, so go by the creation time, `gcloud storage ls -l`; a file of yours that you delete by mistake is created again from your local copy in the Sync server settings):

  ```bash
  gcloud storage ls -l gs://<bucket>/ucdb/
  gcloud storage rm gs://<bucket>/ucdb/<name>
  ```
- The secret prefix is the first hurdle and the recommended one: without the URL none of this is reachable.

Rough cost frame with the defaults (worst case, one attacker who knows the URL and fills the cap, 2 instances, counters never reset):

- **Storage:** at most `UCDB_MAX_FILES` x 16 MiB = 320 MiB in total (a few files more if creations race), and it does not grow by replacing (soft delete is off, see below).
- **Egress:** at most `UCDB_MAX_FILES` x read budget per name x 2 instances = 20 x 32 MiB x 2 = 1.25 GiB per hour, about 30 GiB per day. Through Firebase Hosting the traffic costs on the order of 0.15 USD per GB (check the current price for your project and region; Cloud Functions' own internet egress is cheaper), so the worst case is roughly 4 to 5 dollars per day if it runs around the clock; budget alert, and the cap lowered with `UCDB_MAX_FILES` or `UCDB_READ_MIB_PER_HOUR_PER_NAME`, bound it further.
- **Writes:** storage operations cost very little (order of 0.005 USD per 1,000); per name at most 2 x 60 per hour, and the number of invocations is bounded by `maxInstances: 2` and `concurrency: 4`.

Lower the values if you need less, for example one person with two devices: `UCDB_MAX_FILES=5`, `UCDB_CREATES_PER_DAY=3`.

**4. Soft delete off.** New Cloud Storage buckets keep deleted and overwritten objects for 7 days (soft delete) and bill for them. Then every overwrite of a 16 MiB file would add 16 MiB of storage for a week, which defeats the point of the file cap. Switch it off for the bucket:

```bash
gcloud storage buckets update gs://<bucket> --clear-soft-delete
```

(the bucket is `<project-id>.firebasestorage.app`, see step 1.4). Your own data is covered by the local copy on your devices and by the merge; the function offers no restore anyway.

### Setting the values

The function reads `UCDB_PREFIX`, `UCDB_CREATES_PER_DAY`, `UCDB_WRITES_PER_HOUR_PER_NAME`, `UCDB_READ_MIB_PER_HOUR_PER_NAME` and `UCDB_MAX_FILES` from its environment (`process.env`; a missing, empty or invalid number means the default; an invalid prefix makes the function answer `500`). Put the ones you want to change into `server/firebase/functions/.env.<project-id>`; the template [`.env.example`](../server/firebase/functions/.env.example) lists all of them with their defaults:

```bash
cp server/firebase/functions/.env.example server/firebase/functions/.env.<project-id>
# edit: remove the leading # of the lines you want to set
```

`.env*` files are not committed (only `.env.example` is), because the prefix is a secret. On `firebase deploy` the Firebase CLI reads `.env.<project-id>` and deploys the values as the environment of the function, so they do not need to be declared anywhere (no Firebase parameters are used: a parameter without a value in a dotenv file makes `firebase deploy --non-interactive` fail even if it has a default). The file lives on the machine that deploys; deploy from the same machine (or copy the file) when you update.

### What this does not do

- **Limits cap the cost, not the availability.** An attacker who knows the URL can use up the creation of new files and fill the file cap (see above); your database's own allowances (per-name writes and reads) are out of reach without its name. The app then shows "not synced" or a sync error, your local copy is untouched, and what is blocked is only the creation of a new database on the server. The secret prefix is what makes this unlikely; the limits make it cheap.
- **No hard cost stop.** A budget alert only notifies. If you want spending to stop by itself, Google describes a pattern with a budget notification (Pub/Sub) that triggers a function which disables billing: [Disable billing with notifications](https://cloud.google.com/billing/docs/how-to/disable-billing-with-notifications). That shuts down the whole project, so it is not set up here.
- **Overwriting and deleting** foreign databases is still possible for anyone who knows the URL and a name (see below); the prefix and the limits do not change that.

## Security notes

The server has **no authentication**, by design: the only configuration in the app is the URL.

- **Reading** is harmless: the file is encrypted, and the name has 256 bits and cannot be guessed. There is no listing.
- **Overwriting and deleting**: anyone who knows the URL and the database name can overwrite or delete the server copy. That includes everyone who has ever seen an export or a sync log that contained the name (the app never puts the full name into its log). The encryption and the two MACs detect any manipulation: the app then shows "not synced", writes nothing, and your **local copy stays intact**. The server copy is lost, though; sync again from a device that has the data (create the file again under "Sync server").
- **Storage and egress costs**: anyone who knows the URL can store data under any valid name, up to 16 MiB each, and read it back. Counter-measures: a [secret path prefix, a format check and rate limits](#abuse-limits-and-a-secret-path), the budget alert, `maxInstances: 2`, the 16 MiB limit. Check the bucket from time to time (`ucdb/` in the default bucket) and delete what you do not recognise.
- **Transport**: use `https://` (the app accepts `http://` only for `localhost`, for the Firebase emulator).
- **Deploy access**: you deploy with your own login from your own machine; no workflow and no repository variable holds deploy credentials. Review what you merge from upstream before you deploy it, as you would with any dependency.
- **Which web app?** A web page is delivered fresh on every visit, so whoever serves it controls the code that sees your passphrase. Serve it from your own project (this setup), not from someone else's. See [security.md](security.md#8-trust-and-builds).

## Items to verify

Confirmed on 2026-11-07 against a real deploy (Firebase CLI 15.35.0, 2nd-generation function in `europe-west1`, Hosting rewrite `/ucdb/**`, the rewrite before the secret prefix was added):

- **Header forwarding through Hosting.** The rewrite passes `If-Match`, `If-None-Match` and `ETag` through unchanged and does not cache: responses showed `x-cache: MISS` and `Cache-Control: no-store`.
- **Request body limit through the rewrite.** A 16 MiB upload through the Hosting rewrite works (`201`); 17 MiB is answered with `413`.
- **Function address.** A 2nd-generation deploy is reachable at `https://europe-west1-<project-id>.cloudfunctions.net/ucdb` and at `https://ucdb-<hash>-ew.a.run.app` (the latter without a `/ucdb` suffix; see [the variant](#variant-the-function-only-without-hosting)).

Still open; check these against the current Firebase and Google Cloud documentation before relying on them:

- **Rewrite glob `/ucdb*/**` and the abuse limits on a real deploy.** The glob matches `/ucdb/x` and `/ucdb-<random>/x` with the matcher of the installed Firebase CLI (superstatic 10, minimatch), but has not yet been run against production Hosting; likewise the limits and the prefix have been tested against a fake bucket only. Check after the first deploy: a request to `/<prefix>/<name>` reaches the function, `/<name>` gets `404`, the 11th creation within a day gets `429`, with `UCDB_MAX_FILES` files in the bucket the next creation gets `507`, and `.env.<project-id>` values reach the function.
- **Billing and free tier.** Which Cloud Storage, Cloud Functions and Hosting usage stays free depends on region and current terms (new buckets: free tier only in US regions).
- **Concurrency and memory.** The function is configured with 512 MiB and a concurrency of 4 per instance (at most 2 instances); whether four simultaneous 16 MiB uploads fit into 512 MiB (body, upload copy and buffers) is estimated, not measured. Realistic databases are far smaller (well under a megabyte).
