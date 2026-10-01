import 'dart:async';
import 'dart:io';

import 'package:mdns_bloc/mdns_bloc.dart';
import 'package:mocktail/mocktail.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:test/test.dart';

class MockMDnsClient extends Mock implements MDnsClient {}

class MockRawDatagramSocket extends Mock implements RawDatagramSocket {}

const String _type = '_http._tcp';
const int _validUntil = 1 << 40;

PtrResourceRecord _ptr(String instance, {int validUntil = _validUntil}) =>
    PtrResourceRecord(
      '$_type.local',
      validUntil,
      domainName: '$instance.$_type.local',
    );

SrvResourceRecord _srv(
  String instance, {
  String target = 'host.local',
  int port = 8080,
  int validUntil = _validUntil,
}) =>
    SrvResourceRecord(
      '$instance.$_type.local',
      validUntil,
      target: target,
      port: port,
      priority: 1,
      weight: 1,
    );

IPAddressResourceRecord _ip(String target, String address) =>
    IPAddressResourceRecord(
      target,
      _validUntil,
      address: InternetAddress(address),
    );

TxtResourceRecord _txt(
  String instance,
  String text, {
  int validUntil = _validUntil,
}) =>
    TxtResourceRecord('$instance.$_type.local', validUntil, text: text);

/// Builds a mock client whose lookups answer with the given streams; lookups
/// without a stream complete empty. Each callback receives the query, so
/// answers can differ per instance or per target host.
MockMDnsClient _clientWith({
  Stream<PtrResourceRecord> Function()? ptr,
  Stream<SrvResourceRecord> Function(ResourceRecordQuery query)? srv,
  Stream<IPAddressResourceRecord> Function(ResourceRecordQuery query)? ip,
  Stream<TxtResourceRecord> Function(ResourceRecordQuery query)? txt,
}) {
  final MockMDnsClient client = MockMDnsClient();
  when(
    () => client.start(
      interfacesFactory: any(named: 'interfacesFactory'),
      onError: any(named: 'onError'),
    ),
  ).thenAnswer((_) async {});
  when(
    () => client.lookup<PtrResourceRecord>(
      any(),
      timeout: any(named: 'timeout'),
    ),
  ).thenAnswer(
    (_) => ptr?.call() ?? const Stream<PtrResourceRecord>.empty(),
  );
  when(
    () => client.lookup<SrvResourceRecord>(
      any(),
      timeout: any(named: 'timeout'),
    ),
  ).thenAnswer(
    (Invocation invocation) =>
        srv?.call(
            invocation.positionalArguments.first as ResourceRecordQuery) ??
        const Stream<SrvResourceRecord>.empty(),
  );
  when(
    () => client.lookup<IPAddressResourceRecord>(
      any(),
      timeout: any(named: 'timeout'),
    ),
  ).thenAnswer(
    (Invocation invocation) =>
        ip?.call(invocation.positionalArguments.first as ResourceRecordQuery) ??
        const Stream<IPAddressResourceRecord>.empty(),
  );
  when(
    () => client.lookup<TxtResourceRecord>(
      any(),
      timeout: any(named: 'timeout'),
    ),
  ).thenAnswer(
    (Invocation invocation) =>
        txt?.call(
            invocation.positionalArguments.first as ResourceRecordQuery) ??
        const Stream<TxtResourceRecord>.empty(),
  );
  return client;
}

/// Creates a bloc that is closed when the test ends, even on failure.
MDnsBloc _bloc(MDnsClient Function() clientFactory) {
  final MDnsBloc bloc = MDnsBloc(clientFactory: clientFactory);
  addTearDown(bloc.close);
  return bloc;
}

/// Collects every state [bloc] emits for the duration of the test.
List<MDnsState> _record(MDnsBloc bloc) {
  final List<MDnsState> states = <MDnsState>[];
  final StreamSubscription<MDnsState> subscription =
      bloc.stream.listen(states.add);
  addTearDown(subscription.cancel);
  return states;
}

/// The first non-`searching` state, bounded so a regression that never
/// completes fails fast instead of hanging until the suite timeout.
Future<MDnsState> _done(MDnsBloc bloc) => bloc.stream
    .firstWhere((MDnsState state) => state.status != MDnsStatus.searching)
    .timeout(const Duration(seconds: 10));

