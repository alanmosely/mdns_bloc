import 'dart:async';
import 'dart:io';

import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:multicast_dns/multicast_dns.dart';

import 'mdns_event.dart';
import 'mdns_state.dart';

/// A [Bloc] that performs service discovery over multicast DNS (mDNS).
///
/// Add an [MDnsEventStartSearch] to begin a search; progress and results are
/// reported through [MDnsState]. Adding another [MDnsEventStartSearch] while
/// a search is in flight cancels it and starts over, and an
/// [MDnsEventStopSearch] cancels it outright.
///
/// Every search runs on its own [MDnsClient], created per search and stopped
/// when the search completes, is cancelled, or the bloc is closed. Pass a
/// custom `clientFactory` to configure the client, or to substitute a fake
/// in tests; by default the bloc creates an [MDnsClient] whose sockets it
/// tracks, so they can be reclaimed even when starting the client fails
/// partway.
class MDnsBloc extends Bloc<MDnsEvent, MDnsState> {
  MDnsBloc({MDnsClient Function()? clientFactory})
      : _clientFactory = clientFactory,
        super(const MDnsState()) {
    on<MDnsEventStartSearch>(_onStart, transformer: restartable());
    on<MDnsEventStopSearch>(_onStop);
  }

  final MDnsClient Function()? _clientFactory;

  /// The client used by the search currently in flight, if any.
  MDnsClient? _activeClient;

  /// The sockets bound on behalf of each client the default factory created,
  /// so [_stopClient] can reclaim them even when the client cannot.
  final Expando<List<RawDatagramSocket>> _boundSockets =
      Expando<List<RawDatagramSocket>>('mdns_bloc bound sockets');

  /// Incremented whenever a search starts or is stopped, so that a
  /// superseded search can tell that its results are no longer wanted.
  int _generation = 0;

  Future<void> _onStart(
    MDnsEventStartSearch event,
    Emitter<MDnsState> emit,
  ) async {
    final int generation = ++_generation;
    // Unwind the lookups of any search this one supersedes: stopping the
    // client closes its pending lookup streams.
    _stopActiveClient();

    emit(const MDnsState(status: MDnsStatus.searching));

    final MDnsClient client = _createClient();
    final List<PtrResourceRecord> ptrRecords = <PtrResourceRecord>[];
    final Map<SrvResourceRecord, List<IPAddressResourceRecord>> srvRecords =
        <SrvResourceRecord, List<IPAddressResourceRecord>>{};

    try {
      await client.start();
      if (_isStale(generation, emit)) {
        return;
      }
      _activeClient = client;

      final Set<String> knownPtrNames = <String>{};
      int attempt = 0;
      while (!_isStale(generation, emit) &&
          srvRecords.isEmpty &&
          attempt <= event.retries) {
        // mDNS responders may announce more than once per query window, and
        // earlier attempts may have seen a PTR whose service could not be
        // resolved, so deduplicate within the attempt but resolve again.
        final Set<String> attemptPtrNames = <String>{};
        final List<Future<void>> resolutions = <Future<void>>[];
        await for (final PtrResourceRecord ptr
            in client.lookup<PtrResourceRecord>(
          ResourceRecordQuery.serverPointer(event.serverPointer),
          timeout: event.timeout,
        )) {
          if (!attemptPtrNames.add(ptr.domainName)) {
            continue;
          }
          if (knownPtrNames.add(ptr.domainName)) {
            ptrRecords.add(ptr);
          }
          resolutions.add(
            _resolveService(client, ptr.domainName, event.timeout, srvRecords),
          );
        }
        await Future.wait(resolutions);
        attempt++;
      }

      if (_isStale(generation, emit)) {
        return;
      }

      if (srvRecords.isEmpty) {
        emit(MDnsState(
          status: MDnsStatus.mDnsScanned,
          dnsPtrRecords: ptrRecords,
        ));
      } else {
        final SrvResourceRecord? match = _findMatch(srvRecords, event.service);
        emit(MDnsState(
          status: match == null ? MDnsStatus.mDnsFound : MDnsStatus.mDnsMatch,
          dnsPtrRecords: ptrRecords,
          dnsSrvRecords: srvRecords,
          service: match,
        ));
      }
    } catch (error) {
      if (_isStale(generation, emit)) {
        return;
      }
      emit(MDnsState(
        status: MDnsStatus.error,
        dnsPtrRecords: ptrRecords,
        dnsSrvRecords: srvRecords,
        errorMsg: error.toString(),
      ));
    } finally {
      if (identical(_activeClient, client)) {
        _activeClient = null;
      }
      _stopClient(client);
    }
  }

  Future<void> _onStop(
    MDnsEventStopSearch event,
    Emitter<MDnsState> emit,
  ) async {
    _generation++;
    _stopActiveClient();
    if (state.status == MDnsStatus.searching) {
      emit(state.copyWith(status: MDnsStatus.stopped));
    }
  }

  @override
  Future<void> close() {
    _generation++;
    _stopActiveClient();
    return super.close();
  }

