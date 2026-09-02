import 'dart:async';
import 'dart:io';

import 'package:bloc/bloc.dart';
import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:meta/meta.dart';
import 'package:multicast_dns/multicast_dns.dart';

import 'mdns_event.dart';
import 'mdns_service.dart';
import 'mdns_state.dart';

/// A [Bloc] that performs service discovery over multicast DNS (mDNS).
///
/// Add an [MDnsEventStartSearch] to begin a search; progress and results are
/// reported through [MDnsState]. While the search runs, services are emitted
/// progressively: each `MDnsStatus.searching` state carries a snapshot of
/// everything discovered so far. Adding another [MDnsEventStartSearch] while
/// a search is in flight cancels it and starts over, and an
/// [MDnsEventStopSearch] cancels it outright, retaining what was found.
///
/// Every search runs on its own [MDnsClient], created per search and stopped
/// when the search completes, is cancelled, or the bloc is closed. Pass a
/// custom `clientFactory` to substitute a client (e.g. a fake in tests); it
/// must return a fresh instance on every call, matching the per-search
/// model. By default the bloc creates an [MDnsClient] whose sockets it
/// tracks, so they can be reclaimed even when starting the client fails
/// partway. Pass `interfacesFactory` to control which network interfaces
/// each search listens on (e.g. to exclude a VPN interface); it applies to
/// injected clients too, since the bloc owns the `start()` call.
///
/// A failure — thrown by a lookup, or reported asynchronously by the
/// client's receive socket — cancels the search and is surfaced as an
/// [MDnsStatus.error] state carrying the original error object.
class MDnsBloc extends Bloc<MDnsEvent, MDnsState> {
  MDnsBloc({
    MDnsClient Function()? clientFactory,
    NetworkInterfacesFactory? interfacesFactory,
    @visibleForTesting RawDatagramSocketFactory? socketFactory,
  })  : _clientFactory = clientFactory,
        _interfacesFactory = interfacesFactory,
        _socketFactory = socketFactory,
        super(const MDnsState()) {
    on<MDnsEventStartSearch>(_onStart, transformer: restartable());
    on<MDnsEventStopSearch>(_onStop);
  }

  final MDnsClient Function()? _clientFactory;

  /// Selects the network interfaces every search listens on; passed to
  /// [MDnsClient.start]. When null, the client's default (all multicast-
  /// capable interfaces) is used.
  final NetworkInterfacesFactory? _interfacesFactory;

  /// Binds the sockets of the default client; a test seam for exercising the
  /// socket-reclaim path without touching the network.
  final RawDatagramSocketFactory? _socketFactory;

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
    final List<String> discoveredNames = <String>[];
    final Map<String, _ServiceResolution> resolutionsByName =
        <String, _ServiceResolution>{};

    // The first failure of the search, wherever it surfaced: a lookup stream
    // erroring, or the client's receive socket reporting an error outside
    // the handler's await chain. Recording a failure also stops the client,
    // so pending lookup streams unwind and the error state surfaces promptly
    // instead of after the remaining lookups run their full timeouts.
    Object? failure;
    StackTrace? failureTrace;
    void recordFailure(Object error, StackTrace stackTrace) {
      failure ??= error;
      failureTrace ??= stackTrace;
      if (identical(_activeClient, client)) {
        _activeClient = null;
      }
      _stopClient(client);
    }

    /// Whether this search is over: superseded, stopped, closed, or failed.
    bool searchEnded() =>
        generation != _generation || failure != null || emit.isDone;

    /// Returns [future] with its errors contained: a listener is attached
    /// immediately, so a failure while the future sits in a pending list
    /// during an open `await for` cannot become an unhandled zone error.
    ///
    /// A [StateError] after the search has ended is the expected sound of a
    /// lookup unwinding on a stopped client, and is swallowed; every other
    /// error — including a [StateError] thrown while the search is live,
    /// which can only be a defect — is recorded as the search's failure.
    Future<void> guarded(Future<void> future) {
      return future.then<void>(
        (_) {},
        onError: (Object error, StackTrace stackTrace) {
          if (error is StateError && searchEnded()) {
            return;
          }
          recordFailure(error, stackTrace);
        },
      );
    }

    List<MDnsService> snapshotServices() => List<MDnsService>.unmodifiable(
          resolutionsByName.values
              .expand((_ServiceResolution resolution) => resolution.services()),
        );

    List<String> snapshotNames() => List<String>.unmodifiable(discoveredNames);

