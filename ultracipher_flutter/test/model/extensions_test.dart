import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:ultracipher_flutter/src/model/extensions.dart';

// These tests verify the `fillWith` extension (extensions.dart:4-10), which
// is used to scrub decrypted plaintext buffers after use. Today that is the
// app's v2 database format (ultracipher_flutter/lib/src/core.dart,
// `decryptDatabase`):
//
//   var plaintext = decrypt(ciphertext, key);
//   var tar = BZip2Decoder().decodeBytes(plaintext);
//   plaintext.fillWith(randomIntegers(0xFFFFFFFF));      // fixed-length Uint8List
//   ...
//   var content = file.content as List<int>;             // archive-returned list
//   var text = utf8.decode(content);
//   content.fillWith(randomIntegers(0xFFFFFFFF));
//
// (The same pattern previously also lived in `Ultracipher.decrypt`, the now
// -removed v1 read path in the former core package's lib/src/backend.dart, which is
// where this regression was originally found and fixed.)
//
// Original (buggy) implementation:
//   void fillWith(Iterable<T> source){
//     replaceRange(0, length -1, source);
//   }
// - off-by-one: never overwrote the last element
// - threw UnsupportedError on fixed-length lists (e.g. Uint8List), because
//   replaceRange always throws "Cannot remove from a fixed-length list"
// - hung forever on growable Lists with an infinite Iterable, because
//   ListMixin.replaceRange calls `newContents.toList()` internally
//
// Fixed implementation:
//   void fillWith(Iterable<T> source) {
//     var it = source.iterator;
//     for (var i = 0; i < length; i++) {
//       it.moveNext();
//       this[i] = it.current;
//     }
//   }
// Direct index assignment works on both growable and fixed-length lists.
// Only `length` elements are consumed from the source iterator, so it
// terminates even for an infinite Iterable.
//
// End-to-end coverage of the real call sites (v2's `decryptDatabase`, both
// the fixed-length Uint8List plaintext buffer and the archive-returned
// List<int> content buffer) lives in
// ultracipher_flutter/test/crypto_behaviour_test.dart, in the
// 'UltracipherApp.encryptDatabase / decryptDatabase' group -- a roundtrip
// there would throw (fixed-length case) or hang (infinite-iterable case) if
// this extension regressed. The off-by-one case is only caught here, since
// the roundtrip doesn't assert that the scratch buffers were actually
// scrubbed.
void main() {
  group('fillWith extension (Extensions.dart) - fixed implementation', () {
    test('overwrites ALL elements, including the last one (no off-by-one)',
        () {
      var list = <int>[1, 2, 3, 4, 5];
      list.fillWith(List.filled(list.length, 0));

      expect(list, everyElement(0));
      expect(list.last, 0, reason: 'Last element must be overwritten too');
    });

    test('works on fixed-length lists (e.g. Uint8List) without throwing', () {
      // This is exactly the situation in v2's `decryptDatabase`: the
      // decrypted plaintext buffer is a fixed-length typed-data list, not a
      // growable List.
      var fixedLengthList = Uint8List(5);

      expect(
          () => fixedLengthList.fillWith([9, 9, 9, 9, 9]), returnsNormally);
      expect(fixedLengthList, everyElement(9));
    });

    test('completes immediately for an infinite Iterable (no hang)', () {
      // `randomIntegers()` (Extensions.dart:30) is an infinite generator.
      // `fillWith` must only consume exactly `length` elements via its
      // Iterator and must return instead of hanging.
      var list = <int>[1, 2, 3, 4, 5];
      list.fillWith(randomIntegers(0xFFFFFFFF));
      expect(list.length, 5);
      // All 5 elements should have been overwritten (astronomically unlikely
      // to still match the originals).
      expect(list, isNot([1, 2, 3, 4, 5]));
    });

    test(
        'works on a fixed-length Uint8List with the infinite randomIntegers() source '
        '(exact reproduction of the plaintext-scrubbing usage in decryptDatabase)',
        () {
      var compressed = Uint8List(16);
      expect(() => compressed.fillWith(randomIntegers(0xFFFFFFFF)),
          returnsNormally);
      // All bytes should have been overwritten (astronomically unlikely to
      // remain all-zero by chance for 16 random bytes).
      expect(compressed.every((b) => b == 0), isFalse);
    });
  });
}
