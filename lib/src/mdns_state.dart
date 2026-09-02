import 'package:equatable/equatable.dart';

import 'mdns_service.dart';

/// The lifecycle of an mDNS search.
enum MDnsStatus {
  /// No search has been started yet.
  initial,

  /// A search is currently in flight. States with this status carry the
  /// services discovered so far, growing as the search resolves them.
  searching,

  /// A search completed without resolving any services. Instance names that
  /// were announced but never resolved are in [MDnsState.discoveredNames].
  noneFound,

  /// A search resolved services, but none matched the requested instance
  /// name (or no name was requested).
  found,

  /// A search resolved a service matching the requested instance name; see
  /// [MDnsState.match].
  matched,

  /// The search in flight was cancelled by an `MDnsEventStopSearch`. The
  /// state retains the services discovered before the cancellation.
  stopped,

  /// The search failed; see [MDnsState.error]. The state retains the
  /// services discovered before the failure.
  error,
}

/// The state of an mDNS search and the services it has discovered.
final class MDnsState extends Equatable {
  const MDnsState({
    this.status = MDnsStatus.initial,
    this.services = const <MDnsService>[],
    this.discoveredNames = const <String>[],
    this.match,
    this.error,
    this.stackTrace,
  });

  /// Where the search currently is in its lifecycle.
  final MDnsStatus status;

  /// The service instances resolved so far, in discovery order.
  final List<MDnsService> services;

  /// Every service instance name announced so far (via PTR records), in
  /// discovery order and with its announced case — a superset of the names
  /// in [services], since an announced instance may never resolve.
  final List<String> discoveredNames;

  /// The service matching `MDnsEventStartSearch.serviceName`, when one was
  /// found.
  final MDnsService? match;

  /// What went wrong when [status] is [MDnsStatus.error]: the original
  /// error object (often a `SocketException`), untouched so it can be
  /// matched on by type.
  final Object? error;

  /// The stack trace captured with [error], when one was available.
  ///
  /// Not part of equality: stack traces compare by identity and carry no
  /// state of their own.
  final StackTrace? stackTrace;

  /// A description of [error], or null when there is none.
  String? get errorMessage => error?.toString();

  static const Object _unset = Object();

  /// Creates a copy of this state with the given fields replaced.
  ///
  /// Pass `match: null` (or `error: null`, `stackTrace: null`) explicitly to
  /// clear the field; omitting the parameter keeps the current value.
  MDnsState copyWith({
    MDnsStatus? status,
    List<MDnsService>? services,
    List<String>? discoveredNames,
    Object? match = _unset,
    Object? error = _unset,
    Object? stackTrace = _unset,
  }) {
    return MDnsState(
      status: status ?? this.status,
      services: services ?? this.services,
      discoveredNames: discoveredNames ?? this.discoveredNames,
      match: identical(match, _unset) ? this.match : match as MDnsService?,
      error: identical(error, _unset) ? this.error : error,
      stackTrace: identical(stackTrace, _unset)
          ? this.stackTrace
          : stackTrace as StackTrace?,
    );
  }

  @override
  String toString() {
    return 'MDnsState { status: $status, '
        'services: ${services.length}, '
        'discoveredNames: ${discoveredNames.length}, '
        'match: ${match?.name}, error: $error }';
  }

  @override
  List<Object?> get props =>
      <Object?>[status, services, discoveredNames, match, error];
}