  /// Looks up the SRV records behind [domainName] and the addresses of their
  /// target hosts, adding what it finds to [srvRecords].
  Future<void> _resolveService(
    MDnsClient client,
    String domainName,
    Duration timeout,
    Map<SrvResourceRecord, List<IPAddressResourceRecord>> srvRecords,
  ) async {
    try {
      final List<Future<void>> addressLookups = <Future<void>>[];
      await for (final SrvResourceRecord srv
          in client.lookup<SrvResourceRecord>(
        ResourceRecordQuery.service(domainName),
        timeout: timeout,
      )) {
        // Record equality includes validUntil, so repeated announcements of
        // the same service compare unequal; deduplicate on identity fields.
        final bool alreadyKnown = srvRecords.keys.any(
          (SrvResourceRecord known) =>
              known.name == srv.name &&
              known.target == srv.target &&
              known.port == srv.port,
        );
        if (alreadyKnown) {
          continue;
        }
        final List<IPAddressResourceRecord> addresses =
            <IPAddressResourceRecord>[];
        srvRecords[srv] = addresses;
        addressLookups.add(
          _resolveAddresses(client, srv.target, timeout, addresses),
        );
      }
      await Future.wait(addressLookups);
    } on StateError {
      // The client was stopped while this lookup was in flight (the search
      // was cancelled or superseded); there is nothing left to resolve.
    }
  }

  /// Resolves the IPv4 and IPv6 addresses of [target] into [addresses].
  Future<void> _resolveAddresses(
    MDnsClient client,
    String target,
    Duration timeout,
    List<IPAddressResourceRecord> addresses,
  ) async {
    try {
      final Set<String> seenAddresses = <String>{};
      await Future.wait(<Future<void>>[
        _collectAddresses(
          client,
          ResourceRecordQuery.addressIPv4(target),
          timeout,
          addresses,
          seenAddresses,
        ),
        _collectAddresses(
          client,
          ResourceRecordQuery.addressIPv6(target),
          timeout,
          addresses,
          seenAddresses,
        ),
      ]);
    } on StateError {
      // The client was stopped while this lookup was in flight.
    }
  }

  Future<void> _collectAddresses(
    MDnsClient client,
    ResourceRecordQuery query,
    Duration timeout,
    List<IPAddressResourceRecord> addresses,
    Set<String> seenAddresses,
  ) async {
    await for (final IPAddressResourceRecord record
        in client.lookup<IPAddressResourceRecord>(query, timeout: timeout)) {
      if (seenAddresses.add(record.address.address)) {
        addresses.add(record);
      }
    }
  }

  /// Returns the discovered record whose instance name matches [service],
  /// compared case-insensitively as DNS names are case-insensitive.
  SrvResourceRecord? _findMatch(
    Map<SrvResourceRecord, List<IPAddressResourceRecord>> srvRecords,
    String? service,
  ) {
    if (service == null) {
      return null;
    }
    final String wanted = service.toLowerCase();
    for (final SrvResourceRecord srv in srvRecords.keys) {
      if (srv.name.toLowerCase() == wanted) {
        return srv;
      }
    }
    return null;
  }

  /// Whether the search identified by [generation] has been superseded,
  /// stopped, or outlived by the bloc.
  bool _isStale(int generation, Emitter<MDnsState> emit) =>
      generation != _generation || emit.isDone;

  void _stopActiveClient() {
    final MDnsClient? client = _activeClient;
    _activeClient = null;
    _stopClient(client);
  }

  /// Creates the client for one search: the injected factory's client, or a
  /// default [MDnsClient] whose bound sockets are tracked so [_stopClient]
  /// can reclaim them even when a partially-failed `start()` leaves them
  /// open.
  MDnsClient _createClient() {
    final MDnsClient Function()? factory = _clientFactory;
    if (factory != null) {
      return factory();
    }
    final List<RawDatagramSocket> sockets = <RawDatagramSocket>[];
    final MDnsClient client = MDnsClient(
      rawDatagramSocketFactory: (
        dynamic host,
        int port, {
        bool reuseAddress = true,
        bool reusePort = false,
        int ttl = 1,
      }) async {
        final RawDatagramSocket socket = await RawDatagramSocket.bind(
          host,
          port,
          reuseAddress: reuseAddress,
          reusePort: reusePort,
          ttl: ttl,
        );
        sockets.add(socket);
        return socket;
      },
    );
    _boundSockets[client] = sockets;
    return client;
  }

  /// Stops [client] and reclaims any sockets the default factory bound for
  /// it.
  void _stopClient(MDnsClient? client) {
    if (client == null) {
      return;
    }
    try {
      client.stop();
    } on StateError {
      // Defensive only: multicast_dns 0.3.x's stop() silently returns when
      // the client never finished starting, but a custom clientFactory
      // implementation might throw here.
    }
    // multicast_dns's start() does not clean up after itself when it fails
    // partway (e.g. joinMulticast throwing on a VPN interface), and stop()
    // is a no-op on a client that never finished starting. Close the sockets
    // the default factory bound for this client so failed searches cannot
    // leak them; closing an already-closed socket is harmless.
    final List<RawDatagramSocket>? sockets = _boundSockets[client];
    if (sockets != null) {
      _boundSockets[client] = null;
      for (final RawDatagramSocket socket in sockets) {
        socket.close();
      }
    }
  }
}
