import 'dart:math' as math;

final _random = math.Random.secure();

/// Short, sortable, collision-resistant id: base36 time + random suffix.
String newId() {
  final time = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final rand = List.generate(6, (_) => _random.nextInt(36).toRadixString(36)).join();
  return '$time$rand';
}

int newSeed() => _random.nextInt(1 << 31);
