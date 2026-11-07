# Ultracipher sync server (Firebase)

Cloud Function (2nd generation, Node.js 22) that stores the encrypted database in Cloud Storage and implements the REST protocol of the "Sync server" option. Deployment (from your own machine, there is no deploy workflow), setup, protocol and security notes: [docs/self-hosting.md](../../docs/self-hosting.md).

- `functions/handler.js`: the protocol, without Firebase imports (testable): secret path prefix, format check, in-memory rate limits per database name and a file cap (options of `createHandler`; `optionsFromEnv` maps the `UCDB_*` environment variables to them).
- `functions/index.js`: wiring to Firebase and the default bucket; settings come from `process.env.UCDB_*`.
- `functions/handler.test.js`: tests with a fake bucket; `cd functions && npm test` (no `npm install` needed).
- `functions/.env.example`: template for the per-project settings (`.env.<project-id>`, not committed).
- `../../firebase.json`: Hosting plus the rewrite `/ucdb*/**` (the path prefix `ucdb` or `ucdb-<secret>`) to the function.

Abuse limits and the secret path: [docs/self-hosting.md](../../docs/self-hosting.md#abuse-limits-and-a-secret-path).
