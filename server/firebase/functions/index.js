'use strict';

// Einstiegspunkt fuer Firebase (Cloud Functions Gen 2). Die Logik steht in
// handler.js; hier nur die Verdrahtung mit dem Default-Bucket des Projekts.

const { onRequest } = require('firebase-functions/v2/https');
const { initializeApp } = require('firebase-admin/app');
const { getStorage } = require('firebase-admin/storage');
const { createHandler } = require('./handler');

initializeApp();

// Erst beim ersten Aufruf: der Default-Bucket kommt aus der Laufzeit-
// Konfiguration, beim Deploy (Code-Analyse) ist sie nicht gesetzt.
let handler;

exports.ucdb = onRequest(
  {
    cors: true,
    region: 'europe-west1',
    maxInstances: 2,
    memory: '512MiB',
    // Mehrere 16-MiB-Bodies gleichzeitig passen so in den Speicher (Body, Kopie
    // fuer den Upload, Antwort-Puffer).
    concurrency: 4,
    timeoutSeconds: 60,
    invoker: 'public',
  },
  (req, res) => {
    handler = handler || createHandler(getStorage().bucket());
    return handler(req, res);
  },
);
