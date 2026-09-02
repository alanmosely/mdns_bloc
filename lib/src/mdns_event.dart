import 'package:equatable/equatable.dart';

import 'mdns_constants.dart';

/// Base class for the events understood by `MDnsBloc`.
sealed class MDnsEvent extends Equatable {
  const MDnsEvent();

  @override
  List<Object?> get props => const <Object?>[];
}

/// Starts a search for services of type [serviceType].
///
/// Adding this event while a search is already in flight cancels that search
/// and starts a new one.
final class MDnsEventStartSearch extends MDnsEvent {
  const MDnsEventStartSearch({
    required this.serviceType,
    this.serviceName,
    this.retries = defaultRetries,
    this.timeout = defaultTimeout,
  }) : assert(retries >= 0, 'retries must not be negative');

  /// The service type to search for, e.g. `_http._tcp`.
  final String serviceType;

  /// An optional fully qualified service instance name to look for, e.g.
  /// `example._http._tcp.local`.
  ///
  /// When a discovered service matches this name (case-insensitively, as DNS
  /// names are case-insensitive) the search completes with
  /// `MDnsStatus.matched` instead of `MDnsStatus.found`, and the service is
  /// exposed via `MDnsState.match`.
  final String? serviceName;

  /// The number of additional attempts made when a search resolves no
  /// services.
  final int retries;

  /// How long each individual mDNS lookup waits for responses.
  final Duration timeout;

  @override
  List<Object?> get props =>
      <Object?>[serviceType, serviceName, retries, timeout];
}

/// Cancels the search currently in flight, if any, moving the state to
/// `MDnsStatus.stopped`. Has no effect when no search is running.
final class MDnsEventStopSearch extends MDnsEvent {
  const MDnsEventStopSearch();
}