    // Emits a searching-status snapshot of everything discovered so far. The
    // services are rebuilt from the mutable accumulators on every call, so
    // emitted states can never be mutated by later discoveries. After a
    // failure the search only unwinds, so nothing further is reported.
    void emitProgress() {
      if (_isStale(generation, emit) || failure != null) {
        return;
      }
      emit(MDnsState(
        status: MDnsStatus.searching,
        services: snapshotServices(),
        discoveredNames: snapshotNames(),
      ));
    }

    try {
      await client.start(
        interfacesFactory: _interfacesFactory,
        // Without onError, an error event on the client's receive socket is
        // an unhandled zone error the bloc could never surface. Recording it
        // stops the client, so pending lookups unwind and the handler
        // reports it below.
        onError: recordFailure,
      );
      if (_isStale(generation, emit)) {
        return;
      }
      _activeClient = client;

      final Set<String> knownNames = <String>{};
      bool anyServiceResolved() => resolutionsByName.values
          .any((_ServiceResolution resolution) => resolution.srvs.isNotEmpty);

      int attempt = 0;
      while (!_isStale(generation, emit) &&
          failure == null &&
          !anyServiceResolved() &&
          attempt <= event.retries) {
        // mDNS responders may announce more than once per query window, and
        // earlier attempts may have seen a PTR whose service could not be
        // resolved, so deduplicate within the attempt but resolve again.
        final Set<String> attemptNames = <String>{};
        final List<Future<void>> resolutions = <Future<void>>[];
        await for (final PtrResourceRecord ptr
            in client.lookup<PtrResourceRecord>(
          ResourceRecordQuery.serverPointer(event.serviceType),
          timeout: event.timeout,
        )) {
          // DNS names are case-insensitive; key the accumulators on the
          // lowercased instance name so differently-cased announcements of
          // one instance collapse.
          final String key = ptr.domainName.toLowerCase();
          if (!attemptNames.add(key)) {
            continue;
          }
          if (knownNames.add(key)) {
            discoveredNames.add(ptr.domainName);
            resolutionsByName[key] = _ServiceResolution(ptr.domainName);
            emitProgress();
          }
          resolutions.add(guarded(
            _resolveService(
              client,
              ptr.domainName,
              event.timeout,
              resolutionsByName[key]!,
              emitProgress,
              guarded,
            ),
          ));
        }
        await Future.wait(resolutions);
        attempt++;
      }

      if (_isStale(generation, emit)) {
        return;
      }
      if (failure != null) {
        Error.throwWithStackTrace(failure!, failureTrace ?? StackTrace.current);
      }

      final List<MDnsService> services = snapshotServices();
      if (services.isEmpty) {
        emit(MDnsState(
          status: MDnsStatus.noneFound,
          discoveredNames: snapshotNames(),
        ));
      } else {
        final MDnsService? match = _findMatch(services, event.serviceName);
        emit(MDnsState(
          status: match == null ? MDnsStatus.found : MDnsStatus.matched,
          services: services,
          discoveredNames: snapshotNames(),
          match: match,
        ));
      }
    } catch (error, stackTrace) {
      if (_isStale(generation, emit)) {
        return;
      }
      recordFailure(error, stackTrace);
      emit(MDnsState(
        status: MDnsStatus.error,
        services: snapshotServices(),
        discoveredNames: snapshotNames(),
        error: failure,
        stackTrace: failureTrace,
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

  /// Looks up the SRV and TXT records behind [domainName] and the addresses
  /// of the SRV targets, adding what it finds to [resolution] and reporting
  /// each addition through [onProgress]. Futures spawned along the way are
  /// wrapped in [guard], the search's error containment.
  Future<void> _resolveService(
    MDnsClient client,
    String domainName,
    Duration timeout,
    _ServiceResolution resolution,
    void Function() onProgress,
    Future<void> Function(Future<void>) guard,
  ) async {
    await Future.wait(<Future<void>>[
      _resolveSrv(client, domainName, timeout, resolution, onProgress, guard),
      _collectTxt(client, domainName, timeout, resolution, onProgress),
    ]);
  }

  /// Looks up the SRV records behind [domainName] and the addresses of their
  /// target hosts, adding what it finds to [resolution].
  Future<void> _resolveSrv(
    MDnsClient client,
    String domainName,
    Duration timeout,
    _ServiceResolution resolution,
    void Function() onProgress,
    Future<void> Function(Future<void>) guard,
  ) async {
    final List<Future<void>> addressLookups = <Future<void>>[];
    await for (final SrvResourceRecord srv in client.lookup<SrvResourceRecord>(
      ResourceRecordQuery.service(domainName),
      timeout: timeout,
    )) {
      // Record equality includes validUntil, so repeated announcements of
      // the same service compare unequal; deduplicate on identity fields,
      // case-insensitively as DNS names are.
      final bool alreadyKnown = resolution.srvs.any(
        (_SrvResolution known) =>
            known.srv.target.toLowerCase() == srv.target.toLowerCase() &&
            known.srv.port == srv.port,
      );
      if (alreadyKnown) {
        continue;
      }
      final _SrvResolution srvResolution = _SrvResolution(srv);
      resolution.srvs.add(srvResolution);
      onProgress();
      addressLookups.add(guard(
        _resolveAddresses(
            client, srv.target, timeout, srvResolution, onProgress),
      ));
    }
    await Future.wait(addressLookups);
  }

  /// Collects the TXT attributes for [domainName] into [resolution],
  /// deduplicated. A TXT record holds one attribute per line; blank lines
  /// (services without metadata publish a single empty TXT record) are
  /// skipped.
  Future<void> _collectTxt(
    MDnsClient client,
    String domainName,
    Duration timeout,
    _ServiceResolution resolution,
    void Function() onProgress,
  ) async {
    await for (final TxtResourceRecord txt in client.lookup<TxtResourceRecord>(
      ResourceRecordQuery.text(domainName),
      timeout: timeout,
    )) {
      bool added = false;
      for (final String line in txt.text.split('\n')) {
        final String entry = line.trim();
        if (entry.isEmpty || resolution.txt.contains(entry)) {
          continue;
        }
        resolution.txt.add(entry);
        added = true;
      }
      if (added) {
        onProgress();
      }
    }
  }

  /// Resolves the IPv4 and IPv6 addresses of [target] into [resolution].
  Future<void> _resolveAddresses(
    MDnsClient client,
    String target,
    Duration timeout,
    _SrvResolution resolution,
    void Function() onProgress,
  ) async {
    final Set<String> seenAddresses = <String>{};
    await Future.wait(<Future<void>>[
      _collectAddresses(
        client,
        ResourceRecordQuery.addressIPv4(target),
        timeout,
        resolution,
        seenAddresses,
        onProgress,
      ),
      _collectAddresses(
        client,
        ResourceRecordQuery.addressIPv6(target),
        timeout,
        resolution,
        seenAddresses,
        onProgress,
      ),
    ]);
  }

  Future<void> _collectAddresses(
    MDnsClient client,
    ResourceRecordQuery query,
    Duration timeout,
    _SrvResolution resolution,
    Set<String> seenAddresses,
    void Function() onProgress,
  ) async {
    await for (final IPAddressResourceRecord record
        in client.lookup<IPAddressResourceRecord>(query, timeout: timeout)) {
      if (seenAddresses.add(record.address.address)) {
        resolution.addresses.add(record.address);
        onProgress();
      }
    }
  }

  /// Returns the discovered service whose instance name matches
  /// [serviceName], compared case-insensitively as DNS names are
  /// case-insensitive.
  MDnsService? _findMatch(List<MDnsService> services, String? serviceName) {
    if (serviceName == null) {
      return null;
    }
    final String wanted = serviceName.toLowerCase();
    for (final MDnsService service in services) {
      if (service.name.toLowerCase() == wanted) {
        return service;
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
    final RawDatagramSocketFactory bind =
        _socketFactory ?? RawDatagramSocket.bind;
    final List<RawDatagramSocket> sockets = <RawDatagramSocket>[];
    final MDnsClient client = MDnsClient(
      rawDatagramSocketFactory: (
        dynamic host,
        int port, {
        bool reuseAddress = true,
        bool reusePort = false,
        int ttl = 1,
      }) async {
        final RawDatagramSocket socket = await bind(
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

/// Accumulates the records resolved for one service instance while a search
/// runs.
class _ServiceResolution {
  _ServiceResolution(this.name);

  /// The instance name as first announced.
  final String name;

  /// The SRV records resolved for this instance (usually one), each with the
  /// addresses of its target host.
  final List<_SrvResolution> srvs = <_SrvResolution>[];

  /// The TXT attributes announced for this instance, deduplicated.
  final List<String> txt = <String>[];

  /// Builds an immutable [MDnsService] per resolved SRV record.
  Iterable<MDnsService> services() {
    return srvs.map((_SrvResolution resolution) => MDnsService(
          name: name,
          host: resolution.srv.target,
          port: resolution.srv.port,
          priority: resolution.srv.priority,
          weight: resolution.srv.weight,
          addresses: List<InternetAddress>.unmodifiable(resolution.addresses),
          txt: List<String>.unmodifiable(txt),
        ));
  }
}

/// One resolved SRV record and the addresses of its target host.
class _SrvResolution {
  _SrvResolution(this.srv);

  final SrvResourceRecord srv;
  final List<InternetAddress> addresses = <InternetAddress>[];
}
