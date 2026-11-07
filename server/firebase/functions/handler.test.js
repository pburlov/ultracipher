'use strict';

// Tests fuer handler.js mit einem Fake-Bucket (nur node:test, keine Firebase-
// Pakete). Der Fake bildet die Teile von Cloud Storage nach, auf die sich der
// Handler stuetzt: Generationen, ifGenerationMatch (0 = darf nicht existieren)
// und Fehler mit `err.code` 404/412 wie in @google-cloud/storage.

const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const assert = require('node:assert/strict');
const { Readable } = require('node:stream');
const { createHandler, looksLikeFormatV1, optionsFromEnv, parseEtag, NameWindows, MAX_BYTES, MIN_FILE_LENGTH } = require('./handler');

const NAME = 'A'.repeat(43);
const NAME2 = 'b-_'.repeat(14) + 'Z'; // 43 Zeichen, mit - und _

// Verstoesse des Handlers gegen den Speicher-Vertrag (der Handler faengt Fehler
// ab und meldet 500, ein Assertion-Fehler im Fake ginge sonst unter).
const violations = [];

function apiError(code) {
  return Object.assign(new Error(`fake ${code}`), { code });
}

class FakeBucket {
  constructor() {
    this.objects = new Map(); // Pfad -> { bytes, generation }
    this.nextGeneration = 1700000000000000;
    this.calls = 0;
    this.bucketMissing = false; // Bucket existiert nicht: jeder Zugriff 404
    this.existsCalls = 0;
    this.listCalls = []; // Optionen der getFiles-Aufrufe
    this.failWith = null; // naechster Aufruf wirft diesen Fehler
    this.afterMetadata = null; // Hook zwischen getMetadata und download
  }

  file(path, opts = {}) {
    const bucket = this;
    const pinned = opts.generation === undefined ? undefined : String(opts.generation);
    const file = {
      metadata: undefined,
      async getMetadata() {
        bucket.calls++;
        bucket._maybeFail();
        const o = bucket.objects.get(path);
        if (!o) throw apiError(404);
        const meta = { generation: o.generation, size: String(o.bytes.length) };
        if (bucket.afterMetadata) await bucket.afterMetadata();
        return [meta];
      },
      async download() {
        bucket.calls++;
        bucket._maybeFail();
        await Promise.resolve();
        const o = bucket.objects.get(path);
        // Eine ueberschriebene Generation gibt es nicht mehr.
        if (!o || (pinned !== undefined && o.generation !== pinned)) throw apiError(404);
        return [Buffer.from(o.bytes)];
      },
      async save(bytes, options) {
        bucket.calls++;
        bucket._maybeFail();
        await Promise.resolve(); // Platz fuer parallele Schreiber
        // Ohne Bedingung waere ein Schreibzugriff ein Ueberschreiben ohne
        // Versionspruefung: eigener Assertion-Fehler statt TypeError.
        if (!(options && options.preconditionOpts && options.preconditionOpts.ifGenerationMatch !== undefined)) {
          violations.push('save ohne ifGenerationMatch');
        }
        // Sonst loescht die Bibliothek bei CRC32C-Abweichung ohne Bedingung.
        if (!options || options.validation !== false) violations.push('save ohne validation: false');
        bucket._checkPrecondition(path, options.preconditionOpts);
        const generation = String(bucket.nextGeneration++);
        bucket.objects.set(path, { bytes: Buffer.from(bytes), generation });
        file.metadata = { generation };
      },
      async delete(options) {
        bucket.calls++;
        bucket._maybeFail();
        await Promise.resolve();
        if (!(options && options.ifGenerationMatch !== undefined)) violations.push('delete ohne ifGenerationMatch');
        if (!bucket.objects.has(path)) throw apiError(404);
        bucket._checkPrecondition(path, options);
        bucket.objects.delete(path);
      },
    };
    return file;
  }

  // Wie Bucket#getFiles({ prefix, maxResults, autoPaginate: false }): [files, nextQuery, apiResponse].
  async getFiles(options = {}) {
    this.listCalls.push(options);
    this._maybeFail();
    const files = [...this.objects.keys()]
      .filter((k) => k.startsWith(options.prefix || ''))
      .slice(0, options.maxResults === undefined ? Infinity : options.maxResults)
      .map((name) => ({ name }));
    return [files, null, {}];
  }

  // Wie Bucket#exists(): [boolean], wirft bei Fehlern (failWith) auch.
  async exists() {
    this.existsCalls++;
    this._maybeFail({ skipMissing: true });
    return [!this.bucketMissing];
  }

  _maybeFail({ skipMissing = false } = {}) {
    // Fehlender Bucket: dieselbe 404 wie bei einem fehlenden Objekt.
    if (this.bucketMissing && !skipMissing) throw apiError(404);
    if (this.failWith) {
      const e = this.failWith;
      this.failWith = null;
      throw e;
    }
  }

  _checkPrecondition(path, opts) {
    const o = this.objects.get(path);
    // GCS-Semantik: eine Generation, die nur aus Nullen besteht ("0", "00", ...),
    // heisst "darf nicht existieren"; sonst muss die Generation passen.
    const want = String(opts.ifGenerationMatch);
    if (/^0+$/.test(want) ? o !== undefined : !o || o.generation !== want) throw apiError(412);
  }

  // Stand ausserhalb des Handlers lesen.
  generationOf(name) {
    const o = this.objects.get(`ucdb/${name}`);
    return o && o.generation;
  }

  bytesOf(name) {
    const o = this.objects.get(`ucdb/${name}`);
    return o && o.bytes;
  }
}

function fakeRes() {
  const res = {
    statusCode: undefined,
    headers: {},
    body: undefined,
    ended: false,
    set(k, v) {
      res.headers[k.toLowerCase()] = v;
      return res;
    },
    status(c) {
      res.statusCode = c;
      return res;
    },
    end(b) {
      res.ended = true;
      res.body = b;
      return res;
    },
  };
  return res;
}

// `path` ist `/<name>`; call() setzt den Standardpraefix davor. `raw: true`
// schickt den Pfad unveraendert (Pfad- und Praefixtests).
async function call(handler, method, path, { headers = {}, body, raw = false } = {}) {
  const lower = {};
  for (const [k, v] of Object.entries(headers)) lower[k.toLowerCase()] = v;
  const req = { method, path: raw ? path : `/ucdb${path}`, headers: lower, rawBody: body };
  const res = fakeRes();
  await handler(req, res);
  assert.deepEqual(violations, [], 'Verstoss gegen den Speicher-Vertrag');
  assert.ok(res.ended, 'Antwort wurde abgeschlossen');
  return res;
}

function setup() {
  const bucket = new FakeBucket();
  const logs = [];
  const handler = createHandler(bucket, { log: (...a) => logs.push(a) });
  return { bucket, handler, logs };
}

// Eine Datei, die wie Format v1 aussieht (gueltiger Kopf, 16 B Ciphertext,
// Tag-Platzhalter); `seed` macht den Inhalt unterscheidbar. `blocks` = Anzahl
// 16-Byte-Bloecke des Ciphertexts.
function valid(seed = 'x', blocks = 1) {
  const b = Buffer.alloc(44 + 16 * blocks + 96, 0);
  b.write('UCDB', 0, 'latin1');
  b.writeUInt16BE(1, 4);
  b.writeUInt16BE(1, 6);
  b.writeUInt16BE(1, 8);
  b.writeUInt16BE(0, 10);
  const mark = Buffer.from(seed);
  for (let i = 12; i < b.length; i++) b[i] = mark[i % mark.length];
  return b;
}
const bytes = valid;

// Gueltiges v1-Format mit genau `length` Bytes (length - 140 muss durch 16 teilbar sein).
function validOfLength(length) {
  assert.equal((length - 140) % 16, 0);
  return valid('big', (length - 140) / 16);
}
const create = (h, data = 'one', name = NAME) =>
  call(h, 'PUT', `/${name}`, { headers: { 'If-None-Match': '*' }, body: bytes(data) });

test('GET: fehlende Datei -> 404', async () => {
  const { handler } = setup();
  const res = await call(handler, 'GET', `/${NAME}`);
  assert.equal(res.statusCode, 404);
  assert.equal(res.headers['access-control-expose-headers'], 'ETag');
});

test('GET: fehlende Datei -> 404, Bucket wird dafuer genau einmal geprueft', async () => {
  const { handler, bucket, logs } = setup();
  const res = await call(handler, 'GET', `/${NAME}`);
  assert.equal(res.statusCode, 404);
  assert.equal(bucket.existsCalls, 1);
  assert.deepEqual(logs, []);
});

test('GET: Normalfall prueft den Bucket nicht', async () => {
  const { handler, bucket } = setup();
  await create(handler);
  assert.equal((await call(handler, 'GET', `/${NAME}`)).statusCode, 200);
  assert.equal(bucket.existsCalls, 0);
});

test('GET: fehlender Bucket -> 500 (nicht 404), Log ohne Namen', async () => {
  const { handler, bucket, logs } = setup();
  bucket.bucketMissing = true;
  const res = await call(handler, 'GET', `/${NAME}`);
  assert.equal(res.statusCode, 500);
  assert.deepEqual(logs, [['ucdb', 'GET', 'bucket-missing']]);
  assert.ok(!JSON.stringify(logs).includes(NAME));
  assert.equal(res.headers['cache-control'], 'no-store');
});

