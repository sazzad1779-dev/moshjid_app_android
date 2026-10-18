import 'package:flutter/material.dart';

import '../data/repositories/txn_repository.dart';

/// Makes the single app-wide [TxnRepository] available to the widget tree
/// without any service-locator dependency. The store is created once in
/// `main()` and threaded down from here.
class AppScope extends InheritedWidget {
  final TxnRepository repo;

  const AppScope({super.key, required this.repo, required super.child});

  static TxnRepository of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope is missing above this widget');
    return scope!.repo;
  }

  /// Reads the repository without registering a dependency — safe to call
  /// from `initState`, where `dependOnInheritedWidgetOfExactType` is not.
  static TxnRepository read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope is missing above this widget');
    return scope!.repo;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) => oldWidget.repo != repo;
}
