import 'dart:io';

import 'package:equatable/equatable.dart';

/// A service instance discovered over mDNS.
///
/// One instance corresponds to one SRV record: the instance [name] announced
/// over the wire, the [host] and [port] it points at, the [addresses]
/// resolved for that host, and the TXT attributes published alongside it.
/// While a search is still running, instances are emitted as soon as their
/// SRV record resolves, so [addresses] and [txt] may still be growing in
/// later `searching` snapshots.
final class MDnsService extends Equatable {
  const MDnsService({
    required this.name,
    required this.host,
    required this.port,
    this.priority = 0,
    this.weight = 0,
    this.addresses = const <InternetAddress>[],
    this.txt = const <String>[],
  });

  /// The full service instance name as announced, e.g.
  /// `Printer._http._tcp.local`.
  ///
  /// DNS names are case-insensitive; compare accordingly.
  final String name;

  /// The hostname providing the service (the SRV target), e.g.
  /// `printer.local`.
  final String host;

  /// The port the service listens on.
  final int port;

  /// The SRV priority: lower values are preferred.
  final int priority;

  /// The SRV weight, for choosing between records of equal [priority].
  final int weight;

  /// The IPv4 and IPv6 addresses resolved for [host]; empty when none
  /// resolved (yet).
  final List<InternetAddress> addresses;

  /// The TXT attributes announced for this instance, one `key=value` (or
  /// bare `key`) string each, deduplicated. Empty when the instance
  /// publishes no metadata.
  final List<String> txt;

  /// The TXT attributes parsed into a map: `key=value` becomes `key: value`
  /// and a bare `key` becomes `key: null`.
  ///
  /// Keys are compared case-insensitively and the first occurrence of a key
  /// wins (mirroring RFC 6763's rule for duplicate keys within one record);
  /// the map preserves the case of that first occurrence. Since [txt]
  /// accumulates the attributes of every TXT record seen during the search,
  /// a responder re-announcing changed TXT data mid-scan keeps its earlier
  /// value here.
  Map<String, String?> get txtAttributes {
    final Map<String, String?> attributes = <String, String?>{};
    final Set<String> seenKeys = <String>{};
    for (final String entry in txt) {
      final int separator = entry.indexOf('=');
      final String key =
          separator == -1 ? entry : entry.substring(0, separator);
      if (key.isEmpty || !seenKeys.add(key.toLowerCase())) {
        continue;
      }
      attributes[key] = separator == -1 ? null : entry.substring(separator + 1);
    }
    return attributes;
  }

  @override
  String toString() {
    return 'MDnsService { name: $name, host: $host, port: $port, '
        'addresses: ${addresses.map((InternetAddress a) => a.address).join(', ')}, '
        'txt: ${txt.join('; ')} }';
  }

  @override
  List<Object?> get props =>
      <Object?>[name, host, port, priority, weight, addresses, txt];
}