test('GET: Bucket-Pruefung schlaegt selbst fehl -> 500 mit Code im Log', async () => {
  const { handler, bucket, logs } = setup();
  bucket.failWith = apiError(404); // getMetadata: 404
  const original = bucket.exists.bind(bucket);
  bucket.exists = async () => {
    bucket.failWith = apiError(503);
    return original();
  };
  const res = await call(handler, 'GET', `/${NAME}`);
  assert.equal(res.statusCode, 500);
  assert.deepEqual(logs, [['ucdb', 'GET', 503]]);
});

test('GET: 200 mit Rohbytes, ETag, no-store', async () => {
  const { handler, bucket } = setup();
  await create(handler, 'hello');
  const res = await call(handler, 'GET', `/${NAME}`);
  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.body, bytes('hello'));
  assert.equal(res.headers['etag'], `"${bucket.generationOf(NAME)}"`);
  assert.equal(res.headers['cache-control'], 'no-store');
  assert.equal(res.headers['content-type'], 'application/octet-stream');
  assert.equal(res.headers['x-content-type-options'], 'nosniff');
  assert.equal(res.headers['content-security-policy'], "default-src 'none'; sandbox");
  assert.equal(res.headers['content-disposition'], 'attachment');
  assert.equal(res.headers['access-control-expose-headers'], 'ETag');
});

test('PUT If-None-Match: * legt an (201, ETag), Speicherpfad ucdb/<name>', async () => {
  const { handler, bucket } = setup();
  const res = await create(handler, 'one');
  assert.equal(res.statusCode, 201);
  assert.equal(res.headers['etag'], `"${bucket.generationOf(NAME)}"`);
  assert.deepEqual(bucket.bytesOf(NAME), bytes('one'));
  assert.deepEqual([...bucket.objects.keys()], [`ucdb/${NAME}`]);
});

test('PUT If-None-Match: * bei existierender Datei -> 412, Inhalt bleibt', async () => {
  const { handler, bucket } = setup();
  await create(handler, 'one');
  const gen = bucket.generationOf(NAME);
  const res = await create(handler, 'two');
  assert.equal(res.statusCode, 412);
  assert.deepEqual(bucket.bytesOf(NAME), bytes('one'));
  assert.equal(bucket.generationOf(NAME), gen);
});

test('PUT If-Match ersetzt (200, neuer ETag)', async () => {
  const { handler, bucket } = setup();
  const created = await create(handler, 'one');
  const res = await call(handler, 'PUT', `/${NAME}`, {
    headers: { 'If-Match': created.headers['etag'] },
    body: bytes('two'),
  });
  assert.equal(res.statusCode, 200);
  assert.notEqual(res.headers['etag'], created.headers['etag']);
  assert.equal(res.headers['etag'], `"${bucket.generationOf(NAME)}"`);
  assert.deepEqual(bucket.bytesOf(NAME), bytes('two'));
});

test('PUT If-Match: schwacher und unquotierter ETag werden akzeptiert', async () => {
  const { handler, bucket } = setup();
  await create(handler, 'one');
  const weak = await call(handler, 'PUT', `/${NAME}`, {
    headers: { 'If-Match': `W/"${bucket.generationOf(NAME)}"` },
    body: bytes('two'),
  });
  assert.equal(weak.statusCode, 200);
  const bare = await call(handler, 'PUT', `/${NAME}`, {
    headers: { 'If-Match': bucket.generationOf(NAME) },
    body: bytes('three'),
  });
  assert.equal(bare.statusCode, 200);
});

test('PUT If-Match mit alter Version -> 412, Inhalt bleibt', async () => {
  const { handler, bucket } = setup();
  const first = await create(handler, 'one');
  await call(handler, 'PUT', `/${NAME}`, {
    headers: { 'If-Match': first.headers['etag'] },
    body: bytes('two'),
  });
  const res = await call(handler, 'PUT', `/${NAME}`, {
    headers: { 'If-Match': first.headers['etag'] },
    body: bytes('stale'),
  });
  assert.equal(res.statusCode, 412);
  assert.deepEqual(bucket.bytesOf(NAME), bytes('two'));
});

test('PUT If-Match auf fehlende Datei -> 412, legt nichts an', async () => {
  const { handler, bucket } = setup();
  const res = await call(handler, 'PUT', `/${NAME}`, {
    headers: { 'If-Match': '"1700000000000001"' },
    body: bytes('x'),
  });
  assert.equal(res.statusCode, 412);
  assert.equal(bucket.objects.size, 0);
});

test('PUT If-Match ohne gueltigen ETag -> 412, ohne Zugriff auf den Speicher', async () => {
  const { handler, bucket } = setup();
  for (const v of ['*', 'abc', '"1", "2"', '', '"12 3"']) {
    const res = await call(handler, 'PUT', `/${NAME}`, { headers: { 'If-Match': v }, body: bytes('x') });
    assert.equal(res.statusCode, 412, `If-Match ${JSON.stringify(v)}`);
  }
  assert.equal(bucket.calls, 0);
});

test('PUT ohne If-Match und If-None-Match -> 428', async () => {
  const { handler, bucket } = setup();
  const res = await call(handler, 'PUT', `/${NAME}`, { body: bytes('x') });
  assert.equal(res.statusCode, 428);
  const other = await call(handler, 'PUT', `/${NAME}`, {
    headers: { 'If-None-Match': '"5"' },
    body: bytes('x'),
  });
  assert.equal(other.statusCode, 428);
  assert.equal(bucket.calls, 0);
});

test('PUT mit beiden Bedingungen -> 400', async () => {
  const { handler, bucket } = setup();
  const res = await call(handler, 'PUT', `/${NAME}`, {
    headers: { 'If-None-Match': '*', 'If-Match': '"1"' },
    body: bytes('x'),
  });
  assert.equal(res.statusCode, 400);
  assert.equal(bucket.calls, 0);
});

test('PUT mit leerem oder fehlendem Body -> 400', async () => {
  const { handler, bucket } = setup();
  for (const body of [Buffer.alloc(0), undefined]) {
    const res = await call(handler, 'PUT', `/${NAME}`, { headers: { 'If-None-Match': '*' }, body });
    assert.equal(res.statusCode, 400);
  }
  assert.equal(bucket.calls, 0);
});

test('PUT: groesste gueltige Datei (16 MiB - 4) geht, MAX_BYTES + 1 -> 413, genau MAX_BYTES -> 400 (kein v1-Format)', async () => {
  const { handler, bucket } = setup();
  const ok = await call(handler, 'PUT', `/${NAME}`, {
    headers: { 'If-None-Match': '*' },
    body: validOfLength(MAX_BYTES - 4),
  });
  assert.equal(ok.statusCode, 201);
  const big = await call(handler, 'PUT', `/${NAME2}`, {
    headers: { 'If-None-Match': '*' },
    body: Buffer.alloc(MAX_BYTES + 1, 1),
  });
  assert.equal(big.statusCode, 413);
  assert.equal(bucket.bytesOf(NAME2), undefined);
  // 16 MiB passt nicht zur Laengenarithmetik (16777216 - 140 ist nicht durch 16 teilbar).
  const exact = await call(handler, 'PUT', `/${NAME2}`, {
    headers: { 'If-None-Match': '*' },
    body: Buffer.concat([validOfLength(MAX_BYTES - 4), Buffer.alloc(4)]),
  });
  assert.equal(exact.statusCode, 400);
  assert.equal(bucket.bytesOf(NAME2), undefined);
});

test('DELETE mit If-Match -> 204, danach 404', async () => {
  const { handler, bucket } = setup();
  const created = await create(handler);
  const res = await call(handler, 'DELETE', `/${NAME}`, { headers: { 'If-Match': created.headers['etag'] } });
  assert.equal(res.statusCode, 204);
  assert.equal(bucket.objects.size, 0);
  assert.equal((await call(handler, 'GET', `/${NAME}`)).statusCode, 404);
});

test('DELETE: alte Version oder fehlende Datei -> 412', async () => {
  const { handler, bucket } = setup();
  const first = await create(handler, 'one');
  await call(handler, 'PUT', `/${NAME}`, { headers: { 'If-Match': first.headers['etag'] }, body: bytes('two') });
  const stale = await call(handler, 'DELETE', `/${NAME}`, { headers: { 'If-Match': first.headers['etag'] } });
  assert.equal(stale.statusCode, 412);
  assert.deepEqual(bucket.bytesOf(NAME), bytes('two'));
  const missing = await call(handler, 'DELETE', `/${NAME2}`, { headers: { 'If-Match': '"1"' } });
  assert.equal(missing.statusCode, 412);
});

test('DELETE: fehlender Bucket -> 500 (nicht 412), Log ohne Namen; fehlende Datei bleibt 412', async () => {
  const { handler, bucket, logs } = setup();
  bucket.bucketMissing = true;
  const res = await call(handler, 'DELETE', `/${NAME}`, { headers: { 'If-Match': '"1"' } });
  assert.equal(res.statusCode, 500);
  assert.deepEqual(logs, [['ucdb', 'DELETE', 'bucket-missing']]);
  bucket.bucketMissing = false;
  logs.length = 0;
  const missing = await call(handler, 'DELETE', `/${NAME}`, { headers: { 'If-Match': '"1"' } });
  assert.equal(missing.statusCode, 412);
  assert.deepEqual(logs, []);
});

test('PUT: fehlender Bucket (Anlegen und Ersetzen) -> 500, Code 404 geloggt', async () => {
  for (const headers of [{ 'If-None-Match': '*' }, { 'If-Match': '"1"' }]) {
    const { handler, bucket, logs } = setup();
    bucket.bucketMissing = true;
    const res = await call(handler, 'PUT', `/${NAME}`, { headers, body: bytes('x') });
    assert.equal(res.statusCode, 500);
    assert.deepEqual(logs, [['ucdb', 'PUT', 404]]);
  }
});

