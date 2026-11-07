// In-memory Sync-Server als http.MockClient, nach dem REST-Protokoll von
// RestBackend (lib/src/backend/rest_backend.dart): ein Objekt je Name, das ETag
// ist eine hochgezaehlte "Generation" wie bei der Firebase-Funktion.
//
//   GET     200 Rohbytes + ETag | 404
//   PUT     If-None-Match: *  -> 201 + ETag | 412 (existiert)
//           If-Match: "<g>"   -> 200 + ETag | 412 (andere Version oder fehlt)
//           ohne beide        -> 428
//   DELETE  If-Match: "<g>"   -> 204 | 412 (andere Version oder fehlt)
//
// Test-Schalter: [sendEtag] (false: der Server gibt das ETag nicht frei),
// [failWith] (jede Anfrage bekommt diesen Status), [beforeRequest]. [seed] und
// [deleteFile] aendern den Stand ohne Pruefung ("ein anderes Geraet").
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class FakeRestServer {
  final Map<String, Uint8List> _objects = {};
  final Map<String, int> _generations = {};
  int _counter = 0;

  /// Jede Anfrage, die ankam (auch abgelehnte), in der Reihenfolge.
  final List<http.Request> requests = [];

  bool sendEtag = true;
  int? failWith;
  Map<String, String> failHeaders = const {};
  void Function(http.Request request)? beforeRequest;

  late final MockClient client = MockClient((request) async => _handle(request));

  /// Der gespeicherte Stand zu [name] oder null.
  Uint8List? stored(String name) =>
      _objects[name] == null ? null : Uint8List.fromList(_objects[name]!);

  /// Das aktuelle ETag (ohne Anfuehrungszeichen) zu [name] oder null.
  String? generation(String name) => _generations[name]?.toString();

  void seed(String name, Uint8List bytes) {
    _objects[name] = Uint8List.fromList(bytes);
    _generations[name] = ++_counter;
  }

  void deleteFile(String name) {
    _objects.remove(name);
    _generations.remove(name);
  }

  http.Response _handle(http.Request request) {
    requests.add(request);
    beforeRequest?.call(request);
    var forced = failWith;
    if (forced != null) {
      return http.Response('forced $forced', forced, headers: failHeaders);
    }
    var name = request.url.pathSegments.last;
    Map<String, String> etag(String name) =>
        sendEtag ? {'etag': '"${_generations[name]}"'} : {};
    switch (request.method) {
      case 'GET':
        var bytes = _objects[name];
        if (bytes == null) return http.Response('', 404);
        return http.Response.bytes(bytes, 200,
            headers: {
              'content-type': 'application/octet-stream',
              ...etag(name),
            });
      case 'PUT':
        var ifNoneMatch = request.headers['If-None-Match'];
        var ifMatch = request.headers['If-Match'];
        if (request.bodyBytes.isEmpty) return http.Response('', 400);
        bool create;
        if (ifNoneMatch == '*') {
          create = true;
          if (_objects.containsKey(name)) return http.Response('', 412);
        } else if (ifMatch != null) {
          create = false;
          var current = _generations[name];
          if (current == null || ifMatch.replaceAll('"', '') != '$current') {
            return http.Response('', 412);
          }
        } else {
          return http.Response('', 428);
        }
        _objects[name] = Uint8List.fromList(request.bodyBytes);
        _generations[name] = ++_counter;
        return http.Response('', create ? 201 : 200, headers: etag(name));
      case 'DELETE':
        var ifMatch = request.headers['If-Match'];
        if (ifMatch == null) return http.Response('', 428);
        var current = _generations[name];
        if (current == null || ifMatch.replaceAll('"', '') != '$current') {
          return http.Response('', 412);
        }
        deleteFile(name);
        return http.Response('', 204);
      default:
        return http.Response('', 405);
    }
  }
}
