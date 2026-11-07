'use strict';

// Tests fuer handler.js mit einem Fake-Bucket (nur node:test, keine Firebase-
// Pakete). Der Fake bildet die Teile von Cloud Storage nach, auf die sich der
// Handler stuetzt: Generationen, ifGenerationMatch (0 = darf nicht existieren)
// und Fehler mit `err.code` 404/412 wie in @google-cloud/storage.

const test = require('node:test');
const assert = require('node:assert/strict');
const { Readable } = require('node:stream');
const { createHandler, MAX_BYTES } = require('./handler');

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
        const meta = { generation: o.generation };
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

  _maybeFail() {
    if (this.failWith) {
      const e = this.failWith;
      this.failWith = null;
      throw e;
    }
  }

  _checkPrecondition(path, opts) {
    const o = this.objects.get(path);
    const want = String(opts.ifGenerationMatch);
    if (want === '0' ? o !== undefined : !o || o.generation !== want) throw apiError(412);
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

async function call(handler, method, path, { headers = {}, body } = {}) {
  const lower = {};
  for (const [k, v] of Object.entries(headers)) lower[k.toLowerCase()] = v;
  const req = { method, path, headers: lower, rawBody: body };
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

const bytes = (s) => Buffer.from(s);
const create = (h, data = 'one', name = NAME) =>
  call(h, 'PUT', `/${name}`, { headers: { 'If-None-Match': '*' }, body: bytes(data) });

test('GET: fehlende Datei -> 404', async () => {
  const { handler } = setup();
  const res = await call(handler, 'GET', `/${NAME}`);
  assert.equal(res.statusCode, 404);
  assert.equal(res.headers['access-control-expose-headers'], 'ETag');
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

test('PUT: genau 16 MiB geht, darueber -> 413', async () => {
  const { handler, bucket } = setup();
  const ok = await call(handler, 'PUT', `/${NAME}`, {
    headers: { 'If-None-Match': '*' },
    body: Buffer.alloc(MAX_BYTES, 1),
  });
  assert.equal(ok.statusCode, 201);
  const big = await call(handler, 'PUT', `/${NAME2}`, {
    headers: { 'If-None-Match': '*' },
    body: Buffer.alloc(MAX_BYTES + 1, 1),
  });
  assert.equal(big.statusCode, 413);
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

test('Pfadvarianten: /<name> und /ucdb/<name> sind dieselbe Datei', async () => {
  const { handler } = setup();
  await create(handler, 'data', NAME2);
  const direct = await call(handler, 'GET', `/${NAME2}`);
  const rewritten = await call(handler, 'GET', `/ucdb/${NAME2}`);
  assert.equal(direct.statusCode, 200);
  assert.equal(rewritten.statusCode, 200);
  assert.deepEqual(rewritten.body, direct.body);
  assert.equal(rewritten.headers['etag'], direct.headers['etag']);
  // Anlegen ueber den Rewrite-Pfad, lesen direkt.
  const made = await call(handler, 'PUT', `/ucdb/${NAME}`, { headers: { 'If-None-Match': '*' }, body: bytes('v') });
  assert.equal(made.statusCode, 201);
  assert.deepEqual((await call(handler, 'GET', `/${NAME}`)).body, bytes('v'));
});

test('ungueltige Pfade und Namen -> 404 ohne Zugriff auf den Speicher', async () => {
  const { handler, bucket } = setup();
  const paths = [
    '/',
    '',
    '/ucdb',
    '/ucdb/',
    `/${NAME}/`,
    `/ucdb/${NAME}/`,
    `/ucdb/ucdb/${NAME}`,
    `/x/${NAME}`,
    `/a/b/${NAME}`,
    `//${NAME}`,
    `/ucdb//${NAME}`,
    `/${'A'.repeat(42)}`,
    `/${'A'.repeat(44)}`,
    `/${'A'.repeat(42)}=`,
    `/${'A'.repeat(42)}+`,
    `/${'A'.repeat(42)}.`,
    `/${'A'.repeat(42)}%2F`,
    `/..%2F${'A'.repeat(40)}`,
    `/${'ä'.repeat(43)}`,
    '/ucdb/..',
  ];
  for (const method of ['GET', 'PUT', 'DELETE']) {
    for (const path of paths) {
      const res = await call(handler, method, path, {
        headers: { 'If-None-Match': '*', 'If-Match': '"1"' },
        body: bytes('x'),
      });
      assert.equal(res.statusCode, 404, `${method} ${JSON.stringify(path)}`);
    }
  }
  assert.equal(bucket.calls, 0);
  const undefinedPath = fakeRes();
  await handler({ method: 'GET', headers: {} }, undefinedPath);
  assert.equal(undefinedPath.statusCode, 404);
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
    path: `/${NAME}`,
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
  const req = Object.assign(Readable.from([bytes('ab'), bytes('cd')]), {
    method: 'PUT',
    path: `/${NAME}`,
    headers: { 'if-none-match': '*' },
  });
  const res = fakeRes();
  await handler(req, res);
  assert.equal(res.statusCode, 201);
  assert.deepEqual(bucket.bytesOf(NAME), bytes('abcd'));
});

test('PUT ohne Content-Type: leerer Strom -> 400, zu grosser Strom -> 413', async () => {
  const { handler, bucket } = setup();
  const mk = (chunks) =>
    Object.assign(Readable.from(chunks), { method: 'PUT', path: `/${NAME}`, headers: { 'if-none-match': '*' } });
  const empty = fakeRes();
  await handler(mk([]), empty);
  assert.equal(empty.statusCode, 400);
  const big = fakeRes();
  await handler(mk([Buffer.alloc(MAX_BYTES, 1), bytes('x')]), big);
  assert.equal(big.statusCode, 413);
  assert.equal(bucket.objects.size, 0);
});