test('DELETE ohne If-Match -> 428, mit ungueltigem ETag -> 412', async () => {
  const { handler, bucket } = setup();
  await create(handler);
  assert.equal((await call(handler, 'DELETE', `/${NAME}`)).statusCode, 428);
  assert.equal((await call(handler, 'DELETE', `/${NAME}`, { headers: { 'If-Match': 'x' } })).statusCode, 412);
  assert.equal(bucket.objects.size, 1);
});

test('andere Methoden -> 405', async () => {
  const { handler, bucket } = setup();
  await create(handler);
  for (const m of ['POST', 'PATCH', 'HEAD', 'OPTIONS', 'TRACE']) {
    const res = await call(handler, m, `/${NAME}`);
    assert.equal(res.statusCode, 405, m);
  }
  assert.equal(bucket.objects.size, 1);
});

test('Praefix: /ucdb/<name> (Standardpraefix) geht, nacktes /<name> -> 404 ohne Speicherzugriff', async () => {
  const { handler, bucket } = setup();
  await create(handler, 'data', NAME2);
  const ok = await call(handler, 'GET', `/ucdb/${NAME2}`, { raw: true });
  assert.equal(ok.statusCode, 200);
  const calls = bucket.calls;
  for (const method of ['GET', 'PUT', 'DELETE']) {
    const bare = await call(handler, method, `/${NAME2}`, {
      raw: true,
      headers: { 'If-None-Match': '*', 'If-Match': '"1"' },
      body: valid('bare'),
    });
    assert.equal(bare.statusCode, 404, method);
  }
  assert.equal(bucket.calls, calls);
});

function prefixed(prefix, extra = {}) {
  const bucket = new FakeBucket();
  const logs = [];
  const handler = createHandler(bucket, { prefix, log: (...a) => logs.push(a), ...extra });
  return { bucket, handler, logs };
}

test('Praefix: konfigurierter Praefix geht, Standard-, falscher und fehlender Praefix -> 404', async () => {
  const prefix = 'ucdb-Zx9_k3Q';
  const { handler, bucket } = prefixed(prefix);
  const put = await call(handler, 'PUT', `/${prefix}/${NAME}`, {
    raw: true,
    headers: { 'If-None-Match': '*' },
    body: valid('v'),
  });
  assert.equal(put.statusCode, 201);
  assert.equal((await call(handler, 'GET', `/${prefix}/${NAME}`, { raw: true })).statusCode, 200);
  const calls = bucket.calls;
  for (const path of [
    `/ucdb/${NAME}`,
    `/ucdb-Zx9_k3R/${NAME}`,
    `/ucdb-Zx9_k3/${NAME}`,
    `/${prefix}x/${NAME}`,
    `/${prefix}`,
    `/${prefix}/`,
    `/${prefix}/${prefix}/${NAME}`,
    `/${prefix}//${NAME}`,
    `/x/${prefix}/${NAME}`,
    `/${NAME}`,
  ]) {
    for (const method of ['GET', 'PUT', 'DELETE']) {
      const res = await call(handler, method, path, {
        raw: true,
        headers: { 'If-None-Match': '*', 'If-Match': '"1"' },
        body: valid('v'),
      });
      assert.equal(res.statusCode, 404, `${method} ${path}`);
    }
  }
  assert.equal(bucket.calls, calls);
});

test('Praefix: der Speicherpfad bleibt ucdb/<name>, egal welcher Praefix', async () => {
  const { handler, bucket } = prefixed('ucdbSECRET');
  await call(handler, 'PUT', `/ucdbSECRET/${NAME}`, { raw: true, headers: { 'If-None-Match': '*' }, body: valid('v') });
  assert.deepEqual([...bucket.objects.keys()], [`ucdb/${NAME}`]);
});

test('Praefix: ungueltiger konfigurierter Praefix -> alles 500, Log nur "bad-prefix" ohne den Wert', async () => {
  for (const bad of ['', 'ucdb/', 'abc', 'UCDB', 'ucdb.x', 'ucdb ' , 'ucdb' + 'a'.repeat(65), 'ucdb\n', 7, null]) {
    const { handler, bucket, logs } = prefixed(bad);
    for (const path of [`/ucdb/${NAME}`, `/${bad}/${NAME}`, `/${NAME}`]) {
      const res = await call(handler, 'GET', path, { raw: true });
      assert.equal(res.statusCode, 500, `${JSON.stringify(bad)} ${path}`);
    }
    assert.equal(bucket.calls, 0);
    assert.ok(logs.length > 0);
    for (const l of logs) assert.deepEqual(l, ['ucdb', 'bad-prefix']);
  }
});

test('Praefix: Grenzen des Formats (ucdb allein und 64 Zeichen Suffix sind gueltig)', async () => {
  for (const good of ['ucdb', 'ucdb' + 'a'.repeat(64), 'ucdb-_Az09']) {
    const { handler } = prefixed(good);
    const res = await call(handler, 'PUT', `/${good}/${NAME}`, { raw: true, headers: { 'If-None-Match': '*' }, body: valid('v') });
    assert.equal(res.statusCode, 201, good);
  }
});

test('Namen mit - und _ sind gueltig', async () => {
  const { handler } = setup();
  assert.equal((await create(handler, 'x', NAME2)).statusCode, 201);
});

test('zwei Schreiber mit derselben Version: genau einer gewinnt', async () => {
  const { handler, bucket } = setup();
  const created = await create(handler, 'base');
  const etag = created.headers['etag'];

  const [a, b] = await Promise.all([
    call(handler, 'PUT', `/${NAME}`, { headers: { 'If-Match': etag }, body: bytes('from A') }),
    call(handler, 'PUT', `/${NAME}`, { headers: { 'If-Match': etag }, body: bytes('from B') }),
  ]);
  assert.deepEqual([a.statusCode, b.statusCode].sort(), [200, 412]);
  const winner = a.statusCode === 200 ? 'from A' : 'from B';
  assert.deepEqual(bucket.bytesOf(NAME), bytes(winner));
});

test('Konfliktszenario: Verlierer liest neu, mergt und schreibt mit neuer Version', async () => {
  const { handler, bucket } = setup();
  const created = await create(handler, 'base');
  const e1 = created.headers['etag'];

  const a = await call(handler, 'PUT', `/${NAME}`, { headers: { 'If-Match': e1 }, body: bytes('A') });
  assert.equal(a.statusCode, 200);
  const b = await call(handler, 'PUT', `/${NAME}`, { headers: { 'If-Match': e1 }, body: bytes('B') });
  assert.equal(b.statusCode, 412);

  const reread = await call(handler, 'GET', `/${NAME}`);
  assert.deepEqual(reread.body, bytes('A'));
  assert.equal(reread.headers['etag'], a.headers['etag']);
  const retry = await call(handler, 'PUT', `/${NAME}`, {
    headers: { 'If-Match': reread.headers['etag'] },
    body: bytes('A+B'),
  });
  assert.equal(retry.statusCode, 200);
  assert.deepEqual(bucket.bytesOf(NAME), bytes('A+B'));
});

test('zwei gleichzeitige Anlegen: genau eines gewinnt (201/412)', async () => {
  const { handler } = setup();
  const [a, b] = await Promise.all([create(handler, 'A'), create(handler, 'B')]);
  assert.deepEqual([a.statusCode, b.statusCode].sort(), [201, 412]);
});

test('Anlegen nach Loeschen geht wieder, Namen sind voneinander unabhaengig', async () => {
  const { handler } = setup();
  const first = await create(handler, 'one');
  await call(handler, 'DELETE', `/${NAME}`, { headers: { 'If-Match': first.headers['etag'] } });
  assert.equal((await create(handler, 'again')).statusCode, 201);
  assert.equal((await create(handler, 'other', NAME2)).statusCode, 201);
  assert.deepEqual((await call(handler, 'GET', `/${NAME}`)).body, bytes('again'));
  assert.deepEqual((await call(handler, 'GET', `/${NAME2}`)).body, bytes('other'));
});

test('GET-Race: Datei zwischen Metadaten und Download ueberschrieben -> Wiederholung liefert 200', async () => {
  const { handler, bucket } = setup();
  const created = await create(handler, 'old');
  let once = true;
  bucket.afterMetadata = async () => {
    if (!once) return;
    once = false;
    await call(handler, 'PUT', `/${NAME}`, { headers: { 'If-Match': created.headers['etag'] }, body: bytes('new') });
  };
  const res = await call(handler, 'GET', `/${NAME}`);
  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.body, bytes('new'));
  assert.equal(res.headers['etag'], `"${bucket.generationOf(NAME)}"`);
});

test('GET-Race: Datei zwischen Metadaten und Download geloescht -> 404', async () => {
  const { handler, bucket } = setup();
  const created = await create(handler, 'old');
  let once = true;
  bucket.afterMetadata = async () => {
    if (!once) return;
    once = false;
    await call(handler, 'DELETE', `/${NAME}`, { headers: { 'If-Match': created.headers['etag'] } });
  };
  assert.equal((await call(handler, 'GET', `/${NAME}`)).statusCode, 404);
});

test('GET-Race: dauernd ueberschrieben -> nach 3 Versuchen 503, nie ein falsches 404', async () => {
  const { handler, bucket } = setup();
  await create(handler, 'v0');
  let n = 0;
  bucket.afterMetadata = async () => {
    n++;
    await call(handler, 'PUT', `/${NAME}`, {
      headers: { 'If-Match': `"${bucket.generationOf(NAME)}"` },
      body: bytes(`v${n}`),
    });
  };
  const res = await call(handler, 'GET', `/${NAME}`);
  assert.equal(res.statusCode, 503);
  assert.equal(res.headers['retry-after'], '1');
  assert.equal(n, 3);
});

