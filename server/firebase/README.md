# Ultracipher sync server (Firebase)

Cloud Function (2nd generation, Node.js 22) that stores the encrypted database in Cloud Storage and implements the REST protocol of the "Sync server" option. Deployment, setup, protocol and security notes: [docs/self-hosting.md](../../docs/self-hosting.md).

- `functions/handler.js`: the protocol, without Firebase imports (testable).
- `functions/index.js`: wiring to Firebase and the default bucket.
- `functions/handler.test.js`: tests with a fake bucket; `cd functions && npm test` (no `npm install` needed).
- `../../firebase.json`: Hosting plus the rewrite `/ucdb/**` to the function.
