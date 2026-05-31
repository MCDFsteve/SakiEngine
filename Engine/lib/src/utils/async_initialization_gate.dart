class AsyncInitializationGate<T> {
  Future<T>? _activeInitialization;
  bool _initialized = false;
  late T _value;

  Future<T> run(Future<T> Function() initialize) async {
    if (_initialized) {
      return _value;
    }

    final activeInitialization = _activeInitialization;
    if (activeInitialization != null) {
      return activeInitialization;
    }

    late final Future<T> initialization;
    initialization = initialize().then((value) {
      _value = value;
      _initialized = true;
      return value;
    }).whenComplete(() {
      if (identical(_activeInitialization, initialization)) {
        _activeInitialization = null;
      }
    });
    _activeInitialization = initialization;
    return initialization;
  }
}