test('Speicherfehler -> 500; das Log enthaelt nur Methode und Code, nie Name oder Inhalt', async () => {
  const secret = 'SECRET-CONTENT';
  for (const method of ['GET', 'PUT', 'DELETE']) {
    const { handler, bucket, logs } = setup();
    await create(handler, secret);
    const etag = `"${bucket.generationOf(NAME)}"`;
    const failure = Object.assign(new Error(`boom ucdb/${NAME} ${secret}`), { code: 503 });
    bucket.failWith = failure;
    const res = await call(handler, method, `/${NAME}`, {
      headers: { 'If-Match': etag },
      body: bytes(secret),
    });
    assert.equal(res.statusCode, 500, method);
    assert.deepEqual(logs, [['ucdb', method, 503]]);
    assert.ok(!JSON.stringify(logs).includes(NAME));
    assert.ok(!JSON.stringify(logs).includes(secret));
  }
});

test('Fehler ohne Code wird als 500 geloggt, ohne die Meldung', async () => {
  const { handler, bucket, logs } = setup();
  bucket.failWith = new Error(`kaputt ${NAME}`);
  const res = await call(handler, 'GET', `/${NAME}`);
  assert.equal(res.statusCode, 500);
  assert.deepEqual(logs, [['ucdb', 'GET', 'error']]);
});

test('jede Antwort traegt Access-Control-Expose-Headers: ETag, no-store und nosniff', async () => {
  const { handler } = setup();
  const responses = [
    await call(handler, 'GET', '/nope'),
    await call(handler, 'POST', `/${NAME}`),
    await call(handler, 'PUT', `/${NAME}`, { body: bytes('x') }),
    await create(handler),
    await call(handler, 'GET', `/${NAME}`),
  ];
  for (const r of responses) {
    assert.equal(r.headers['access-control-expose-headers'], 'ETag');
    assert.equal(r.headers['cache-control'], 'no-store');
    assert.equal(r.headers['x-content-type-options'], 'nosniff');
  }
});

test('PUT: Content-Length ueber dem Limit -> 413, ohne den Body zu lesen', async () => {
  const { handler, bucket } = setup();
  let read = false;
  const req = {
    method: 'PUT',
    path: `/ucdb/${NAME}`,
    headers: { 'if-none-match': '*', 'content-length': String(MAX_BYTES + 1) },
    async *[Symbol.asyncIterator]() {
      read = true;
      yield Buffer.from('x');
    },
  };
  const res = fakeRes();
  await handler(req, res);
  assert.equal(res.statusCode, 413);
  assert.equal(read, false);
  assert.equal(bucket.calls, 0);
});

test('PUT: Datei fehlt im Speicher (404, z. B. Bucket fehlt) -> 500, Code geloggt, kein 412', async () => {
  const { handler, bucket, logs } = setup();
  bucket.failWith = Object.assign(new Error(`no bucket ucdb/${NAME}`), { code: 404 });
  const res = await call(handler, 'PUT', `/${NAME}`, { headers: { 'If-None-Match': '*' }, body: bytes('x') });
  assert.equal(res.statusCode, 500);
  assert.deepEqual(logs, [['ucdb', 'PUT', 404]]);
});

test('save ohne Generation im Ergebnis -> 500, nie eine fremde Generation', async () => {
  const { handler, bucket, logs } = setup();
  const original = bucket.file.bind(bucket);
  bucket.file = (path, opts) => {
    const f = original(path, opts);
    const save = f.save;
    f.save = async (b, o) => {
      await save(b, o);
      f.metadata = undefined;
    };
    return f;
  };
  const res = await create(handler, 'x');
  assert.equal(res.statusCode, 500);
  assert.equal(res.headers['etag'], undefined);
  assert.deepEqual(logs, [['ucdb', 'PUT', 'error']]);
});

// Ohne Content-Type fuellt das Framework rawBody nicht; der Handler liest den Strom.
test('PUT ohne Content-Type (Body nur im Strom) wird gelesen', async () => {
  const { handler, bucket } = setup();
  const whole = valid('ab');
  const req = Object.assign(Readable.from([whole.subarray(0, 100), whole.subarray(100)]), {
    method: 'PUT',
    path: `/ucdb/${NAME}`,
    headers: { 'if-none-match': '*' },
  });
  const res = fakeRes();
  await handler(req, res);
  assert.equal(res.statusCode, 201);
  assert.deepEqual(bucket.bytesOf(NAME), whole);
});

test('PUT ohne Content-Type: leerer Strom -> 400, zu grosser Strom -> 413', async () => {
  const { handler, bucket } = setup();
  const mk = (chunks) =>
    Object.assign(Readable.from(chunks), { method: 'PUT', path: `/ucdb/${NAME}`, headers: { 'if-none-match': '*' } });
  const empty = fakeRes();
  await handler(mk([]), empty);
  assert.equal(empty.statusCode, 400);
  const big = fakeRes();
  await handler(mk([Buffer.alloc(MAX_BYTES, 1), Buffer.from('x')]), big);
  assert.equal(big.statusCode, 413);
  assert.equal(bucket.objects.size, 0);
});

// ---------------------------------------------------------------------------
// Formatpruefung (PUT)

function putCreate(handler, body) {
  return call(handler, 'PUT', `/${NAME}`, { headers: { 'If-None-Match': '*' }, body });
}

// Der Ciphertext aus test/golden_v1_vectors.dart ist echte App-Ausgabe
// (FormatV1.seal). Nur gelesen, dort wird nichts geaendert.
test('Formatpruefung: die echte Golden-Vector-Datei der App wird angenommen', async () => {
  const file = path.join(__dirname, '..', '..', '..', 'ultracipher_flutter', 'test', 'golden_v1_vectors.dart');
  const source = fs.readFileSync(file, 'utf8');
  const m = /const String fileBase64 =([^;]+);/.exec(source);
  assert.ok(m, 'fileBase64 in golden_v1_vectors.dart gefunden');
  const base64 = [...m[1].matchAll(/'([^']*)'/g)].map((x) => x[1]).join('');
  const golden = Buffer.from(base64, 'base64');
  assert.ok(golden.length >= MIN_FILE_LENGTH);
  assert.equal((golden.length - 140) % 16, 0, 'Laengenarithmetik der echten Datei');
  assert.equal(golden.subarray(0, 4).toString('latin1'), 'UCDB');
  assert.ok(looksLikeFormatV1(golden));
  const { handler, bucket } = setup();
  const res = await putCreate(handler, golden);
  assert.equal(res.statusCode, 201);
  assert.deepEqual(bucket.bytesOf(NAME), golden);
});

test('Formatpruefung: kleinste gueltige Datei (156 B) geht, ohne Ciphertext-Block nicht', async () => {
  const { handler, bucket } = setup();
  assert.equal(valid('x', 1).length, 156);
  assert.equal((await putCreate(handler, valid('x', 1))).statusCode, 201);
  const { handler: h2, bucket: b2 } = setup();
  assert.equal((await putCreate(h2, valid('x', 0))).statusCode, 400);
  assert.equal(b2.calls, 0);
  assert.equal(bucket.objects.size, 1);
});

test('Formatpruefung: jede Abweichung -> 400, ohne Speicherzugriff', async () => {
  const mutate = (fn, blocks = 2) => {
    const b = valid('m', blocks);
    fn(b);
    return b;
  };
  const cases = {
    'Magic ucdb': mutate((b) => b.write('ucdb', 0, 'latin1')),
    'Magic UCDC': mutate((b) => (b[3] = 0x43)),
    'Version 0': mutate((b) => b.writeUInt16BE(0, 4)),
    'Version 2': mutate((b) => b.writeUInt16BE(2, 4)),
    'Version hohes Byte': mutate((b) => (b[4] = 1)),
    'Suite 2': mutate((b) => b.writeUInt16BE(2, 6)),
    'Suite 0': mutate((b) => b.writeUInt16BE(0, 6)),
    'Profil 2': mutate((b) => b.writeUInt16BE(2, 8)),
    'Profil hohes Byte': mutate((b) => (b[8] = 1)),
    'Flags 1': mutate((b) => b.writeUInt16BE(1, 10)),
    'Flags 0x0100': mutate((b) => (b[10] = 1)),
    'ein Byte zu lang': Buffer.concat([valid('m', 2), Buffer.alloc(1)]),
    'ein Byte zu kurz': valid('m', 2).subarray(0, valid('m', 2).length - 1),
    '15 Byte mehr': Buffer.concat([valid('m', 2), Buffer.alloc(15)]),
    'nur Header + Tags (kein Block)': valid('m', 0),
    'nur der Header': valid('m', 0).subarray(0, 44),
    'Zufallsbytes': Buffer.from(Array.from({ length: 300 }, (_, i) => (i * 37) % 251)),
    'Text': Buffer.from('hello world'),
    'ein Byte': Buffer.from('U'),
    'Null-Bytes (Laenge passt)': Buffer.alloc(156),
  };
  for (const [name, body] of Object.entries(cases)) {
    for (const headers of [{ 'If-None-Match': '*' }, { 'If-Match': '"1"' }]) {
      const { handler, bucket } = setup();
      const res = await call(handler, 'PUT', `/${NAME}`, { headers, body });
      assert.equal(res.statusCode, 400, name);
      assert.equal(bucket.calls, 0, name);
      assert.equal(bucket.objects.size, 0, name);
    }
  }
  // Gegenprobe: mehrere Bloecke und beliebiger Salt/Rest sind gueltig.
  assert.equal((await putCreate(setup().handler, valid('m', 5))).statusCode, 201);
});

