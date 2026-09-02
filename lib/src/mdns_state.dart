import 'package:equatable/equatable.dart';
import 'package:multicast_dns/multicast_dns.dart';

/// The lifecycle of an mDNS search.
enum MDnsStatus {
  /// No search has been started yet.
  initial,

  /// A search is currently in flight. States with this status carry the
  /// records discovered so far, growing as the search resolves them.
  searching,

  /// A search completed without discovering any services.
  mDnsScanned,

  /// A search discovered services, but none matched the requested service
  /// instance name (or no name was requested).
  mDnsFound,

  /// A search discovered a service matching the requested instance name.
  mDnsMatch,

  /// The search in flight was cancelled by an `MDnsEventStopSearch`. The
  /// state retains the records discovered before the cancellation.
  stopped,

  /// The search failed; see [MDnsState.errorMsg].
  error,
}

/// The state of an mDNS search and the records it has discovered.
class MDnsState extends Equatable {
  const MDnsState({
    this.status = MDnsStatus.initial,
    this.dnsPtrRecords = const <PtrResourceRecord>[],
    this.dnsSrvRecords =
        const <SrvResourceRecord, List<IPAddressResourceRecord>>{},
    this.dnsTxtRecords = const <String, List<TxtResourceRecord>>{},
    this.service,
    this.errorMsg = '',
  });

  /// Where the search currently is in its lifecycle.
  final MDnsStatus status;

  /// The unique PTR records discovered across all attempts of the search.
  final List<PtrResourceRecord> dnsPtrRecords;

  /// The SRV records discovered, each mapped to the IPv4/IPv6 address records
  /// resolved for its target host (an empty list when no address resolved).
  final Map<SrvResourceRecord, List<IPAddressResourceRecord>> dnsSrvRecords;

  /// The TXT records discovered, keyed by *lowercased* service instance name
  /// (DNS names are case-insensitive): look up an instance's TXT data with
  /// `dnsTxtRecords[srv.name.toLowerCase()]`. Instances without TXT data
  /// have no entry.
  final Map<String, List<TxtResourceRecord>> dnsTxtRecords;

  /// The record matching `MDnsEventStartSearch.service`, when one was found.
  final SrvResourceRecord? service;

  /// A description of what went wrong when [status] is [MDnsStatus.error].
  final String errorMsg;

  static const Object _unset = Object();

  /// Creates a copy of this state with the given fields replaced.
  ///
  /// Pass `service: null` explicitly to clear [service]; omitting the
  /// parameter keeps the current value.
  MDnsState copyWith({
    MDnsStatus? status,
    List<PtrResourceRecord>? dnsPtrRecords,
    Map<SrvResourceRecord, List<IPAddressResourceRecord>>? dnsSrvRecords,
    Map<String, List<TxtResourceRecord>>? dnsTxtRecords,
    Object? service = _unset,
    String? errorMsg,
  }) {
    return MDnsState(
      status: status ?? this.status,
      dnsPtrRecords: dnsPtrRecords ?? this.dnsPtrRecords,
      dnsSrvRecords: dnsSrvRecords ?? this.dnsSrvRecords,
      dnsTxtRecords: dnsTxtRecords ?? this.dnsTxtRecords,
      service: identical(service, _unset)
          ? this.service
          : service as SrvResourceRecord?,
      errorMsg: errorMsg ?? this.errorMsg,
    );
  }

  @override
  String toString() {
    return 'MDnsState { status: $status, '
        'dnsPtrRecords: ${dnsPtrRecords.length}, '
        'dnsSrvRecords: ${dnsSrvRecords.length}, '
        'dnsTxtRecords: ${dnsTxtRecords.length}, '
        'service: $service, errorMsg: $errorMsg }';
  }

  @override
  List<Object?> get props => <Object?>[
        status,
        dnsPtrRecords,
        dnsSrvRecords,
        dnsTxtRecords,
        service,
        errorMsg,
      ];
}