/// Gives pending microtasks and zero-duration timers a chance to run.
Future<void> _pump([int times = 20]) async {
  for (int i = 0; i < times; i += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  setUpAll(() {
    registerFallbackValue(ResourceRecordQuery.serverPointer('$_type.local'));
    registerFallbackValue(Duration.zero);
  });

  group('MDnsBloc', () {
    test('initial state is an empty MDnsState', () async {
      final MDnsBloc bloc = _bloc(MockMDnsClient.new);
      expect(bloc.state, const MDnsState());
    });

    test('emits searching then found with the resolved services', () async {
      final PtrResourceRecord ptr = _ptr('printer');
      final SrvResourceRecord srv = _srv('printer');
      final MockMDnsClient client = _clientWith(
        ptr: () => Stream<PtrResourceRecord>.fromIterable(<PtrResourceRecord>[
          ptr,
        ]),
        srv: (_) => Stream<SrvResourceRecord>.fromIterable(<SrvResourceRecord>[
          srv,
        ]),
        ip: (ResourceRecordQuery query) =>
            Stream<IPAddressResourceRecord>.fromIterable(
          <IPAddressResourceRecord>[
            if (query.resourceRecordType == ResourceRecordType.addressIPv4)
              _ip('host.local', '192.168.1.10')
            else
              _ip('host.local', 'fe80::1'),
          ],
        ),
      );
      final MDnsBloc bloc = _bloc(() => client);
      final List<MDnsState> states = _record(bloc);
      final Future<MDnsState> done = _done(bloc);

      const Duration timeout = Duration(milliseconds: 1234);
      bloc.add(
          const MDnsEventStartSearch(serviceType: _type, timeout: timeout));
      final MDnsState result = await done;

      expect(states.first.status, MDnsStatus.searching);
      expect(result.status, MDnsStatus.found);
      expect(result.discoveredNames, <String>[ptr.domainName]);
      final MDnsService service = result.services.single;
      expect(service.name, ptr.domainName);
      expect(service.host, srv.target);
      expect(service.port, srv.port);
      expect(service.priority, srv.priority);
      expect(service.weight, srv.weight);
      expect(
        service.addresses,
        unorderedEquals(<InternetAddress>[
          InternetAddress('192.168.1.10'),
          InternetAddress('fe80::1'),
        ]),
      );
      expect(result.match, isNull);
      expect(result.error, isNull);
      verify(() => client.stop()).called(1);

      // The PTR query must ask for the event's service type, the SRV query
      // for the PTR's domain name, and the address queries (A and AAAA) for
      // the SRV's target host — all with the event's timeout.
      final List<dynamic> ptrArgs = verify(
        () => client.lookup<PtrResourceRecord>(
          captureAny(),
          timeout: captureAny(named: 'timeout'),
        ),
      ).captured;
      final ResourceRecordQuery ptrQuery = ptrArgs[0] as ResourceRecordQuery;
      expect(ptrQuery.fullyQualifiedName, _type);
      expect(ptrQuery.resourceRecordType, ResourceRecordType.serverPointer);
      expect(ptrArgs[1], timeout);

      final List<dynamic> srvArgs = verify(
        () => client.lookup<SrvResourceRecord>(
          captureAny(),
          timeout: captureAny(named: 'timeout'),
        ),
      ).captured;
      final ResourceRecordQuery srvQuery = srvArgs[0] as ResourceRecordQuery;
      expect(srvQuery.fullyQualifiedName, ptr.domainName);
      expect(srvQuery.resourceRecordType, ResourceRecordType.service);
      expect(srvArgs[1], timeout);

      final List<dynamic> ipArgs = verify(
        () => client.lookup<IPAddressResourceRecord>(
          captureAny(),
          timeout: captureAny(named: 'timeout'),
        ),
      ).captured;
      expect(ipArgs, hasLength(4));
      final ResourceRecordQuery ipQuery1 = ipArgs[0] as ResourceRecordQuery;
      final ResourceRecordQuery ipQuery2 = ipArgs[2] as ResourceRecordQuery;
      expect(ipQuery1.fullyQualifiedName, srv.target);
      expect(ipQuery2.fullyQualifiedName, srv.target);
      expect(
        <int>{ipQuery1.resourceRecordType, ipQuery2.resourceRecordType},
        <int>{
          ResourceRecordType.addressIPv4,
          ResourceRecordType.addressIPv6,
        },
      );
      expect(ipArgs[1], timeout);
      expect(ipArgs[3], timeout);
    });

    test('emits matched when the requested instance is found, ignoring case',
        () async {
      final MockMDnsClient client = _clientWith(
        ptr: () => Stream<PtrResourceRecord>.fromIterable(<PtrResourceRecord>[
          _ptr('printer'),
        ]),
        srv: (_) => Stream<SrvResourceRecord>.fromIterable(<SrvResourceRecord>[
          _srv('printer'),
        ]),
      );
      final MDnsBloc bloc = _bloc(() => client);
      final Future<MDnsState> done = _done(bloc);

      bloc.add(const MDnsEventStartSearch(
        serviceType: _type,
        serviceName: 'PRINTER._HTTP._tcp.local',
      ));
      final MDnsState result = await done;

      expect(result.status, MDnsStatus.matched);
      expect(result.match, result.services.single);
      expect(result.match!.name, 'printer.$_type.local');
    });

    test('emits found, not matched, when the requested instance is absent',
        () async {
      final MockMDnsClient client = _clientWith(
        ptr: () => Stream<PtrResourceRecord>.fromIterable(<PtrResourceRecord>[
          _ptr('printer'),
        ]),
        srv: (_) => Stream<SrvResourceRecord>.fromIterable(<SrvResourceRecord>[
          _srv('printer'),
        ]),
      );
      final MDnsBloc bloc = _bloc(() => client);
      final Future<MDnsState> done = _done(bloc);

      bloc.add(const MDnsEventStartSearch(
        serviceType: _type,
        serviceName: 'absent.$_type.local',
      ));
      final MDnsState result = await done;

      expect(result.status, MDnsStatus.found);
      expect(result.services, hasLength(1));
      expect(result.match, isNull);
    });

    test('keeps a service whose host has no address records', () async {
      final MockMDnsClient client = _clientWith(
        ptr: () => Stream<PtrResourceRecord>.fromIterable(<PtrResourceRecord>[
          _ptr('printer'),
        ]),
        srv: (_) => Stream<SrvResourceRecord>.fromIterable(<SrvResourceRecord>[
          _srv('printer'),
        ]),
      );
      final MDnsBloc bloc = _bloc(() => client);
      final Future<MDnsState> done = _done(bloc);

      bloc.add(const MDnsEventStartSearch(serviceType: _type));
      final MDnsState result = await done;

      expect(result.status, MDnsStatus.found);
      expect(result.services.single.addresses, isEmpty);
    });

    test('resolves services on different hosts to their own addresses',
        () async {
      final MockMDnsClient client = _clientWith(
        ptr: () => Stream<PtrResourceRecord>.fromIterable(<PtrResourceRecord>[
          _ptr('printer'),
          _ptr('scanner'),
        ]),
        srv: (ResourceRecordQuery query) =>
            Stream<SrvResourceRecord>.fromIterable(<SrvResourceRecord>[
          if (query.fullyQualifiedName == 'printer.$_type.local')
            _srv('printer', target: 'hosta.local', port: 8080)
          else if (query.fullyQualifiedName == 'scanner.$_type.local')
            _srv('scanner', target: 'hostb.local', port: 9090),
        ]),
        ip: (ResourceRecordQuery query) =>
            Stream<IPAddressResourceRecord>.fromIterable(
          <IPAddressResourceRecord>[
            if (query.resourceRecordType == ResourceRecordType.addressIPv4 &&
                query.fullyQualifiedName == 'hosta.local')
              _ip('hosta.local', '192.168.1.10'),
            if (query.resourceRecordType == ResourceRecordType.addressIPv4 &&
                query.fullyQualifiedName == 'hostb.local')
              _ip('hostb.local', '192.168.1.20'),
          ],
        ),
      );
      final MDnsBloc bloc = _bloc(() => client);
      final Future<MDnsState> done = _done(bloc);

      bloc.add(const MDnsEventStartSearch(serviceType: _type));
      final MDnsState result = await done;

      expect(result.status, MDnsStatus.found);
      expect(result.services, hasLength(2));
      final MDnsService printer = result.services
          .singleWhere((MDnsService s) => s.name.startsWith('printer'));
      final MDnsService scanner = result.services
          .singleWhere((MDnsService s) => s.name.startsWith('scanner'));
      expect(printer.host, 'hosta.local');
      expect(printer.port, 8080);
      expect(printer.addresses, <InternetAddress>[
        InternetAddress('192.168.1.10'),
      ]);
      expect(scanner.host, 'hostb.local');
      expect(scanner.port, 9090);
      expect(scanner.addresses, <InternetAddress>[
        InternetAddress('192.168.1.20'),
      ]);
    });

    test('retries when nothing is found and ends with noneFound', () async {
      final MockMDnsClient client = _clientWith();
      final MDnsBloc bloc = _bloc(() => client);
      final Future<MDnsState> done = _done(bloc);

      bloc.add(const MDnsEventStartSearch(serviceType: _type, retries: 2));
      final MDnsState result = await done;

      expect(result.status, MDnsStatus.noneFound);
      expect(result.discoveredNames, isEmpty);
      verify(
        () => client.lookup<PtrResourceRecord>(
          any(),
          timeout: any(named: 'timeout'),
        ),
      ).called(3);
    });

    test('re-resolves a known instance on retry and succeeds', () async {
      // Attempt 1 announces the PTR but its SRV does not resolve; attempt 2
      // must resolve the same instance again rather than skipping it as
      // already known.
      int srvCalls = 0;
      final MockMDnsClient client = _clientWith(
        ptr: () => Stream<PtrResourceRecord>.fromIterable(<PtrResourceRecord>[
          _ptr('printer'),
        ]),
        srv: (_) {
          srvCalls += 1;
          return srvCalls == 1
              ? const Stream<SrvResourceRecord>.empty()
              : Stream<SrvResourceRecord>.fromIterable(<SrvResourceRecord>[
                  _srv('printer'),
                ]);
        },
      );
      final MDnsBloc bloc = _bloc(() => client);
      final Future<MDnsState> done = _done(bloc);

      bloc.add(const MDnsEventStartSearch(serviceType: _type, retries: 3));
      final MDnsState result = await done;

      expect(result.status, MDnsStatus.found);
      expect(result.services, hasLength(1));
      // The instance was announced twice but discovered once.
      expect(result.discoveredNames, <String>['printer.$_type.local']);
      // The search stopped after the successful attempt instead of
      // exhausting the remaining retries.
      verify(
        () => client.lookup<PtrResourceRecord>(
          any(),
          timeout: any(named: 'timeout'),
        ),
      ).called(2);
    });

    test('deduplicates repeated PTR, SRV and address announcements', () async {
      final MockMDnsClient client = _clientWith(
        ptr: () => Stream<PtrResourceRecord>.fromIterable(<PtrResourceRecord>[
          _ptr('printer'),
          _ptr('printer', validUntil: _validUntil + 1),
          // A differently-cased announcement of the same instance.
          _ptr('Printer'),
        ]),
        srv: (_) => Stream<SrvResourceRecord>.fromIterable(<SrvResourceRecord>[
          _srv('printer'),
          _srv('printer', validUntil: _validUntil + 1),
        ]),
        ip: (ResourceRecordQuery query) =>
            query.resourceRecordType == ResourceRecordType.addressIPv4
                ? Stream<IPAddressResourceRecord>.fromIterable(
                    <IPAddressResourceRecord>[
                      _ip('host.local', '192.168.1.10'),
                      _ip('host.local', '192.168.1.10'),
                    ],
                  )
                : const Stream<IPAddressResourceRecord>.empty(),
      );
      final MDnsBloc bloc = _bloc(() => client);
      final Future<MDnsState> done = _done(bloc);

      bloc.add(const MDnsEventStartSearch(serviceType: _type));
      final MDnsState result = await done;

      expect(result.discoveredNames, <String>['printer.$_type.local']);
      final MDnsService service = result.services.single;
      expect(service.addresses, <InternetAddress>[
        InternetAddress('192.168.1.10'),
      ]);
      verify(
        () => client.lookup<SrvResourceRecord>(
          any(),
          timeout: any(named: 'timeout'),
        ),
      ).called(1);
    });

    test('splits and deduplicates TXT attributes across records', () async {
      // The PTR announces a differently-cased instance name; the TXT data
      // must still attach to the same instance.
      final MockMDnsClient client = _clientWith(
        ptr: () => Stream<PtrResourceRecord>.fromIterable(<PtrResourceRecord>[
          _ptr('Printer'),
        ]),
        srv: (_) => Stream<SrvResourceRecord>.fromIterable(<SrvResourceRecord>[
          _srv('printer'),
        ]),
        txt: (_) => Stream<TxtResourceRecord>.fromIterable(<TxtResourceRecord>[
          _txt('printer', 'path=/index.html\nversion=2'),
          _txt('printer', 'path=/index.html', validUntil: _validUntil + 1),
        ]),
      );
      final MDnsBloc bloc = _bloc(() => client);
      final Future<MDnsState> done = _done(bloc);

      bloc.add(const MDnsEventStartSearch(serviceType: _type));
      final MDnsState result = await done;

      expect(result.status, MDnsStatus.found);
      final MDnsService service = result.services.single;
      expect(service.txt, <String>['path=/index.html', 'version=2']);
      expect(service.txtAttributes, <String, String?>{
        'path': '/index.html',
        'version': '2',
      });
    });

    test('emits progressive snapshots while the search resolves', () async {
      // Broadcast controllers: a second PTR triggers additional SRV/TXT
      // lookup calls, which listen to these same streams again.
      final StreamController<PtrResourceRecord> ptrController =
          StreamController<PtrResourceRecord>.broadcast();
      final StreamController<SrvResourceRecord> srvController =
          StreamController<SrvResourceRecord>.broadcast();
      final StreamController<TxtResourceRecord> txtController =
          StreamController<TxtResourceRecord>.broadcast();
      final StreamController<IPAddressResourceRecord> ipController =
          StreamController<IPAddressResourceRecord>.broadcast();
      final MockMDnsClient client = _clientWith(
        ptr: () => ptrController.stream,
        srv: (_) => srvController.stream,
        txt: (_) => txtController.stream,
        ip: (ResourceRecordQuery query) =>
            query.resourceRecordType == ResourceRecordType.addressIPv4
                ? ipController.stream
                : const Stream<IPAddressResourceRecord>.empty(),
      );
      final MDnsBloc bloc = _bloc(() => client);
      final List<MDnsState> states = _record(bloc);

      bloc.add(const MDnsEventStartSearch(serviceType: _type, retries: 0));
      await _pump();
      expect(states.last, const MDnsState(status: MDnsStatus.searching));

      final PtrResourceRecord ptr = _ptr('printer');
      ptrController.add(ptr);
      await _pump();
      expect(states.last.status, MDnsStatus.searching);
      expect(states.last.discoveredNames, <String>[ptr.domainName]);
      expect(states.last.services, isEmpty);
      final MDnsState ptrSnapshot = states.last;

      srvController.add(_srv('printer'));
      await _pump();
      expect(states.last.status, MDnsStatus.searching);
      expect(states.last.services.single.addresses, isEmpty);
      final MDnsState srvSnapshot = states.last;

      txtController.add(_txt('printer', 'path=/'));
      await _pump();
      expect(states.last.services.single.txt, <String>['path=/']);

      ipController.add(_ip('host.local', '192.168.1.10'));
      await _pump();
      expect(states.last.services.single.addresses, <InternetAddress>[
        InternetAddress('192.168.1.10'),
      ]);

      ptrController.add(_ptr('scanner'));
      await _pump();
      expect(states.last.discoveredNames, hasLength(2));

      // Earlier snapshots must not be mutated by later discoveries.
      expect(ptrSnapshot.discoveredNames, hasLength(1));
      expect(ptrSnapshot.services, isEmpty);
      expect(srvSnapshot.services.single.addresses, isEmpty);
      expect(srvSnapshot.services.single.txt, isEmpty);

      final Future<MDnsState> done = _done(bloc);
      await ptrController.close();
      await srvController.close();
      await txtController.close();
      await ipController.close();
      final MDnsState result = await done;

      expect(result.status, MDnsStatus.found);
      final MDnsService service = result.services.single;
      expect(service.addresses, <InternetAddress>[
        InternetAddress('192.168.1.10'),
      ]);
      expect(service.txt, <String>['path=/']);
      expect(result.discoveredNames, hasLength(2));
    });

    test('a stopped search retains the services discovered so far', () async {
      final StreamController<PtrResourceRecord> ptrController =
          StreamController<PtrResourceRecord>();
      final StreamController<SrvResourceRecord> srvController =
          StreamController<SrvResourceRecord>();
      final StreamController<TxtResourceRecord> txtController =
          StreamController<TxtResourceRecord>();
      final MockMDnsClient client = _clientWith(
        ptr: () => ptrController.stream,
        srv: (_) => srvController.stream,
        txt: (_) => txtController.stream,
      );
      final MDnsBloc bloc = _bloc(() => client);
      final List<MDnsState> states = _record(bloc);

      bloc.add(const MDnsEventStartSearch(serviceType: _type));
      await _pump();
      final PtrResourceRecord ptr = _ptr('printer');
      ptrController.add(ptr);
      await _pump();
      srvController.add(_srv('printer'));
      txtController.add(_txt('printer', 'path=/'));
      await _pump();
      expect(states.last.discoveredNames, <String>[ptr.domainName]);
      expect(states.last.services, hasLength(1));

      bloc.add(const MDnsEventStopSearch());
      await _pump();
      expect(states.last.status, MDnsStatus.stopped);
      expect(states.last.discoveredNames, <String>[ptr.domainName]);
      final MDnsService service = states.last.services.single;
      expect(service.name, ptr.domainName);
      expect(service.txt, <String>['path=/']);

      await ptrController.close();
      await srvController.close();
      await txtController.close();
      await _pump();
      expect(states.last.status, MDnsStatus.stopped);
    });

    test('ends noneFound when announced instances never resolve an SRV',
        () async {
      final PtrResourceRecord ptr = _ptr('printer');
      final MockMDnsClient client = _clientWith(
        ptr: () => Stream<PtrResourceRecord>.fromIterable(<PtrResourceRecord>[
          ptr,
        ]),
        txt: (_) => Stream<TxtResourceRecord>.fromIterable(<TxtResourceRecord>[
          _txt('printer', 'path=/index.html'),
        ]),
      );
      final MDnsBloc bloc = _bloc(() => client);
      final Future<MDnsState> done = _done(bloc);

      bloc.add(const MDnsEventStartSearch(serviceType: _type, retries: 0));
      final MDnsState result = await done;

      expect(result.status, MDnsStatus.noneFound);
      expect(result.services, isEmpty);
      expect(result.discoveredNames, <String>[ptr.domainName]);
    });

    test('emits error when the client fails to start', () async {
      final MockMDnsClient client = MockMDnsClient();
      when(
        () => client.start(
          interfacesFactory: any(named: 'interfacesFactory'),
          onError: any(named: 'onError'),
        ),
      ).thenThrow(const SocketException('no network'));
      // Defensive: the real MDnsClient's stop() silently returns after a
      // failed start, but the bloc must also tolerate a custom client
      // implementation whose stop() throws.
      when(() => client.stop()).thenThrow(
        StateError('Cannot stop mDNS client while it is starting.'),
      );
      final MDnsBloc bloc = _bloc(() => client);
      final Future<MDnsState> done = _done(bloc);

      bloc.add(const MDnsEventStartSearch(serviceType: _type));
      final MDnsState result = await done;

      expect(result.status, MDnsStatus.error);
      expect(result.error, isA<SocketException>());
      expect(result.errorMessage, contains('no network'));
      expect(result.stackTrace, isNotNull);
    });

    test('a failing PTR stream ends the search with its partial results',
        () async {
      final StreamController<PtrResourceRecord> ptrController =
          StreamController<PtrResourceRecord>();
      final StreamController<SrvResourceRecord> srvController =
          StreamController<SrvResourceRecord>();
      addTearDown(srvController.close);
      final MockMDnsClient client = _clientWith(
        ptr: () => ptrController.stream,
        srv: (_) => srvController.stream,
      );
      final MDnsBloc bloc = _bloc(() => client);
      final Future<MDnsState> done = _done(bloc);

      bloc.add(const MDnsEventStartSearch(serviceType: _type));
      await _pump();
      final PtrResourceRecord ptr = _ptr('printer');
      ptrController.add(ptr);
      await _pump();
      ptrController.addError(const SocketException('interface down'));
      await ptrController.close();
      final MDnsState result = await done;

      expect(result.status, MDnsStatus.error);
      expect(result.error, isA<SocketException>());
      expect(result.errorMessage, contains('interface down'));
      // The records discovered before the failure are retained.
      expect(result.discoveredNames, <String>[ptr.domainName]);
    });

    test(
        'a nested lookup failing while the PTR stream is open surfaces as an '
        'error state, not an unhandled zone error', () async {
      // The SRV lookup fails long before the PTR stream closes — the window
      // in which the resolution future has no listener yet. The failure must
      // be contained and reported through the state.
      final StreamController<PtrResourceRecord> ptrController =
          StreamController<PtrResourceRecord>();
      final MockMDnsClient client = _clientWith(
        ptr: () => ptrController.stream,
        srv: (_) => Stream<SrvResourceRecord>.error(
          const SocketException('srv lookup failed'),
        ),
      );
      final MDnsBloc bloc = _bloc(() => client);
      final Future<MDnsState> done = _done(bloc);

      bloc.add(const MDnsEventStartSearch(serviceType: _type, retries: 3));
      await _pump();
      final PtrResourceRecord ptr = _ptr('printer');
      ptrController.add(ptr);
      // The failure happens now, while the PTR stream is still open; give it
      // time to become an unhandled error if it is going to.
      await _pump();
      await ptrController.close();
      final MDnsState result = await done;

      expect(result.status, MDnsStatus.error);
      expect(result.error, isA<SocketException>());
      expect(result.errorMessage, contains('srv lookup failed'));
      expect(result.discoveredNames, <String>[ptr.domainName]);
      // The failed search must not burn the remaining retries.
      verify(
        () => client.lookup<PtrResourceRecord>(
          any(),
          timeout: any(named: 'timeout'),
        ),
      ).called(1);
    });

    test(
        'an error reported by the receive socket ends the search with an '
        'error state', () async {
      final StreamController<PtrResourceRecord> ptrController =
          StreamController<PtrResourceRecord>();
      final MockMDnsClient client =
          _clientWith(ptr: () => ptrController.stream);
      final MDnsBloc bloc = _bloc(() => client);
      final Future<MDnsState> done = _done(bloc);

      bloc.add(const MDnsEventStartSearch(serviceType: _type));
      await _pump();

      // The bloc must wire an onError into client.start(); invoke it the way
      // the client's incoming-socket subscription would.
      final Function onError = verify(
        () => client.start(
          interfacesFactory: any(named: 'interfacesFactory'),
          onError: captureAny(named: 'onError'),
        ),
      ).captured.single as Function;
      onError(const SocketException('socket died'), StackTrace.current);
      await _pump();
      // The client is stopped as soon as the error arrives, so pending
      // lookups unwind; the real client ends its lookup streams when
      // stopped — emulate that.
      verify(() => client.stop()).called(greaterThanOrEqualTo(1));
      await ptrController.close();
      final MDnsState result = await done;

      expect(result.status, MDnsStatus.error);
      expect(result.error, isA<SocketException>());
      expect(result.errorMessage, contains('socket died'));
    });

    test('MDnsEventStopSearch cancels the search in flight', () async {
      final StreamController<PtrResourceRecord> ptrController =
          StreamController<PtrResourceRecord>();
      final MockMDnsClient client =
          _clientWith(ptr: () => ptrController.stream);
      final MDnsBloc bloc = _bloc(() => client);
      final List<MDnsState> states = _record(bloc);

      bloc.add(const MDnsEventStartSearch(serviceType: _type));
      await _pump();
      expect(states.last.status, MDnsStatus.searching);

      bloc.add(const MDnsEventStopSearch());
      await _pump();
      expect(states.last.status, MDnsStatus.stopped);
      verify(() => client.stop()).called(1);

      // The real client ends its lookup streams when stopped; emulate that
      // and check the cancelled search emits nothing further.
      await ptrController.close();
      await _pump();
      expect(
        states.map((MDnsState state) => state.status),
        <MDnsStatus>[MDnsStatus.searching, MDnsStatus.stopped],
      );
    });

    test('a stopped search can be followed by a successful new search',
        () async {
      final StreamController<PtrResourceRecord> hanging =
          StreamController<PtrResourceRecord>();
      final MockMDnsClient first = _clientWith(ptr: () => hanging.stream);
      final MockMDnsClient second = _clientWith(
        ptr: () => Stream<PtrResourceRecord>.fromIterable(<PtrResourceRecord>[
          _ptr('printer'),
        ]),
        srv: (_) => Stream<SrvResourceRecord>.fromIterable(<SrvResourceRecord>[
          _srv('printer'),
        ]),
      );
      final List<MockMDnsClient> clients = <MockMDnsClient>[first, second];
      final MDnsBloc bloc = _bloc(() => clients.removeAt(0));
      final List<MDnsState> states = _record(bloc);

      bloc.add(const MDnsEventStartSearch(serviceType: _type));
      await _pump();
      bloc.add(const MDnsEventStopSearch());
      await _pump();
      expect(states.last.status, MDnsStatus.stopped);
      verify(() => first.stop()).called(1);

      final Future<MDnsState> done = bloc.stream
          .firstWhere(
            (MDnsState state) =>
                state.status != MDnsStatus.searching &&
                state.status != MDnsStatus.stopped,
          )
          .timeout(const Duration(seconds: 10));
      bloc.add(const MDnsEventStartSearch(serviceType: _type));
      final MDnsState result = await done;

      expect(result.status, MDnsStatus.found);
      expect(result.services.single.name, 'printer.$_type.local');

      // Unwind the stopped search and check it emits nothing further.
      await hanging.close();
      await _pump();
      expect(states.last, result);
    });

    test('a new search starts from a clean slate', () async {
      // Search 1 fails after discovering an instance; search 2 must not leak
      // its records or its error into the new search's states.
      final MockMDnsClient first = _clientWith(
        ptr: () => Stream<PtrResourceRecord>.fromIterable(<PtrResourceRecord>[
          _ptr('printer'),
        ]),
        srv: (_) => Stream<SrvResourceRecord>.error(
          const SocketException('boom'),
        ),
      );
      final MockMDnsClient second = _clientWith(
        ptr: () => Stream<PtrResourceRecord>.fromIterable(<PtrResourceRecord>[
          _ptr('scanner'),
        ]),
        srv: (_) => Stream<SrvResourceRecord>.fromIterable(<SrvResourceRecord>[
          _srv('scanner', target: 'hostb.local'),
        ]),
      );
      final List<MockMDnsClient> clients = <MockMDnsClient>[first, second];
      final MDnsBloc bloc = _bloc(() => clients.removeAt(0));
      final List<MDnsState> states = _record(bloc);

      bloc.add(const MDnsEventStartSearch(serviceType: _type, retries: 0));
      final MDnsState failed = await _done(bloc);
      expect(failed.status, MDnsStatus.error);
      expect(failed.discoveredNames, hasLength(1));

      final int statesBefore = states.length;
      final Future<MDnsState> done = bloc.stream
          .firstWhere(
            (MDnsState state) =>
                state.status != MDnsStatus.searching &&
                state.status != MDnsStatus.error,
          )
          .timeout(const Duration(seconds: 10));
      bloc.add(const MDnsEventStartSearch(serviceType: _type, retries: 0));
      final MDnsState result = await done;

      // The first state of the new search carries nothing over.
      expect(
        states[statesBefore],
        const MDnsState(status: MDnsStatus.searching),
      );
      expect(result.status, MDnsStatus.found);
      expect(result.services.single.name, 'scanner.$_type.local');
      expect(result.discoveredNames, <String>['scanner.$_type.local']);
      expect(result.error, isNull);
    });

    test('swallows StateErrors from lookups unwinding after a stop', () async {
      // A stopped client's pending lookups end and later lookup() calls
      // throw StateError ('mDNS client must be started before calling
      // lookup.'); once the search is cancelled those must stay silent.
      final StreamController<PtrResourceRecord> ptrController =
          StreamController<PtrResourceRecord>();
      final StreamController<SrvResourceRecord> srvController =
          StreamController<SrvResourceRecord>();
      final MockMDnsClient client = _clientWith(
        ptr: () => ptrController.stream,
        srv: (_) => srvController.stream,
      );
      final MDnsBloc bloc = _bloc(() => client);
      final List<MDnsState> states = _record(bloc);

      bloc.add(const MDnsEventStartSearch(serviceType: _type));
      await _pump();
      ptrController.add(_ptr('printer'));
      await _pump();
      bloc.add(const MDnsEventStopSearch());
      await _pump();
      expect(states.last.status, MDnsStatus.stopped);

      // The real client errors the streams of lookups that were in flight
      // when it stopped; emulate that and check nothing further is emitted.
      srvController.addError(
        StateError('mDNS client must be started before calling lookup.'),
      );
      await srvController.close();
      await ptrController.close();
      await _pump();
      expect(states.last.status, MDnsStatus.stopped);
    });

    test('surfaces a StateError from a live search as an error state',
        () async {
      // A StateError while the search is live and unfailed cannot mean 'the
      // client was stopped' — it is a defect (e.g. in a custom clientFactory
      // client) and must not be silently masked as noneFound.
      final MockMDnsClient client = _clientWith(
        ptr: () => Stream<PtrResourceRecord>.fromIterable(<PtrResourceRecord>[
          _ptr('printer'),
        ]),
      );
      when(
        () => client.lookup<SrvResourceRecord>(
          any(),
          timeout: any(named: 'timeout'),
        ),
      ).thenThrow(StateError('defective custom client'));
      final MDnsBloc bloc = _bloc(() => client);
      final Future<MDnsState> done = _done(bloc);

      bloc.add(const MDnsEventStartSearch(serviceType: _type, retries: 3));
      final MDnsState result = await done;

      expect(result.status, MDnsStatus.error);
      expect(result.error, isA<StateError>());
      expect(result.errorMessage, contains('defective custom client'));
      expect(result.discoveredNames, hasLength(1));
    });

    test('forwards interfacesFactory to client.start()', () async {
      final MockMDnsClient client = _clientWith();
      Future<Iterable<NetworkInterface>> interfaces(
        InternetAddressType type,
      ) async =>
          const <NetworkInterface>[];
      final MDnsBloc bloc = MDnsBloc(
        clientFactory: () => client,
        interfacesFactory: interfaces,
      );
      addTearDown(bloc.close);
      final Future<MDnsState> done = _done(bloc);

      bloc.add(const MDnsEventStartSearch(serviceType: _type, retries: 0));
      await done;

      final List<dynamic> captured = verify(
        () => client.start(
          interfacesFactory: captureAny(named: 'interfacesFactory'),
          onError: any(named: 'onError'),
        ),
      ).captured;
      expect(identical(captured.single, interfaces), isTrue);
    });

    test('MDnsEventStopSearch is a no-op when nothing is running', () async {
      final MDnsBloc bloc = _bloc(MockMDnsClient.new);
      bloc.add(const MDnsEventStopSearch());
      await _pump();
      expect(bloc.state, const MDnsState());
    });

    test('a new search supersedes the one in flight', () async {
      final StreamController<PtrResourceRecord> hanging =
          StreamController<PtrResourceRecord>();
      final MockMDnsClient first = _clientWith(ptr: () => hanging.stream);
      final MockMDnsClient second = _clientWith(
        ptr: () => Stream<PtrResourceRecord>.fromIterable(<PtrResourceRecord>[
          _ptr('printer'),
        ]),
        srv: (_) => Stream<SrvResourceRecord>.fromIterable(<SrvResourceRecord>[
          _srv('printer'),
        ]),
      );
      final List<MockMDnsClient> clients = <MockMDnsClient>[first, second];
      final MDnsBloc bloc = _bloc(() => clients.removeAt(0));
      final List<MDnsState> states = _record(bloc);

      bloc.add(const MDnsEventStartSearch(serviceType: _type));
      await _pump();
      expect(states.last.status, MDnsStatus.searching);

      final Future<MDnsState> done = _done(bloc);
      bloc.add(const MDnsEventStartSearch(serviceType: _type));
      final MDnsState result = await done;

      expect(result.status, MDnsStatus.found);
      expect(result.services.single.name, 'printer.$_type.local');
      verify(() => first.stop()).called(1);

      // Unwind the superseded search and check it emits nothing further.
      await hanging.close();
      await _pump();
      expect(states.last, result);
    });

    test('close() stops the client of a search in flight', () async {
      final StreamController<PtrResourceRecord> hanging =
          StreamController<PtrResourceRecord>();
      final MockMDnsClient client = _clientWith(ptr: () => hanging.stream);
      final MDnsBloc bloc = MDnsBloc(clientFactory: () => client);

      bloc.add(const MDnsEventStartSearch(serviceType: _type));
      await _pump();

      final Future<void> closing = bloc.close();
      await _pump();
      verify(() => client.stop()).called(1);

      await hanging.close();
      await closing;
    });

    test(
        'the default client reclaims its bound sockets when start() fails '
        'partway', () async {
      // The real MDnsClient.start() does not clean up after itself when it
      // fails after binding its sockets (e.g. enumerating interfaces or
      // joining multicast throws on a VPN interface), and its stop() is a
      // no-op on a client that never finished starting. The bloc tracks the
      // sockets its default factory bound and must close them itself.
      final MockRawDatagramSocket socket = MockRawDatagramSocket();
      when(() => socket.address).thenReturn(InternetAddress.anyIPv4);

      final MDnsBloc bloc = MDnsBloc(
        // start() awaits the interfaces only after binding the incoming
        // socket, so this fails the start with the socket already bound.
        interfacesFactory: (InternetAddressType type) async =>
            throw const SocketException('interfaces unavailable'),
        socketFactory: (
          dynamic host,
          int port, {
          bool reuseAddress = true,
          bool reusePort = false,
          int ttl = 1,
        }) async =>
            socket,
      );
      addTearDown(bloc.close);
      final Future<MDnsState> done = _done(bloc);

      bloc.add(const MDnsEventStartSearch(serviceType: _type));
      final MDnsState result = await done;

      expect(result.status, MDnsStatus.error);
      expect(result.error, isA<SocketException>());
      expect(result.errorMessage, contains('interfaces unavailable'));
      // The socket bound by the failed start() must have been reclaimed.
      verify(() => socket.close()).called(1);
    });
  });
}
