/// Serializes native resource mutations without poisoning the queue on failure.
class LifecycleQueue {
  Future<void> _tail = Future<void>.value();

  Future<void> run(Future<void> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }
}
