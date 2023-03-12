import 'package:equatable/equatable.dart';
import 'package:multicast_dns/multicast_dns.dart';

/// A list of all the possible states that the mDNS discovery can be in
enum MDnsStatus {
  initial,
  mDnsScanned,
  mDnsFound,
  mDnsMatch,
  error,
}

/// MDnsState is a class that contains a bunch of properties that are used to store the state
/// of the mDNS discovery
class MDnsState extends Equatable {
  const MDnsState({
    this.status = MDnsStatus.initial,
    this.dnsPtrRecords = const <PtrResourceRecord>[],
    this.dnsSrvRecords = const <String, SrvResourceRecord>{},
    this.service,
    this.errorMsg = "",
  });

  final MDnsStatus status;
  final List<PtrResourceRecord> dnsPtrRecords;
  final Map<String, SrvResourceRecord> dnsSrvRecords;
  final SrvResourceRecord? service;
  final String errorMsg;

  MDnsState copyWith({
    MDnsStatus? status,
    List<PtrResourceRecord>? dnsPtrRecords,
    Map<String, SrvResourceRecord>? dnsSrvRecords,
    SrvResourceRecord? service,
    String? errorMsg,
  }) {
    return MDnsState(
      status: status ?? this.status,
      dnsPtrRecords: dnsPtrRecords ?? this.dnsPtrRecords,
      dnsSrvRecords: dnsSrvRecords ?? this.dnsSrvRecords,
      service: service ?? this.service,
      errorMsg: errorMsg ?? this.errorMsg,
    );
  }

  @override
  String toString() {
    return '''MDnsState { status: $status, dnsPtrRecords: ${dnsPtrRecords.length}, dnsSrvRecords: ${dnsSrvRecords.length}, service: $service, errorMsg: $errorMsg''';
  }

  @override
  List<Object?> get props =>
      [status, dnsPtrRecords, dnsSrvRecords, service, errorMsg];
}