test('Formatpruefung: Fehler zaehlen nicht gegen die Ratenlimits', async () => {
  const bucket = new FakeBucket();
  const handler = createHandler(bucket, { createsPerDay: 1, writesPerHourPerName: 1, log: () => {} });
  for (let i = 0; i < 5; i++) assert.equal((await putCreate(handler, Buffer.from('junk'))).statusCode, 400);
  assert.equal((await putCreate(handler, valid('a'))).statusCode, 201);
});

// ---------------------------------------------------------------------------
// Ratenlimits

function limited(options) {
  const clock = { t: 1_000_000 };
  const bucket = new FakeBucket();
  const logs = [];
  const handler = createHandler(bucket, { now: () => clock.t, log: (...a) => logs.push(a), ...options });
  return { bucket, handler, clock, logs };
}
const nameN = (i) => String(i).padStart(43, 'A');
const createN = (h, i, seed = 'c') =>
  call(h, 'PUT', `/${nameN(i)}`, { headers: { 'If-None-Match': '*' }, body: valid(seed) });
const HOUR = 3600 * 1000;

test('Anlegelimit: ab dem 11. Anlegen am Tag 429 mit Retry-After, kein Speicherzugriff, nach 24 h wieder frei', async () => {
  const { handler, bucket, clock } = limited({});
  for (let i = 0; i < 10; i++) {
    assert.equal((await createN(handler, i)).statusCode, 201, `Anlegen ${i}`);
    clock.t += 1000;
  }
  const callsBefore = bucket.calls;
  const res = await createN(handler, 10);
  assert.equal(res.statusCode, 429);
  // Fenster begann bei t0; seit dem Start sind 10 s vergangen.
  assert.equal(res.headers['retry-after'], String(24 * 3600 - 10));
  assert.equal(bucket.calls, callsBefore);
  assert.equal(bucket.bytesOf(nameN(10)), undefined);
  assert.equal(res.headers['cache-control'], 'no-store');
  clock.t += 24 * HOUR - 10_000 - 1;
  assert.equal((await createN(handler, 10)).statusCode, 429);
  clock.t += 1;
  assert.equal((await createN(handler, 10)).statusCode, 201);
});

test('Anlegelimit: Ersetzen (If-Match) und Lesen sind davon unberuehrt', async () => {
  const { handler, clock } = limited({ createsPerDay: 1 });
  const first = await createN(handler, 0);
  assert.equal((await createN(handler, 1)).statusCode, 429);
  let etag = first.headers['etag'];
  for (let i = 0; i < 5; i++) {
    const r = await call(handler, 'PUT', `/${nameN(0)}`, { headers: { 'If-Match': etag }, body: valid(`r${i}`) });
    assert.equal(r.statusCode, 200);
    etag = r.headers['etag'];
  }
  assert.equal((await call(handler, 'GET', `/${nameN(0)}`)).statusCode, 200);
  clock.t += 1;
});

test('Anlegelimit: Anlegen mit 412 (existiert schon) bleibt gezaehlt', async () => {
  const { handler } = limited({ createsPerDay: 2 });
  assert.equal((await createN(handler, 0)).statusCode, 201);
  assert.equal((await createN(handler, 0)).statusCode, 412);
  assert.equal((await createN(handler, 1)).statusCode, 429);
});

test('Schreiblimit pro Name: PUT und DELETE zusammen, danach 429 mit Retry-After, nach einer Stunde wieder frei', async () => {
  const { handler, bucket, clock } = limited({ writesPerHourPerName: 5, createsPerDay: 1000 });
  const created = await createN(handler, 0); // 1. Schreibzugriff dieses Namens
  let etag = created.headers['etag'];
  for (let i = 0; i < 3; i++) {
    const r = await call(handler, 'PUT', `/${nameN(0)}`, { headers: { 'If-Match': etag }, body: valid(`w${i}`) });
    assert.equal(r.statusCode, 200);
    etag = r.headers['etag'];
  }
  const del = await call(handler, 'DELETE', `/${nameN(0)}`, { headers: { 'If-Match': etag } });
  assert.equal(del.statusCode, 204); // 5. Schreibzugriff
  clock.t += 600_000;
  const callsBefore = bucket.calls;
  const put = await call(handler, 'PUT', `/${nameN(0)}`, { headers: { 'If-Match': etag }, body: valid('z') });
  assert.equal(put.statusCode, 429);
  assert.equal(put.headers['retry-after'], '3000');
  const del2 = await call(handler, 'DELETE', `/${nameN(0)}`, { headers: { 'If-Match': etag } });
  assert.equal(del2.statusCode, 429);
  const again = await createN(handler, 0);
  assert.equal(again.statusCode, 429);
  assert.equal(bucket.calls, callsBefore);
  // Lesen bleibt moeglich, ein anderer Name ist nicht betroffen.
  assert.equal((await call(handler, 'GET', `/${nameN(0)}`)).statusCode, 404);
  assert.equal((await createN(handler, 1)).statusCode, 201);
  clock.t += 3_000_000;
  assert.equal((await createN(handler, 0)).statusCode, 201);
});

test('Schreiblimit pro Name: zwei Namen sind unabhaengig, einer erschoepft, der andere schreibt weiter', async () => {
  const { handler } = limited({ writesPerHourPerName: 3, createsPerDay: 1000 });
  const a = await createN(handler, 0);
  const b = await createN(handler, 1);
  let ea = a.headers['etag'];
  for (let i = 0; i < 2; i++) {
    const r = await call(handler, 'PUT', `/${nameN(0)}`, { headers: { 'If-Match': ea }, body: valid(`a${i}`) });
    assert.equal(r.statusCode, 200);
    ea = r.headers['etag'];
  }
  // Name 0 hat 3 von 3; ein Fremder mit dem Namen kann das Kontingent von Name 1 nicht verbrauchen.
  assert.equal((await call(handler, 'PUT', `/${nameN(0)}`, { headers: { 'If-Match': ea }, body: valid('x') })).statusCode, 429);
  assert.equal((await call(handler, 'DELETE', `/${nameN(0)}`, { headers: { 'If-Match': ea } })).statusCode, 429);
  let eb = b.headers['etag'];
  for (let i = 0; i < 2; i++) {
    const r = await call(handler, 'PUT', `/${nameN(1)}`, { headers: { 'If-Match': eb }, body: valid(`b${i}`) });
    assert.equal(r.statusCode, 200, `Name 1, Schreibzugriff ${i + 2}`);
    eb = r.headers['etag'];
  }
  assert.equal((await call(handler, 'PUT', `/${nameN(1)}`, { headers: { 'If-Match': eb }, body: valid('x') })).statusCode, 429);
});

test('Es gibt keinen globalen Schreibdeckel: viele Namen mit je ihrem Kontingent schreiben alle weiter', async () => {
  const { handler } = limited({ writesPerHourPerName: 2, createsPerDay: 1000, maxFiles: 1000 });
  for (let i = 0; i < 100; i++) {
    assert.equal((await createN(handler, i)).statusCode, 201, `Name ${i}`);
  }
  const first = await call(handler, 'GET', `/${nameN(0)}`);
  assert.equal((await call(handler, 'PUT', `/${nameN(0)}`, { headers: { 'If-Match': first.headers['etag'] }, body: valid('n') })).statusCode, 200);
});

test('Schreiblimit: ein am Anlegelimit abgewiesenes Anlegen verbraucht kein Schreibbudget', async () => {
  const { handler } = limited({ createsPerDay: 1, writesPerHourPerName: 3 });
  const first = await createN(handler, 0);
  for (let i = 1; i < 10; i++) assert.equal((await createN(handler, i)).statusCode, 429);
  const etag = first.headers['etag'];
  assert.equal((await call(handler, 'PUT', `/${nameN(0)}`, { headers: { 'If-Match': etag }, body: valid('a') })).statusCode, 200);
});

test('Limits: Vorpruefungen (413, 400, 404, 412 ohne ETag, 428) zaehlen nicht', async () => {
  const { handler } = limited({ createsPerDay: 1, writesPerHourPerName: 1 });
  for (let i = 0; i < 5; i++) {
    assert.equal((await call(handler, 'PUT', `/${NAME}`, { headers: { 'If-None-Match': '*' }, body: Buffer.alloc(MAX_BYTES + 1) })).statusCode, 413);
    assert.equal((await call(handler, 'PUT', `/${NAME}`, { headers: { 'If-None-Match': '*' }, body: Buffer.from('junk') })).statusCode, 400);
    assert.equal((await call(handler, 'PUT', `/${NAME}`, { body: valid('x') })).statusCode, 428);
    assert.equal((await call(handler, 'PUT', `/${NAME}`, { headers: { 'If-Match': 'abc' }, body: valid('x') })).statusCode, 412);
    assert.equal((await call(handler, 'DELETE', `/${NAME}`, { headers: { 'If-Match': 'abc' } })).statusCode, 412);
    assert.equal((await call(handler, 'DELETE', `/${NAME}`)).statusCode, 428);
    assert.equal((await call(handler, 'PUT', `/x/${NAME}`, { raw: true, headers: { 'If-None-Match': '*' }, body: valid('x') })).statusCode, 404);
  }
  assert.equal((await createN(handler, 0)).statusCode, 201);
});

test('Limits: Pruefen und Reservieren sind synchron, parallele Anfragen ueberschreiten das Limit nicht', async () => {
  const { handler } = limited({ createsPerDay: 3, writesPerHourPerName: 1000 });
  const results = await Promise.all(Array.from({ length: 10 }, (_, i) => createN(handler, i)));
  assert.deepEqual(results.map((r) => r.statusCode).filter((c) => c === 201).length, 3);
  assert.equal(results.filter((r) => r.statusCode === 429).length, 7);
});

