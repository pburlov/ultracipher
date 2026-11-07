'use strict';

// Sync-Server (REST) fuer Ultracipher: reine Protokoll-Logik ohne Firebase-
// Imports. `bucket` ist ein Cloud-Storage-Bucket (@google-cloud/storage) oder
// ein Fake mit denselben Methoden (siehe handler.test.js). Das Protokoll steht
// in docs/self-hosting.md.
//
// Die Objekt-`generation` von Cloud Storage ist die Version (ETag). Die
// Bedingungen (`ifGenerationMatch`, 0 = darf nicht existieren) wertet Cloud
// Storage atomar aus.

const NAME = /^[A-Za-z0-9_-]{43}$/;
const MAX_BYTES = 16 * 1024 * 1024;
const GET_ATTEMPTS = 3;
const GENERATION = /^[0-9]{1,20}$/;
const OCTET_STREAM = 'application/octet-stream';

// `/<name>` (direkter Funktionsaufruf) oder `/ucdb/<name>` (Hosting-Rewrite);
// alles andere (auch ein abschliessender `/`) ist kein gueltiger Pfad.
function nameFromPath(path) {
  if (typeof path !== 'string') return null;
  const m = /^\/(?:ucdb\/)?([^/]+)$/.exec(path);
  return m && NAME.test(m[1]) ? m[1] : null;
}

// ETag-Wert ("123", W/"123" oder 123) -> Generation als Ziffernfolge, sonst null.
function parseEtag(value) {
  if (typeof value !== 'string') return null;
  const m = /^\s*(?:W\/)?"?([0-9]{1,20})"?\s*$/.exec(value);
  return m && GENERATION.test(m[1]) ? m[1] : null;
}

function header(req, name) {
  const value = req.headers && req.headers[name];
  if (Array.isArray(value)) return value.join(', ');
  return typeof value === 'string' ? value : undefined;
}

// Der Body-Parser des Functions-Frameworks fuellt rawBody nur, wenn die Anfrage
// einen Content-Type hat. Ohne Content-Type (so sendet z. B. Dart http Bytes)
// bleibt der Strom unberuehrt; dann wird er hier gelesen, hoechstens bis zum
// Limit + 1 Byte (reicht fuer 413).
async function readBody(req) {
  if (Buffer.isBuffer(req.rawBody)) return req.rawBody;
  if (Buffer.isBuffer(req.body)) return req.body;
  if (typeof req[Symbol.asyncIterator] !== 'function') return null;
  const chunks = [];
  let total = 0;
  for await (const chunk of req) {
    chunks.push(Buffer.from(chunk));
    total += chunk.length;
    if (total > MAX_BYTES) break;
  }
  return Buffer.concat(chunks);
}

function send(res, status, body) {
  res.status(status).end(body);
}

// Die Generation der gerade geschriebenen Version. Fehlt sie, ist das ein
// Fehler (500): ein ungepinnter getMetadata-Aufruf koennte die Generation eines
// anderen Schreibers liefern.
function generationAfterSave(file) {
  const known = file.metadata && file.metadata.generation;
  if (known === undefined || known === null || !GENERATION.test(String(known))) {
    throw new Error('generation missing after save');
  }
  return String(known);
}

