'use strict';

// Sync-Server (REST) fuer Ultracipher: reine Protokoll-Logik ohne Firebase-
// Imports. `bucket` ist ein Cloud-Storage-Bucket (@google-cloud/storage) oder
// ein Fake mit denselben Methoden (siehe handler.test.js). Das Protokoll steht
// in docs/self-hosting.md.
//
// Die Objekt-`generation` von Cloud Storage ist die Version (ETag). Die
// Bedingungen (`ifGenerationMatch`, 0 = darf nicht existieren) wertet Cloud
// Storage atomar aus.
//
// Missbrauchsschutz (kein Login, die Funktion bleibt oeffentlich): geheimer
// Pfadpraefix, Formatpruefung beim PUT und Ratenlimits pro Instanz im Speicher
// (je Datenbankname; Anlegen global; Obergrenze der Dateizahl)
// (siehe docs/self-hosting.md, "Abuse limits and a secret path").

const NAME = /^[A-Za-z0-9_-]{43}$/;
const MAX_BYTES = 16 * 1024 * 1024;
const GET_ATTEMPTS = 3;
const GENERATION = /^[0-9]{1,20}$/;
const ETAG_GENERATION = /^[1-9][0-9]{0,18}$/;
const OCTET_STREAM = 'application/octet-stream';

const DEFAULT_PREFIX = 'ucdb';
// Muss mit `ucdb` beginnen (der Hosting-Rewrite in firebase.json ist `/ucdb*/**`).
const PREFIX = /^ucdb[A-Za-z0-9_-]{0,64}$/;

const DEFAULT_CREATES_PER_DAY = 10;
const DEFAULT_WRITES_PER_HOUR_PER_NAME = 60;
const DEFAULT_READ_BYTES_PER_HOUR_PER_NAME = 32 * 1024 * 1024;
const DEFAULT_MAX_FILES = 20;
const STORAGE_PREFIX = 'ucdb/';
const DEFAULT_MAX_TRACKED_NAMES = 10000;
const SWEEP_MS = 60 * 1000;
const MAX_FILES_LIMIT = 999;
const HOUR_MS = 60 * 60 * 1000;
const DAY_MS = 24 * HOUR_MS;

// Format v1 (ultracipher_flutter/lib/src/crypto/format_v1.dart), Ganzzahlen
// Big-Endian: 0 "UCDB", 4 version=1, 6 suite=1, 8 kdf_profile=1, 10 flags=0,
// 12 file_salt (32 B), 44 Ciphertext (n >= 16, n % 16 == 0), dann HMAC-SHA-512
// (64 B) und HMAC-SHA3-256 (32 B).
const HEADER_LENGTH = 44;
const TAGS_LENGTH = 64 + 32;
const MIN_FILE_LENGTH = HEADER_LENGTH + 16 + TAGS_LENGTH;
const MAGIC = Buffer.from('UCDB', 'latin1');

// Sieht `body` wie eine Datei des Formats v1 aus? Nur Kopf und Laengen-
// arithmetik; ohne Schluessel prueft niemand die MACs. Das haelt Fremdprogramme
// ab, die nur Bytes ablegen wollen, ist aber faelschbar (jeder kann einen
// passenden Kopf mit Zufallsbytes davor setzen).
function looksLikeFormatV1(body) {
  if (!Buffer.isBuffer(body) || body.length < MIN_FILE_LENGTH) return false;
  if ((body.length - HEADER_LENGTH - TAGS_LENGTH) % 16 !== 0) return false;
  if (!body.subarray(0, 4).equals(MAGIC)) return false;
  return (
    body.readUInt16BE(4) === 1 &&
    body.readUInt16BE(6) === 1 &&
    body.readUInt16BE(8) === 1 &&
    body.readUInt16BE(10) === 0
  );
}

// `/<prefix>/<name>`; alles andere (auch ein nacktes `/<name>`, ein
// abschliessender `/` oder ein falscher Praefix) ist kein gueltiger Pfad.
function nameFromPath(path, prefix = DEFAULT_PREFIX) {
  if (typeof path !== 'string' || typeof prefix !== 'string') return null;
  const lead = `/${prefix}/`;
  if (!path.startsWith(lead)) return null;
  const name = path.slice(lead.length);
  return NAME.test(name) ? name : null;
}