// Das Lesebudget pro Name ist mindestens MAX_BYTES; die Egress-Tests nutzen daher
// die groesste gueltige Datei (16 MiB - 4) und Budgets in Vielfachen davon.
const BIGFILE = () => validOfLength(MAX_BYTES - 4);

test('Egress: GET-Budget pro Stunde, vor dem Download geprueft; 429 mit Retry-After; nach einer Stunde frei', async () => {
  const body = BIGFILE();
  const { handler, bucket, clock } = limited({ readBytesPerHourPerName: 2 * MAX_BYTES, createsPerDay: 100 });
  await call(handler, 'PUT', `/${NAME}`, { headers: { 'If-None-Match': '*' }, body });
  for (let i = 0; i < 2; i++) {
    const r = await call(handler, 'GET', `/${NAME}`);
    assert.equal(r.statusCode, 200);
    assert.deepEqual(r.body, body);
    clock.t += 1000;
  }
  const before = bucket.calls;
  const blocked = await call(handler, 'GET', `/${NAME}`);
  assert.equal(blocked.statusCode, 429);
  assert.equal(blocked.headers['retry-after'], String(3600 - 2));
  assert.equal(blocked.body, undefined);
  assert.equal(blocked.headers['etag'], undefined);
  assert.equal(bucket.calls, before + 1, 'nur getMetadata, kein download');
  // Schreiben ist vom Lesebudget unabhaengig.
  const etag = `"${bucket.generationOf(NAME)}"`;
  assert.equal((await call(handler, 'PUT', `/${NAME}`, { headers: { 'If-Match': etag }, body })).statusCode, 200);
  clock.t += HOUR;
  assert.equal((await call(handler, 'GET', `/${NAME}`)).statusCode, 200);
});

test('Egress: nach Groesse laut Metadaten, fehlende Datei (404) verbraucht nichts, parallele GETs ueberschreiten das Budget nicht', async () => {
  const { handler } = limited({ readBytesPerHourPerName: 2 * MAX_BYTES, createsPerDay: 100 });
  for (let i = 0; i < 20; i++) assert.equal((await call(handler, 'GET', `/${nameN(99)}`)).statusCode, 404);
  await call(handler, 'PUT', `/${NAME}`, { headers: { 'If-None-Match': '*' }, body: BIGFILE() });
  const results = await Promise.all(Array.from({ length: 8 }, () => call(handler, 'GET', `/${NAME}`)));
  assert.equal(results.filter((r) => r.statusCode === 200).length, 2);
  assert.equal(results.filter((r) => r.statusCode === 429).length, 6);
});

test('Egress: ein Budget unter 16 MiB wird auf MAX_BYTES angehoben, die groesste Datei bleibt lesbar', async () => {
  const { handler } = limited({ readBytesPerHourPerName: 100, createsPerDay: 100 });
  await call(handler, 'PUT', `/${nameN(0)}`, { headers: { 'If-None-Match': '*' }, body: BIGFILE() });
  assert.equal((await call(handler, 'GET', `/${nameN(0)}`)).statusCode, 200);
  assert.equal((await call(handler, 'GET', `/${nameN(0)}`)).statusCode, 429);
});

test('Egress: fehlt die Groesse in den Metadaten, wird vom Maximum ausgegangen', async () => {
  const { handler, bucket } = limited({ readBytesPerHourPerName: MAX_BYTES * 2 - 1, createsPerDay: 100 });
  await createN(handler, 0);
  const original = bucket.file.bind(bucket);
  bucket.file = (p, o) => {
    const f = original(p, o);
    const getMetadata = f.getMetadata;
    f.getMetadata = async () => {
      const [m] = await getMetadata();
      delete m.size;
      return [m];
    };
    return f;
  };
  assert.equal((await call(handler, 'GET', `/${nameN(0)}`)).statusCode, 200);
  assert.equal((await call(handler, 'GET', `/${nameN(0)}`)).statusCode, 429);
});

test('Limits: ungueltige Optionen fallen auf die Standardwerte zurueck, 0 sperrt', async () => {
  const bad = limited({ createsPerDay: 'x', writesPerHourPerName: NaN, readBytesPerHourPerName: -1 });
  for (let i = 0; i < 10; i++) assert.equal((await createN(bad.handler, i)).statusCode, 201);
  assert.equal((await createN(bad.handler, 10)).statusCode, 429);
  const zero = limited({ createsPerDay: 0 });
  assert.equal((await createN(zero.handler, 0)).statusCode, 429);
});

test('Limits: Standardwerte sind 10 Anlegen pro Tag (global), 60 Schreibzugriffe pro Stunde und Name, 32 MiB Lesen pro Stunde und Name, 20 Dateien', async () => {
  const { handler } = limited({});
  const first = await createN(handler, 0);
  let etag = first.headers['etag'];
  for (let writes = 1; writes < 60; writes++) {
    const r = await call(handler, 'PUT', `/${nameN(0)}`, { headers: { 'If-Match': etag }, body: valid(`s${writes}`) });
    assert.equal(r.statusCode, 200, `Schreibzugriff ${writes + 1}`);
    etag = r.headers['etag'];
  }
  assert.equal((await call(handler, 'PUT', `/${nameN(0)}`, { headers: { 'If-Match': etag }, body: valid('over') })).statusCode, 429);

  const big = limited({});
  await call(big.handler, 'PUT', `/${nameN(0)}`, { headers: { 'If-None-Match': '*' }, body: validOfLength(MAX_BYTES - 4) });
  let ok = 0;
  while (ok < 20 && (await call(big.handler, 'GET', `/${nameN(0)}`)).statusCode === 200) ok++;
  assert.equal(ok, 2, '32 MiB pro Name: 2 Lesezugriffe auf (16 MiB - 4)-Dateien, der dritte passt nicht');

  // 20 Dateien: mit hohem Anlegelimit fuellen, die 21. wird abgewiesen.
  const files = limited({ createsPerDay: 1000 });
  for (let i = 0; i < 20; i++) assert.equal((await createN(files.handler, i)).statusCode, 201);
  assert.equal((await createN(files.handler, 20)).statusCode, 507);
});

// ---------------------------------------------------------------------------
// Egress pro Name und global, Obergrenze der Zaehler

test('Egress pro Name: ein Name erschoepft sein Budget, ein anderer liest weiter; Retry-After bis Fensterende', async () => {
  const body = BIGFILE();
  const { handler, clock } = limited({ readBytesPerHourPerName: 2 * MAX_BYTES, createsPerDay: 100 });
  await call(handler, 'PUT', `/${nameN(0)}`, { headers: { 'If-None-Match': '*' }, body });
  await call(handler, 'PUT', `/${nameN(1)}`, { headers: { 'If-None-Match': '*' }, body });
  assert.equal((await call(handler, 'GET', `/${nameN(0)}`)).statusCode, 200);
  clock.t += 1000;
  assert.equal((await call(handler, 'GET', `/${nameN(0)}`)).statusCode, 200);
  clock.t += 1000;
  const blocked = await call(handler, 'GET', `/${nameN(0)}`);
  assert.equal(blocked.statusCode, 429);
  assert.equal(blocked.headers['retry-after'], String(3600 - 2));
  assert.equal((await call(handler, 'GET', `/${nameN(1)}`)).statusCode, 200);
  assert.equal((await call(handler, 'GET', `/${nameN(1)}`)).statusCode, 200);
  clock.t += HOUR;
  assert.equal((await call(handler, 'GET', `/${nameN(0)}`)).statusCode, 200);
});

test('Egress: kein globaler Deckel, viele Namen lesen alle weiter, jeder bis zu seinem Budget', async () => {
  const body = BIGFILE();
  const { handler } = limited({ readBytesPerHourPerName: MAX_BYTES, createsPerDay: 100, maxFiles: 100 });
  for (let i = 0; i < 6; i++) await call(handler, 'PUT', `/${nameN(i)}`, { headers: { 'If-None-Match': '*' }, body });
  for (let i = 0; i < 6; i++) assert.equal((await call(handler, 'GET', `/${nameN(i)}`)).statusCode, 200, `Name ${i}`);
  assert.equal((await call(handler, 'GET', `/${nameN(0)}`)).statusCode, 429);
});

test('Zaehler-Map: Obergrenze fuer Eintraege, Fantasienamen fuellen den Speicher nicht, aktive Namen bleiben (LRU)', async () => {
  const { NameWindows } = require('./handler');
  const clock = { t: 0 };
  const w = new NameWindows(5, HOUR, () => clock.t, 3);
  for (let i = 0; i < 100; i++) {
    w.take(`n${i}`, 1);
    assert.ok(w.size <= 3);
  }
  assert.equal(w.size, 3);
  assert.equal(w.retryAfter('n0', 1), 0, 'verworfener Name beginnt von vorn');
  // retryAfter legt nie einen Eintrag an.
  for (let i = 0; i < 50; i++) w.retryAfter(`peek${i}`, 1);
  assert.equal(w.size, 3);
  // LRU: n97 wird benutzt und bleibt, n98 faellt zuerst heraus.
  w.take('n97', 1);
  w.take('new', 1);
  assert.equal(w.map.has('n97'), true);
  assert.equal(w.map.has('n98'), false);
  assert.equal(w.map.has('n99'), true);
});

test('Zaehler-Map: abgelaufene Fenster werden weggeraeumt', async () => {
  const { NameWindows } = require('./handler');
  const clock = { t: 0 };
  const w = new NameWindows(5, HOUR, () => clock.t, 1000);
  for (let i = 0; i < 100; i++) w.take(`n${i}`, 1);
  assert.equal(w.size, 100);
  clock.t += HOUR + 61_000;
  w.take('fresh', 1);
  assert.equal(w.size, 1);
});