function createHandler(bucket, options = {}) {
  const log = options.log || ((...args) => console.error(...args));

  async function get(res, path) {
    for (let attempt = 0; attempt < GET_ATTEMPTS; attempt++) {
      let generation;
      try {
        const [meta] = await bucket.file(path).getMetadata();
        generation = String(meta.generation);
      } catch (e) {
        if (Number(e && e.code) === 404) return send(res, 404);
        throw e;
      }
      try {
        // Die Generation steckt im File-Objekt: download() selbst nimmt keine
        // Generation als Option an.
        const [bytes] = await bucket.file(path, { generation }).download();
        res.set('ETag', `"${generation}"`);
        res.set('Content-Type', OCTET_STREAM);
        // Fremde Bytes unter dem Origin der App: nie als Seite ausfuehren.
        res.set('Content-Security-Policy', "default-src 'none'; sandbox");
        res.set('Content-Disposition', 'attachment');
        return send(res, 200, bytes);
      } catch (e) {
        // 404 auf die gelesene Generation: zwischen Metadaten und Download
        // wurde die Datei ueberschrieben (oder geloescht). Neu versuchen.
        if (Number(e && e.code) === 404) continue;
        throw e;
      }
    }
    // Die Datei wurde dreimal hintereinander ueberschrieben: kein "fehlt"
    // melden, sondern ein vorlaeufiger Fehler (die App zeigt "nicht synchron").
    res.set('Retry-After', '1');
    return send(res, 503);
  }

  async function put(req, res, path) {
    // Zu grosse Anfrage gleich abweisen, ohne den Body zu lesen.
    const declared = header(req, 'content-length');
    if (declared !== undefined && /^[0-9]+$/.test(declared.trim()) && Number(declared) > MAX_BYTES) {
      return send(res, 413);
    }
    const body = await readBody(req);
    if (!body || body.length === 0) return send(res, 400);
    if (body.length > MAX_BYTES) return send(res, 413);

    const ifNoneMatch = header(req, 'if-none-match');
    const ifMatch = header(req, 'if-match');
    if (ifNoneMatch !== undefined && ifMatch !== undefined) return send(res, 400);

    let match;
    if (ifNoneMatch !== undefined) {
      // Nur "*" (anlegen) gibt es; andere Werte sind keine Bedingung dieses Protokolls.
      if (ifNoneMatch.trim() !== '*') return send(res, 428);
      match = 0;
    } else if (ifMatch !== undefined) {
      // Kein gueltiger ETag: kann zu keiner Version passen.
      match = parseEtag(ifMatch);
      if (match === null) return send(res, 412);
    } else {
      return send(res, 428);
    }

    const file = bucket.file(path);
    await file.save(body, {
      resumable: false,
      contentType: OCTET_STREAM,
      // Sonst loescht die Bibliothek bei einer CRC32C-Abweichung die Datei
      // OHNE ifGenerationMatch (file.js, _File_validateIntegrity).
      validation: false,
      preconditionOpts: { ifGenerationMatch: match },
    });
    res.set('ETag', `"${generationAfterSave(file)}"`);
    return send(res, match === 0 ? 201 : 200);
  }

  async function remove(req, res, path) {
    const ifMatch = header(req, 'if-match');
    if (ifMatch === undefined) return send(res, 428);
    const generation = parseEtag(ifMatch);
    if (generation === null) return send(res, 412);
    await bucket.file(path).delete({ ifGenerationMatch: generation });
    return send(res, 204);
  }

  return async function handler(req, res) {
    // Ohne diesen Header sieht die Web-App den ETag nicht (CORS).
    res.set('Access-Control-Expose-Headers', 'ETag');
    // Fuer alle Antworten: nie cachen, kein Content-Type-Raten.
    res.set('Cache-Control', 'no-store');
    res.set('X-Content-Type-Options', 'nosniff');
    const name = nameFromPath(req.path);
    if (name === null) return send(res, 404);
    const path = `ucdb/${name}`;
    try {
      switch (req.method) {
        case 'GET':
          return await get(res, path);
        case 'PUT':
          return await put(req, res, path);
        case 'DELETE':
          return await remove(req, res, path);
        default:
          res.set('Allow', 'GET, PUT, DELETE');
          return send(res, 405);
      }
    } catch (e) {
      const code = Number(e && e.code);
      if (code === 412) return send(res, 412);
      // Datei fehlt bei DELETE: fuer den Client ein Versionskonflikt. Bei PUT
      // und GET kommt ein 404 aus dem Speicher nur, wenn z. B. der Bucket fehlt
      // (PUT mit Bedingung liefert 412): das ist ein Serverfehler (500).
      if (code === 404 && req.method === 'DELETE') return send(res, 412);
      // Nie Name, Pfad, Inhalt oder die Fehlermeldung loggen (kann den Pfad
      // enthalten), nur Methode und Code.
      log('ucdb', req.method, Number.isFinite(code) ? code : 'error');
      return send(res, 500);
    }
  };
}

module.exports = { createHandler, nameFromPath, parseEtag, readBody, MAX_BYTES };