// Festes Zeitfenster, nur im Speicher der Instanz. Pruefen und Reservieren sind
// synchron (kein await dazwischen): bei `concurrency` > 1 laufen mehrere
// Anfragen in derselben Instanz, die sonst gemeinsam durch die Pruefung kaemen.
class Window {
  constructor(limit, windowMs, now) {
    this.limit = limit;
    this.windowMs = windowMs;
    this.now = now;
    this.start = undefined;
    this.used = 0;
  }

  _roll() {
    const t = this.now();
    if (this.start === undefined || t - this.start >= this.windowMs) {
      this.start = t;
      this.used = 0;
    }
    return t;
  }

  // Sekunden bis zum Fensterende (mindestens 1), wenn `amount` nicht mehr passt,
  // sonst 0. Reserviert nichts.
  retryAfter(amount) {
    const t = this._roll();
    if (this.used + amount <= this.limit) return 0;
    return Math.max(1, Math.ceil((this.start + this.windowMs - t) / 1000));
  }

  take(amount) {
    this._roll();
    this.used += amount;
  }
}

// Wie Window, aber ein Fenster pro Datenbankname (Map name -> Fenster, im
// Speicher). Die Map ist begrenzt, damit Anfragen mit vielen Fantasienamen den
// Speicher nicht fuellen: abgelaufene Fenster werden hoechstens einmal pro
// Minute weggeraeumt, und ueber `maxNames` hinaus faellt der am laengsten nicht
// benutzte Name heraus. Ein Eintrag entsteht erst in take(), also erst nach
// bestandenen Vorpruefungen; retryAfter() legt nie etwas an.
//
// Schreibzugriffe reservieren mit take(name, n, true): der Eintrag entsteht
// ohne Verdraengung, und erst commit() (Speicher hat zugestimmt) kuerzt die Map.
// Weist der Speicher ab (412/404), gibt release() die Reservierung zurueck und
// entfernt den Eintrag, den diese Anfrage angelegt hat. So hinterlassen
// Anfragen mit erfundenen Namen keine Eintraege und koennen den Zaehler eines
// echten Namens nicht per Verdraengung zuruecksetzen: Eintraege entstehen
// bleibend nur durch erfolgreiche Zugriffe auf echte Dateien.
class NameWindows {
  constructor(limit, windowMs, now, maxNames) {
    this.limit = limit;
    this.windowMs = windowMs;
    this.now = now;
    this.maxNames = Math.max(1, maxNames);
    this.map = new Map(); // name -> { start, used }; Reihenfolge = letzte Benutzung
    this.lastSweep = undefined;
  }

  get size() {
    return this.map.size;
  }

  _live(name, t) {
    const e = this.map.get(name);
    if (e !== undefined && t - e.start >= this.windowMs) {
      this.map.delete(name);
      return undefined;
    }
    return e;
  }

  retryAfter(name, amount) {
    const t = this.now();
    const e = this._live(name, t);
    const used = e === undefined ? 0 : e.used;
    if (used + amount <= this.limit) return 0;
    // Ohne Eintrag passt `amount` allein nicht ins Limit: erst das naechste
    // Fenster hilft auch nicht, Wartezeit = ein volles Fenster.
    const end = e === undefined ? t + this.windowMs : e.start + this.windowMs;
    return Math.max(1, Math.ceil((end - t) / 1000));
  }

  _trim() {
    while (this.map.size > this.maxNames) this.map.delete(this.map.keys().next().value);
  }

  // Reserviert `amount`. Mit `deferTrim` (Schreibzugriffe) erst nach commit()
  // verdraengen. Liefert das Ticket fuer commit()/release().
  take(name, amount, deferTrim = false) {
    const t = this.now();
    if (this.lastSweep === undefined || t - this.lastSweep >= SWEEP_MS) {
      this.lastSweep = t;
      for (const [k, v] of this.map) if (t - v.start >= this.windowMs) this.map.delete(k);
    }
    let e = this._live(name, t);
    const created = e === undefined;
    if (created) {
      e = { start: t, used: 0 };
    } else {
      this.map.delete(name); // ans Ende (zuletzt benutzt)
    }
    e.used += amount;
    this.map.set(name, e);
    if (!deferTrim) this._trim();
    return { name, amount, created, start: e.start };
  }

  commit() {
    this._trim();
  }

