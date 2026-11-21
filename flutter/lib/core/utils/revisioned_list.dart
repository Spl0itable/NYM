import 'dart:collection';

class RevisionedList<E> extends ListBase<E> {
  final List<E> _items = <E>[];
  int _revision = 0;

  int get revision => _revision;

  @override
  int get length => _items.length;

  @override
  set length(int value) {
    _items.length = value;
    _revision++;
  }

  @override
  E operator [](int index) => _items[index];

  @override
  void operator []=(int index, E value) {
    _items[index] = value;
    _revision++;
  }

  @override
  void add(E element) {
    _items.add(element);
    _revision++;
  }

  @override
  void addAll(Iterable<E> iterable) {
    _items.addAll(iterable);
    _revision++;
  }
}