test('Zaehler-Map im Handler: mit kleiner Obergrenze laufen viele Namen weiter durch', async () => {
  const bucket = new FakeBucket();
  const handler = createHandler(bucket, { maxTrackedNames: 5, createsPerDay: 1000, log: () => {} });
  for (let i = 0; i < 20; i++) assert.equal((await createN(handler, i)).statusCode, 201);
  for (let i = 0; i < 20; i++) assert.equal((await call(handler, 'GET', `/${nameN(i)}`)).statusCode, 200);
});

// ---------------------------------------------------------------------------
// Obergrenze der Dateizahl (UCDB_MAX_FILES)

test('MAX_FILES: bei erreichter Grenze 507 ohne Speichern, Log max-files ohne Namen, kein Budget verbraucht', async () => {
  const { handler, bucket, logs } = limited({ maxFiles: 3, createsPerDay: 4 });
  for (let i = 0; i < 3; i++) assert.equal((await createN(handler, i)).statusCode, 201);
  const res = await createN(handler, 3);
  assert.equal(res.statusCode, 507);
  assert.equal(bucket.bytesOf(nameN(3)), undefined);
  assert.equal(bucket.objects.size, 3);
  assert.deepEqual(logs, [['ucdb', 'max-files']]);
  assert.ok(!JSON.stringify(logs).includes(nameN(3)));
  assert.equal(res.headers['retry-after'], undefined, 'kein 429: Warten hilft nicht');
  assert.equal(res.headers['cache-control'], 'no-store');
  // Das 507 hat weder das Anlegelimit (4) noch ein Namensbudget verbraucht: nach Platz schaffen geht es.
  const del = await call(handler, 'DELETE', `/${nameN(0)}`, { headers: { 'If-Match': `"${bucket.generationOf(nameN(0))}"` } });
  assert.equal(del.statusCode, 204);
  assert.equal((await createN(handler, 3)).statusCode, 201);
});

test('MAX_FILES: Ersetzen, Loeschen und Lesen bestehender Dateien gehen bei voller Grenze weiter', async () => {
  const { handler, bucket } = limited({ maxFiles: 2, createsPerDay: 10 });
  const a = await createN(handler, 0);
  await createN(handler, 1);
  assert.equal((await createN(handler, 2)).statusCode, 507);
  const put = await call(handler, 'PUT', `/${nameN(0)}`, { headers: { 'If-Match': a.headers['etag'] }, body: valid('neu') });
  assert.equal(put.statusCode, 200);
  assert.equal((await call(handler, 'GET', `/${nameN(0)}`)).statusCode, 200);
  // Anlegen auf einen vorhandenen Namen bei voller Grenze: 507 (die Grenze gilt vor dem Speicher).
  assert.equal((await createN(handler, 0)).statusCode, 507);
  assert.equal(bucket.objects.size, 2);
});

test('MAX_FILES: Listenaufruf nur ueber ucdb/, hoechstens maxFiles + 1 Eintraege, keine Seitenwechsel, nur beim Anlegen', async () => {
  const { handler, bucket } = limited({ maxFiles: 5, createsPerDay: 100 });
  const first = await createN(handler, 0);
  assert.equal(bucket.listCalls.length, 1);
  assert.deepEqual(bucket.listCalls[0], { prefix: 'ucdb/', maxResults: 6, autoPaginate: false, fields: 'items(name)' });
  await call(handler, 'PUT', `/${nameN(0)}`, { headers: { 'If-Match': first.headers['etag'] }, body: valid('r') });
  await call(handler, 'GET', `/${nameN(0)}`);
  await call(handler, 'PUT', `/${nameN(0)}`, { headers: { 'If-Match': 'abc' }, body: valid('r') });
  await call(handler, 'PUT', `/${nameN(1)}`, { headers: { 'If-None-Match': '*' }, body: Buffer.from('junk') });
  assert.equal(bucket.listCalls.length, 1, 'nur ein gueltiges Anlegen listet');
  // Fremde Objekte ausserhalb von ucdb/ zaehlen nicht (der Fake filtert wie der Prefix-Parameter).
  bucket.objects.set('other/x', { bytes: valid('o'), generation: '1' });
  assert.equal((await createN(handler, 2)).statusCode, 201);
});

test('MAX_FILES: Listenfehler -> 500 mit Code im Log, es wird nichts angelegt', async () => {
  const { handler, bucket, logs } = limited({});
  bucket.failWith = Object.assign(new Error('boom'), { code: 503 });
  const res = await createN(handler, 0);
  assert.equal(res.statusCode, 500);
  assert.deepEqual(logs, [['ucdb', 'PUT', 503]]);
  assert.equal(bucket.objects.size, 0);
});

test('MAX_FILES: zwei gleichzeitige Anlagen duerfen die Grenze um wenige ueberschreiten (dokumentiert)', async () => {
  const { handler, bucket } = limited({ maxFiles: 1, createsPerDay: 100 });
  const results = await Promise.all([createN(handler, 0), createN(handler, 1), createN(handler, 2)]);
  assert.ok(bucket.objects.size >= 1 && bucket.objects.size <= 3);
  assert.ok(results.some((r) => r.statusCode === 201));
  assert.equal((await createN(handler, 3)).statusCode, 507);
});

test('MAX_FILES: 0 sperrt das Anlegen, ungueltiger Wert faellt auf 20 zurueck', async () => {
  const zero = limited({ maxFiles: 0 });
  assert.equal((await createN(zero.handler, 0)).statusCode, 507);
  const bad = limited({ maxFiles: 'x', createsPerDay: 1000 });
  for (let i = 0; i < 20; i++) assert.equal((await createN(bad.handler, i)).statusCode, 201);
  assert.equal((await createN(bad.handler, 20)).statusCode, 507);
});

// ---------------------------------------------------------------------------
// optionsFromEnv (die Verdrahtung in index.js)

test('optionsFromEnv: ohne Werte keine Optionen (Standards des Handlers gelten)', () => {
  assert.deepEqual(optionsFromEnv({}), {});
  assert.deepEqual(optionsFromEnv(undefined), {});
  assert.deepEqual(optionsFromEnv({ PATH: '/bin', UCDB_OTHER: '5' }), {});
});

test('optionsFromEnv: Werte werden uebernommen, MiB in Bytes', () => {
  assert.deepEqual(
    optionsFromEnv({
      UCDB_PREFIX: 'ucdb-abc_123',
      UCDB_CREATES_PER_DAY: '3',
      UCDB_WRITES_PER_HOUR_PER_NAME: ' 7 ',
      UCDB_READ_MIB_PER_HOUR_PER_NAME: '16',
      UCDB_MAX_FILES: '50',
    }),
    {
      prefix: 'ucdb-abc_123',
      createsPerDay: 3,
      writesPerHourPerName: 7,
      readBytesPerHourPerName: 16 * 1024 * 1024,
      maxFiles: 50,
    },
  );
  assert.deepEqual(optionsFromEnv({ UCDB_MAX_FILES: '0' }), { maxFiles: 0 });
});

test('optionsFromEnv: leere oder ungueltige Zahlen fehlen (Standard), leerer Praefix = Standardpraefix, ungueltiger Praefix wird durchgereicht', () => {
  assert.deepEqual(
    optionsFromEnv({
      UCDB_PREFIX: '  ',
      UCDB_CREATES_PER_DAY: '',
      UCDB_WRITES_PER_HOUR_PER_NAME: 'abc',
      UCDB_READ_MIB_PER_HOUR_PER_NAME: '-5',
      UCDB_MAX_FILES: '1.5',
    }),
    {},
  );
  assert.deepEqual(optionsFromEnv({ UCDB_PREFIX: 'nope' }), { prefix: 'nope' });
});

test('optionsFromEnv: Ende zu Ende mit dem Handler (Praefix, Limits, MAX_FILES kommen an)', async () => {
  const options = optionsFromEnv({
    UCDB_PREFIX: 'ucdb-geheim',
    UCDB_CREATES_PER_DAY: '2',
    UCDB_MAX_FILES: '5',
  });
  const bucket = new FakeBucket();
  const handler = createHandler(bucket, { ...options, log: () => {} });
  const put = (i, prefix) =>
    call(handler, 'PUT', `/${prefix}/${nameN(i)}`, { raw: true, headers: { 'If-None-Match': '*' }, body: valid('v') });
  assert.equal((await put(0, 'ucdb')).statusCode, 404);
  assert.equal((await put(0, 'ucdb-geheim')).statusCode, 201);
  assert.equal((await put(1, 'ucdb-geheim')).statusCode, 201);
  assert.equal((await put(2, 'ucdb-geheim')).statusCode, 429);
  const small = createHandler(new FakeBucket(), { ...optionsFromEnv({ UCDB_MAX_FILES: '1' }), log: () => {} });
  assert.equal((await createN(small, 0)).statusCode, 201);
  assert.equal((await createN(small, 1)).statusCode, 507);
});

// ---------------------------------------------------------------------------
// Review-Befunde

