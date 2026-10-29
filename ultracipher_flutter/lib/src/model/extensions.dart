import 'dart:math';

extension ListExtension<T> on List<T> {
  void fillWith(Iterable<T> source) {
    var it = source.iterator;
    for (var i = 0; i < length; i++) {
      it.moveNext();
      this[i] = it.current;
    }
  }

  int indexOfSubList(List<T> pattern) {
    if (pattern.isEmpty) return 0;
    if (pattern.length > length) return -1;

    for (int i = 0; i <= length - pattern.length; i++) {
      bool match = true;
      for (int j = 0; j < pattern.length; j++) {
        if (this[i + j] != pattern[j]) {
          match = false;
          break;
        }
      }
      if (match) return i;
    }
    return -1;
  }
}

Iterable<int> randomIntegers(int max) sync*{
  var rnd = Random();
  while(true) {
    yield rnd.nextInt(max);
  }
}