  release(ticket) {
    const e = this.map.get(ticket.name);
    if (e === undefined || e.start !== ticket.start) return; // Fenster ist schon weg
    e.used -= ticket.amount;
    if (ticket.created && e.used <= 0) this.map.delete(ticket.name);
  }
}

function limitOption(value, fallback) {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0 ? value : fallback;
}

// ETag-Wert ("123", W/"123" oder 123) -> Generation als Ziffernfolge, sonst null.
function parseEtag(value) {
  if (typeof value !== 'string') return null;
  const m = /^\s*(?:W\/)?"?([0-9]+)"?\s*$/.exec(value);
  // Ohne fuehrende Nullen, nie 0, hoechstens 19 Ziffern: `0` waere bei Cloud
  // Storage "darf nicht existieren" (ifGenerationMatch = 0) und wuerde ein
  // Anlegen am Anlegelimit und an der Dateigrenze vorbei erlauben.
  return m && ETAG_GENERATION.test(m[1]) ? m[1] : null;
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

// Optionen (alle optional): `prefix` (Pfadpraefix, Standard `ucdb`),
// Ratenlimits pro Instanz: `createsPerDay` (Anlegen, global),
// `writesPerHourPerName` (Ersetzen/Loeschen/Anlegen je Datenbankname),
// `readBytesPerHourPerName` (GET-Bytes je Name), `maxFiles` (Obergrenze der
// Dateien unter `ucdb/`; beim Anlegen darueber 507), `maxTrackedNames`
// (Obergrenze der Zaehler-Eintraege je Map). Bewusst keine globalen Lese- und
// Schreibdeckel (ein Angreifer koennte sie fuer den Nutzer ausschoepfen),
// ausserdem `now` (Uhr in Millisekunden, fuer Tests), `log`.
function createHandler(bucket, options = {}) {
  const log = options.log || ((...args) => console.error(...args));
  const now = options.now || Date.now;
  const prefix = options.prefix === undefined ? DEFAULT_PREFIX : options.prefix;
  const prefixValid = typeof prefix === 'string' && PREFIX.test(prefix);
  const creates = new Window(limitOption(options.createsPerDay, DEFAULT_CREATES_PER_DAY), DAY_MS, now);
  const maxNames = limitOption(options.maxTrackedNames, DEFAULT_MAX_TRACKED_NAMES);
  // Bewusst kein globaler Schreibdeckel: ein Angreifer sammelt ueber Tage
  // beliebig viele eigene Namen und koennte ihn fuer den Nutzer ausschoepfen;
  // Schreibzugriffe kosten fast nichts und Ersetzen vergroessert den Speicher
  // nicht.
  const writesPerName = new NameWindows(
    limitOption(options.writesPerHourPerName, DEFAULT_WRITES_PER_HOUR_PER_NAME), HOUR_MS, now, maxNames);
  // Mindestens MAX_BYTES: ein kleineres Budget lieferte fuer grosse Dateien fuer
  // immer 429.
  const readsPerName = new NameWindows(
    Math.max(limitOption(options.readBytesPerHourPerName, DEFAULT_READ_BYTES_PER_HOUR_PER_NAME), MAX_BYTES),
    HOUR_MS, now, maxNames);
  // Hoechstens 999: eine Listenseite von Cloud Storage hat hoechstens 1000
  // Eintraege, gezaehlt werden maxFiles + 1.
  const maxFiles = Math.min(limitOption(options.maxFiles, DEFAULT_MAX_FILES), MAX_FILES_LIMIT);

  function tooMany(res, seconds) {
    res.set('Retry-After', String(seconds));
    return send(res, 429);
  }

  // Die Speicher-Bibliothek meldet fuer ein fehlendes Objekt und fuer einen
  // fehlenden Bucket beide 404. Nur im 404-Fall gefragt (einmal, kein Mehr-
  // aufwand im Normalfall): fehlt der Bucket, ist das ein Serverfehler (500,
  // Log ohne Namen), kein "Datei fehlt". Wirft exists() selbst, wird daraus
  // der uebliche 500 des Handlers.
  async function bucketMissing(res, method) {
    const [exists] = await bucket.exists();
    if (exists) return false;
    log('ucdb', method, 'bucket-missing');
    send(res, 500);
    return true;
  }

  // Anzahl der Dateien unter `ucdb/`, hoechstens maxFiles + 1 gezaehlt.
  async function countFiles() {
    const [files] = await bucket.getFiles({
      prefix: STORAGE_PREFIX,
      maxResults: maxFiles + 1,
      autoPaginate: false,
      fields: 'items(name)',
    });
    return Array.isArray(files) ? files.length : 0;
  }

  async function get(res, path, name) {
    for (let attempt = 0; attempt < GET_ATTEMPTS; attempt++) {
      let generation;
      let size;
      try {
        const [meta] = await bucket.file(path).getMetadata();
        generation = String(meta.generation);
        size = Number(meta.size);
        // Ohne brauchbare Groesse vom Maximum ausgehen (nie unterschaetzen).
        if (!Number.isFinite(size) || size < 0) size = MAX_BYTES;
      } catch (e) {
        if (Number(e && e.code) !== 404) throw e;
        if (await bucketMissing(res, 'GET')) return;
        return send(res, 404);
      }
      // Egress-Budget vor dem Download reservieren (Groesse laut Metadaten):
      // so wird eine abgewiesene Anfrage gar nicht erst aus dem Speicher geholt.
      // Pruefen und Reservieren ohne await dazwischen. Eine Wiederholung
      // (Race, siehe unten) reserviert erneut; das ist hoechstens eine kleine
      // Ueberschaetzung.
      const wait = readsPerName.retryAfter(name, size);
      if (wait > 0) return tooMany(res, wait);
      readsPerName.take(name, size);
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

  async function put(req, res, path, name) {
    // Zu grosse Anfrage gleich abweisen, ohne den Body zu lesen.
    const declared = header(req, 'content-length');
    if (declared !== undefined && /^[0-9]+$/.test(declared.trim()) && Number(declared) > MAX_BYTES) {
      return send(res, 413);
    }
    const body = await readBody(req);
    if (!body || body.length === 0) return send(res, 400);
    if (body.length > MAX_BYTES) return send(res, 413);
    // Kein Ultracipher-v1-Format: kein Speicherzugriff, kein Budget verbraucht.
    if (!looksLikeFormatV1(body)) return send(res, 400);

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

    const create = match === 0;
    // Alle Vorpruefungen bestanden. Beim Anlegen zuerst nur pruefen (ohne zu
    // reservieren), ob die Limits noch Platz haben: fuer ohnehin abgelehnte
    // Anlagen entfaellt der Listenaufruf.
    if (create && Math.max(creates.retryAfter(1), writesPerName.retryAfter(name, 1)) > 0) {
      return tooMany(res, Math.max(creates.retryAfter(1), writesPerName.retryAfter(name, 1)));
    }
    // Obergrenze der Dateizahl (nur beim Anlegen), vor dem Speichern und vor den
    // Zaehlern: ein 507 verbraucht kein Budget. Ein Listenaufruf mit hoechstens
    // maxFiles + 1 Namen, ohne Seitenwechsel. Zwei gleichzeitige Anlagen koennen
    // die Grenze um wenige ueberschreiten (zwischen Zaehlen und Speichern liegt
    // kein Schloss); das ist gewollt (KISS).
    if (create && (await countFiles()) >= maxFiles) {
      log('ucdb', 'max-files');
      return send(res, 507);
    }

    // Jetzt zaehlt die Anfrage: erneut pruefen und reservieren, synchron (das
    // await oben hat den Zustand evtl. veraendert). Ein Anlegen, das der Speicher
    // danach mit 412 abweist, bleibt im globalen Anlegezaehler gezaehlt
    // (einfacher; kostet nur einen Platz); der Namenszaehler wird erstattet.
    const wait = Math.max(create ? creates.retryAfter(1) : 0, writesPerName.retryAfter(name, 1));
    if (wait > 0) return tooMany(res, wait);
    if (create) creates.take(1);
    const ticket = writesPerName.take(name, 1, true);

    const file = bucket.file(path);
    try {
      await file.save(body, {
        resumable: false,
        contentType: OCTET_STREAM,
        // Sonst loescht die Bibliothek bei einer CRC32C-Abweichung die Datei
        // OHNE ifGenerationMatch (file.js, _File_validateIntegrity).
        validation: false,
        preconditionOpts: { ifGenerationMatch: match },
      });
    } catch (e) {
      writesPerName.release(ticket);
      throw e;
    }
    writesPerName.commit();
    res.set('ETag', `"${generationAfterSave(file)}"`);
    return send(res, create ? 201 : 200);
  }

  async function remove(req, res, path, name) {
    const ifMatch = header(req, 'if-match');
    if (ifMatch === undefined) return send(res, 428);
    const generation = parseEtag(ifMatch);
    if (generation === null) return send(res, 412);
    const wait = writesPerName.retryAfter(name, 1);
    if (wait > 0) return tooMany(res, wait);
    const ticket = writesPerName.take(name, 1, true);
    try {
      await bucket.file(path).delete({ ifGenerationMatch: generation });
    } catch (e) {
      // Der Speicher hat abgewiesen (412/404/Fehler): Reservierung zurueck, siehe NameWindows.
      writesPerName.release(ticket);
      if (Number(e && e.code) !== 404) throw e;
      // Datei fehlt: fuer den Client ein Versionskonflikt; fehlt der Bucket,
      // ein Serverfehler.
      if (await bucketMissing(res, 'DELETE')) return;
      return send(res, 412);
    }
    writesPerName.commit();
    return send(res, 204);
  }

  return async function handler(req, res) {
    // Ohne diesen Header sieht die Web-App den ETag nicht (CORS).
    res.set('Access-Control-Expose-Headers', 'ETag');
    // Fuer alle Antworten: nie cachen, kein Content-Type-Raten.
    res.set('Cache-Control', 'no-store');
    res.set('X-Content-Type-Options', 'nosniff');
    // Ungueltiger konfigurierter Praefix: alles ablehnen, den Wert nicht loggen.
    if (!prefixValid) {
      log('ucdb', 'bad-prefix');
      return send(res, 500);
    }
    const name = nameFromPath(req.path, prefix);
    if (name === null) return send(res, 404);
    // Der Speicherpfad haengt nicht vom Praefix ab: ein anderer Praefix darf
    // keine gespeicherte Datei verwaisen.
    const path = `${STORAGE_PREFIX}${name}`;
    try {
      switch (req.method) {
        case 'GET':
          return await get(res, path, name);
        case 'PUT':
          return await put(req, res, path, name);
        case 'DELETE':
          return await remove(req, res, path, name);
        default:
          res.set('Allow', 'GET, PUT, DELETE');
          return send(res, 405);
      }
    } catch (e) {
      const code = Number(e && e.code);
      if (code === 412) return send(res, 412);
      // Ein 404 aus dem Speicher bei PUT kommt nur, wenn z. B. der Bucket fehlt
      // (PUT mit Bedingung liefert 412): das ist ein Serverfehler (500). GET
      // und DELETE behandeln ihr 404 selbst (siehe bucketMissing).
      // Nie Name, Pfad, Inhalt oder die Fehlermeldung loggen (kann den Pfad
      // enthalten), nur Methode und Code.
      log('ucdb', req.method, Number.isFinite(code) ? code : 'error');
      return send(res, 500);
    }
  };
}

// Optionen aus Umgebungsvariablen (`.env.<projekt-id>`, siehe .env.example).
// Fehlende, leere oder ungueltige Zahlen lassen den Standard des Handlers
// gelten (die Option fehlt dann). Ein nicht leerer Praefix wird unveraendert
// durchgereicht: ein ungueltiger fuehrt im Handler zu 500 `bad-prefix`.
function optionsFromEnv(env = {}) {
  const options = {};
  const count = (key) => {
    const v = env[key];
    return typeof v === 'string' && /^[0-9]{1,15}$/.test(v.trim()) ? Number(v.trim()) : undefined;
  };
  const set = (key, value) => {
    if (value !== undefined) options[key] = value;
  };
  if (typeof env.UCDB_PREFIX === 'string' && env.UCDB_PREFIX.trim() !== '') options.prefix = env.UCDB_PREFIX.trim();
  set('createsPerDay', count('UCDB_CREATES_PER_DAY'));
  set('writesPerHourPerName', count('UCDB_WRITES_PER_HOUR_PER_NAME'));
  const mib = count('UCDB_READ_MIB_PER_HOUR_PER_NAME');
  if (mib !== undefined) options.readBytesPerHourPerName = mib * 1024 * 1024;
  set('maxFiles', count('UCDB_MAX_FILES'));
  return options;
}

module.exports = {
  optionsFromEnv,
  createHandler,
  nameFromPath,
  parseEtag,
  readBody,
  looksLikeFormatV1,
  MAX_BYTES,
  MIN_FILE_LENGTH,
  DEFAULT_PREFIX,
  NameWindows,
};