// B1: If-Match mit Generation 0 ist bei Cloud Storage "darf nicht existieren"
// (ifGenerationMatch = 0) und darf kein Anlegen am Anlegelimit und an der
// Dateigrenze vorbei ermoeglichen.
test('If-Match mit Generation 0 (auch "00", W/"0", 0, 20 Ziffern) -> 412, legt nichts an, umgeht weder Anlegelimit noch MAX_FILES', async () => {
  const values = ['"0"', '"00"', 'W/"0"', '0', '00', ' 0 ', '"000000000000000000"', '"12345678901234567890"', '"1000000000000000000000"', '"01"', '"-1"'];
  for (const v of values) {
    const { handler, bucket } = limited({ createsPerDay: 0, maxFiles: 0 });
    const put = await call(handler, 'PUT', `/${NAME}`, { headers: { 'If-Match': v }, body: valid('x') });
    assert.equal(put.statusCode, 412, `PUT If-Match ${JSON.stringify(v)}`);
    assert.equal(bucket.objects.size, 0, `PUT If-Match ${JSON.stringify(v)} legt nichts an`);
    assert.equal(bucket.calls, 0);
    const del = await call(handler, 'DELETE', `/${NAME}`, { headers: { 'If-Match': v } });
    assert.equal(del.statusCode, 412, `DELETE If-Match ${JSON.stringify(v)}`);
    assert.equal(bucket.calls, 0);
  }
});

test('parseEtag: nur Generationen 1..19 Ziffern ohne fuehrende Null', () => {
  assert.equal(parseEtag('"1"'), '1');
  assert.equal(parseEtag('W/"1700000000000000"'), '1700000000000000');
  assert.equal(parseEtag('9999999999999999999'), '9999999999999999999'); // 19 Ziffern
  for (const v of ['0', '"0"', '00', '"01"', '12345678901234567890', '', 'abc', '*', undefined]) {
    assert.equal(parseEtag(v), null, JSON.stringify(v));
  }
});

// S1: Schreibzaehler beliebiger Namen duerfen nicht per Verdraengung durch
// Anfragen mit erfundenen Namen zurueckgesetzt werden.
test('Schreibzaehler: If-Match-Anfragen mit erfundenen Namen (412/404) verdraengen keinen Zaehler und hinterlassen keinen Eintrag', async () => {
  const { handler, bucket } = limited({ writesPerHourPerName: 2, maxTrackedNames: 3, createsPerDay: 100 });
  const mine = await createN(handler, 0); // Schreibzugriff 1
  const r = await call(handler, 'PUT', `/${nameN(0)}`, { headers: { 'If-Match': mine.headers['etag'] }, body: valid('b') });
  assert.equal(r.statusCode, 200); // Schreibzugriff 2: Namenslimit erschoepft
  const etag = r.headers['etag'];
  assert.equal((await call(handler, 'PUT', `/${nameN(0)}`, { headers: { 'If-Match': etag }, body: valid('c') })).statusCode, 429);
  // Die Map (Obergrenze 3) ist mit echten Namen voll; der eigene ist der aelteste.
  const b = await createN(handler, 1);
  assert.equal(b.statusCode, 201);
  assert.equal((await createN(handler, 2)).statusCode, 201);
  for (let i = 50; i < 60; i++) {
    const put = await call(handler, 'PUT', `/${nameN(i)}`, { headers: { 'If-Match': '"1700000000000001"' }, body: valid('f') });
    assert.equal(put.statusCode, 412, `erfundener Name ${i} (PUT)`);
    const del = await call(handler, 'DELETE', `/${nameN(i)}`, { headers: { 'If-Match': '"1700000000000001"' } });
    assert.equal(del.statusCode, 412, `erfundener Name ${i} (DELETE)`);
  }
  assert.equal(bucket.objects.size, 3);
  // Ein erfolgreicher Zugriff auf einen echten Namen kuerzt die Map (commit).
  assert.equal((await call(handler, 'PUT', `/${nameN(1)}`, { headers: { 'If-Match': b.headers['etag'] }, body: valid('b2') })).statusCode, 200);
  assert.equal((await call(handler, 'PUT', `/${nameN(0)}`, { headers: { 'If-Match': etag }, body: valid('c') })).statusCode, 429);
  assert.equal((await call(handler, 'DELETE', `/${nameN(0)}`, { headers: { 'If-Match': etag } })).statusCode, 429);
});

test('Schreibzaehler: ein 412 auf dem echten Namen (veralteter ETag) wird erstattet, 500 auch', async () => {
  const { handler, bucket } = limited({ writesPerHourPerName: 2, createsPerDay: 100 });
  const mine = await createN(handler, 0); // 1
  for (let i = 0; i < 5; i++) {
    const stale = await call(handler, 'PUT', `/${nameN(0)}`, { headers: { 'If-Match': '"1700000000000001"' }, body: valid('s') });
    assert.equal(stale.statusCode, 412);
  }
  bucket.failWith = Object.assign(new Error('x'), { code: 503 });
  assert.equal((await call(handler, 'PUT', `/${nameN(0)}`, { headers: { 'If-Match': mine.headers['etag'] }, body: valid('e') })).statusCode, 500);
  assert.equal((await call(handler, 'PUT', `/${nameN(0)}`, { headers: { 'If-Match': mine.headers['etag'] }, body: valid('ok') })).statusCode, 200); // 2
  assert.equal((await call(handler, 'PUT', `/${nameN(0)}`, { headers: { 'If-Match': '"1700000000000001"' }, body: valid('x') })).statusCode, 429); // 2 von 2 erfolgreich: erschoepft
});

test('NameWindows: take mit deferTrim verdraengt erst nach commit, release entfernt den von dieser Anfrage angelegten Eintrag', () => {
  const clock = { t: 0 };
  const w = new NameWindows(5, HOUR, () => clock.t, 2);
  w.take('a', 1);
  w.take('b', 1);
  const t = w.take('fantasy', 1, true);
  assert.equal(w.size, 3, 'ohne Verdraengung');
  assert.equal(w.map.has('a'), true);
  w.release(t);
  assert.equal(w.size, 2);
  assert.equal(w.map.has('a'), true, 'a blieb erhalten');
  // Erstattung auf einem bestehenden Eintrag
  const t2 = w.take('a', 1, true);
  assert.equal(w.map.get('a').used, 2);
  w.release(t2);
  assert.equal(w.map.get('a').used, 1);
  // commit kuerzt
  w.take('c', 1, true);
  w.commit();
  assert.equal(w.size, 2);
  // Ticket eines abgelaufenen Fensters wirkt nicht auf ein neues
  const t3 = w.take('d', 1, true);
  clock.t += HOUR + 1;
  w.take('d', 3, true);
  w.release(t3);
  assert.equal(w.map.get('d').used, 3);
});

// S2 (M9): Ersetzen verbraucht das Anlegebudget nicht.
test('Anlegebudget: Ersetzen verbraucht es nicht (createsPerDay 2: A anlegen, A mehrfach ersetzen, B anlegen -> 201)', async () => {
  const { handler } = limited({ createsPerDay: 2, writesPerHourPerName: 100 });
  const a = await createN(handler, 0);
  let etag = a.headers['etag'];
  for (let i = 0; i < 6; i++) {
    const r = await call(handler, 'PUT', `/${nameN(0)}`, { headers: { 'If-Match': etag }, body: valid(`r${i}`) });
    assert.equal(r.statusCode, 200);
    etag = r.headers['etag'];
  }
  assert.equal((await createN(handler, 1)).statusCode, 201);
  assert.equal((await createN(handler, 2)).statusCode, 429);
});

// S2 (M5): Retry-After wird aufgerundet.
test('Retry-After wird aufgerundet (500 ms nach Fensterstart: 3600 s bzw. 86400 s)', async () => {
  const w = limited({ writesPerHourPerName: 1, createsPerDay: 1 });
  const first = await createN(w.handler, 0);
  w.clock.t += 500;
  const put = await call(w.handler, 'PUT', `/${nameN(0)}`, { headers: { 'If-Match': first.headers['etag'] }, body: valid('n') });
  assert.equal(put.statusCode, 429);
  assert.equal(put.headers['retry-after'], '3600');
  const again = await createN(w.handler, 1);
  assert.equal(again.statusCode, 429);
  assert.equal(again.headers['retry-after'], '86400');
  w.clock.t += 3_599_999 - 500 + 0; // 1 ms vor Fensterende: mindestens 1 s
  const last = await call(w.handler, 'PUT', `/${nameN(0)}`, { headers: { 'If-Match': first.headers['etag'] }, body: valid('n') });
  assert.equal(last.headers['retry-after'], '1');
});

// K1: abgelehnte Anlagen loesen keinen Listenaufruf aus.
test('Anlegen: am Anlegelimit oder Namenslimit abgelehnte Anlagen rufen die Liste nicht auf', async () => {
  const { handler, bucket } = limited({ createsPerDay: 1 });
  await createN(handler, 0);
  assert.equal(bucket.listCalls.length, 1);
  for (let i = 1; i < 5; i++) assert.equal((await createN(handler, i)).statusCode, 429);
  assert.equal(bucket.listCalls.length, 1);
  const w = limited({ writesPerHourPerName: 1, createsPerDay: 100 });
  const first = await createN(w.handler, 0);
  assert.equal(first.statusCode, 201);
  assert.equal(w.bucket.listCalls.length, 1);
  assert.equal((await createN(w.handler, 0)).statusCode, 429);
  assert.equal(w.bucket.listCalls.length, 1);
});

// K2: eine Listenseite hat hoechstens 1000 Eintraege.
test('MAX_FILES wird auf 999 geklemmt (maxResults hoechstens 1000)', async () => {
  const { handler, bucket } = limited({ maxFiles: 100000, createsPerDay: 100 });
  await createN(handler, 0);
  assert.equal(bucket.listCalls[0].maxResults, 1000);
  const small = limited({ maxFiles: 999, createsPerDay: 100 });
  await createN(small.handler, 0);
  assert.equal(small.bucket.listCalls[0].maxResults, 1000);
});
