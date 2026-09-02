import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mdns_bloc/mdns_bloc.dart';
import 'package:mocktail/mocktail.dart';
import 'package:multicast_dns/multicast_dns.dart';

class MockMDnsClient extends Mock implements MDnsClient {}

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
/// without a stream complete empty.
MockMDnsClient _clientWith({
  Stream<PtrResourceRecord> Function()? ptr,
  Stream<SrvResourceRecord> Function()? srv,
  Stream<IPAddressResourceRecord> Function(ResourceRecordQuery query)? ip,
  Stream<TxtResourceRecord> Function()? txt,
}) {
  final MockMDnsClient client = MockMDnsClient();
  when(() => client.start()).thenAnswer((_) async {});
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
    (_) => srv?.call() ?? const Stream<SrvResourceRecord>.empty(),
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
    (_) => txt?.call() ?? const Stream<TxtResourceRecord>.empty(),
  );
  return client;
}

void main() {
  setUpAll(() {
    registerFallbackValue(ResourceRecordQuery.serverPointer('$_type.local'));
    registerFallbackValue(Duration.zero);
  });

  group('MDnsBloc', () {
    test('initial state is an empty MDnsState', () async {
      final MDnsBloc bloc = MDnsBloc(clientFactory: MockMDnsClient.new);
      expect(bloc.state, const MDnsState());
      await bloc.close();
    });

    test('emits searching then mDnsFound with the resolved services', () async {
      final PtrResourceRecord ptr = _ptr('printer');
      final SrvResourceRecord srv = _srv('printer');
      final IPAddressResourceRecord v4 = _ip('host.local', '192.168.1.10');
      final IPAddressResourceRecord v6 = _ip('host.local', 'fe80::1');
      final MockMDnsClient client = _clientWith(
        ptr: () => Stream<PtrResourceRecord>.fromIterable(<PtrResourceRecord>[
          ptr,
        ]),
        srv: () => Stream<SrvResourceRecord>.fromIterable(<SrvResourceRecord>[
          srv,
        ]),
        ip: (ResourceRecordQuery query) =>
            Stream<IPAddressResourceRecord>.fromIterable(
          <IPAddressResourceRecord>[
            if (query.resourceRecordType == ResourceRecordType.addressIPv4)
              v4
            else
              v6,
          ],
        ),
      );
      final MDnsBloc bloc = MDnsBloc(clientFactory: () => client);
      final List<MDnsState> states = <MDnsState>[];
      final StreamSubscription<MDnsState> subscription =
          bloc.stream.listen(states.add);
      final Future<MDnsState> done = bloc.stream.firstWhere(
        (MDnsState state) => state.status != MDnsStatus.searching,
      );

      const Duration timeout = Duration(milliseconds: 1234);
      bloc.add(
          const MDnsEventStartSearch(serverPointer: _type, timeout: timeout));
      final MDnsState result = await done;

      expect(states.first.status, MDnsStatus.searching);
      expect(result.status, MDnsStatus.mDnsFound);
      expect(result.dnsPtrRecords, <PtrResourceRecord>[ptr]);
      expect(result.dnsSrvRecords.keys.single, srv);
      expect(
        result.dnsSrvRecords[srv],
        unorderedEquals(<IPAddressResourceRecord>[v4, v6]),
      );
      expect(result.service, isNull);
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

      await subscription.cancel();
      await bloc.close();
    });

    test('emits mDnsMatch when the requested instance is found, ignoring case',
        () async {
      final SrvResourceRecord srv = _srv('printer');
      final MockMDnsClient client = _clientWith(
        ptr: () => Stream<PtrResourceRecord>.fromIterable(<PtrResourceRecord>[
          _ptr('printer'),
        ]),
        srv: () => Stream<SrvResourceRecord>.fromIterable(<SrvResourceRecord>[
          srv,
        ]),
      );
      final MDnsBloc bloc = MDnsBloc(clientFactory: () => client);
      final Future<MDnsState> done = bloc.stream.firstWhere(
        (MDnsState state) => state.status != MDnsStatus.searching,
      );

      bloc.add(const MDnsEventStartSearch(
        serverPointer: _type,
        service: 'PRINTER._HTTP._tcp.local',
      ));
      final MDnsState result = await done;

      expect(result.status, MDnsStatus.mDnsMatch);
      expect(result.service, srv);

      await bloc.close();
    });

    test('keeps a service whose host has no address records', () async {
      final SrvResourceRecord srv = _srv('printer');
      final MockMDnsClient client = _clientWith(
        ptr: () => Stream<PtrResourceRecord>.fromIterable(<PtrResourceRecord>[
          _ptr('printer'),
        ]),
        srv: () => Stream<SrvResourceRecord>.fromIterable(<SrvResourceRecord>[
          srv,
        ]),
      );
      final MDnsBloc bloc = MDnsBloc(clientFactory: () => client);
      final Future<MDnsState> done = bloc.stream.firstWhere(
        (MDnsState state) => state.status != MDnsStatus.searching,
      );

      bloc.add(const MDnsEventStartSearch(serverPointer: _type));
      final MDnsState result = await done;

      expect(result.status, MDnsStatus.mDnsFound);
      expect(result.dnsSrvRecords[srv], isEmpty);

      await bloc.close();
    });

    test('retries when nothing is found and ends with mDnsScanned', () async {
      final MockMDnsClient client = _clientWith();
      final MDnsBloc bloc = MDnsBloc(clientFactory: () => client);
      final Future<MDnsState> done = bloc.stream.firstWhere(
        (MDnsState state) => state.status != MDnsStatus.searching,
      );

      bloc.add(const MDnsEventStartSearch(serverPointer: _type, retries: 2));
      final MDnsState result = await done;

      expect(result.status, MDnsStatus.mDnsScanned);
      expect(result.dnsPtrRecords, isEmpty);
      verify(
        () => client.lookup<PtrResourceRecord>(
          any(),
          timeout: any(named: 'timeout'),
        ),
      ).called(3);

      await bloc.close();
    });

    test('deduplicates repeated PTR, SRV and address announcements', () async {
      final SrvResourceRecord srv = _srv('printer');
      final IPAddressResourceRecord v4 = _ip('host.local', '192.168.1.10');
      final MockMDnsClient client = _clientWith(
        ptr: () => Stream<PtrResourceRecord>.fromIterable(<PtrResourceRecord>[
          _ptr('printer'),
          _ptr('printer', validUntil: _validUntil + 1),
        ]),
        srv: () => Stream<SrvResourceRecord>.fromIterable(<SrvResourceRecord>[
          srv,
          _srv('printer', validUntil: _validUntil + 1),
        ]),
        ip: (ResourceRecordQuery query) =>
            query.resourceRecordType == ResourceRecordType.addressIPv4
                ? Stream<IPAddressResourceRecord>.fromIterable(
                    <IPAddressResourceRecord>[
                      v4,
                      _ip('host.local', '192.168.1.10'),
                    ],
                  )
                : const Stream<IPAddressResourceRecord>.empty(),
      );
      final MDnsBloc bloc = MDnsBloc(clientFactory: () => client);
      final Future<MDnsState> done = bloc.stream.firstWhere(
        (MDnsState state) => state.status != MDnsStatus.searching,
      );

      bloc.add(const MDnsEventStartSearch(serverPointer: _type));
      final MDnsState result = await done;

      expect(result.dnsPtrRecords, hasLength(1));
      expect(result.dnsSrvRecords.keys.single, srv);
      expect(result.dnsSrvRecords[srv], <IPAddressResourceRecord>[v4]);
      verify(
        () => client.lookup<SrvResourceRecord>(
          any(),
          timeout: any(named: 'timeout'),
        ),
      ).called(1);

      await bloc.close();
    });

    test('resolves TXT records keyed by lowercased instance name, deduplicated',
        () async {
      final SrvResourceRecord srv = _srv('printer');
      // The PTR announces a differently-cased instance name; the TXT map key
      // must still line up with srv.name via lowercasing.
      final PtrResourceRecord ptr = _ptr('Printer');
      final MockMDnsClient client = _clientWith(
        ptr: () => Stream<PtrResourceRecord>.fromIterable(<PtrResourceRecord>[
          ptr,
        ]),
        srv: () => Stream<SrvResourceRecord>.fromIterable(<SrvResourceRecord>[
          srv,
        ]),
        txt: () => Stream<TxtResourceRecord>.fromIterable(<TxtResourceRecord>[
          _txt('printer', 'path=/index.html'),
          _txt('printer', 'path=/index.html', validUntil: _validUntil + 1),
          _txt('printer', 'version=2'),
        ]),
      );
      final MDnsBloc bloc = MDnsBloc(clientFactory: () => client);
      final Future<MDnsState> done = bloc.stream.firstWhere(
        (MDnsState state) => state.status != MDnsStatus.searching,
      );

      const Duration timeout = Duration(milliseconds: 1234);
      bloc.add(
          const MDnsEventStartSearch(serverPointer: _type, timeout: timeout));
      final MDnsState result = await done;

      expect(result.status, MDnsStatus.mDnsFound);
      expect(result.dnsTxtRecords.keys.single, srv.name.toLowerCase());
      expect(
        result.dnsTxtRecords[srv.name.toLowerCase()]!
            .map((TxtResourceRecord record) => record.text),
        <String>['path=/index.html', 'version=2'],
      );

      // The TXT query must ask for the PTR's domain name (original case)
      // with the event's timeout.
      final List<dynamic> txtArgs = verify(
        () => client.lookup<TxtResourceRecord>(
          captureAny(),
          timeout: captureAny(named: 'timeout'),
        ),
      ).captured;
      final ResourceRecordQuery txtQuery = txtArgs[0] as ResourceRecordQuery;
      expect(txtQuery.fullyQualifiedName, ptr.domainName);
      expect(txtQuery.resourceRecordType, ResourceRecordType.text);
      expect(txtArgs[1], timeout);

      await bloc.close();
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
        srv: () => srvController.stream,
        txt: () => txtController.stream,
        ip: (ResourceRecordQuery query) =>
            query.resourceRecordType == ResourceRecordType.addressIPv4
                ? ipController.stream
                : const Stream<IPAddressResourceRecord>.empty(),
      );
      final MDnsBloc bloc = MDnsBloc(clientFactory: () => client);
      final List<MDnsState> states = <MDnsState>[];
      final StreamSubscription<MDnsState> subscription =
          bloc.stream.listen(states.add);

      bloc.add(const MDnsEventStartSearch(serverPointer: _type, retries: 0));
      await pumpEventQueue();
      expect(states.last, const MDnsState(status: MDnsStatus.searching));

      final PtrResourceRecord ptr = _ptr('printer');
      ptrController.add(ptr);
      await pumpEventQueue();
      expect(states.last.status, MDnsStatus.searching);
      expect(states.last.dnsPtrRecords, <PtrResourceRecord>[ptr]);
      expect(states.last.dnsSrvRecords, isEmpty);
      final MDnsState ptrSnapshot = states.last;

      final SrvResourceRecord srv = _srv('printer');
      srvController.add(srv);
      await pumpEventQueue();
      expect(states.last.status, MDnsStatus.searching);
      expect(states.last.dnsSrvRecords.keys.single, srv);
      expect(states.last.dnsSrvRecords[srv], isEmpty);
      final MDnsState srvSnapshot = states.last;

      final TxtResourceRecord txt = _txt('printer', 'path=/');
      txtController.add(txt);
      await pumpEventQueue();
      expect(states.last.status, MDnsStatus.searching);
      expect(
        states.last.dnsTxtRecords[srv.name.toLowerCase()],
        <TxtResourceRecord>[txt],
      );

      final IPAddressResourceRecord v4 = _ip('host.local', '192.168.1.10');
      ipController.add(v4);
      await pumpEventQueue();
      expect(states.last.status, MDnsStatus.searching);
      expect(states.last.dnsSrvRecords[srv], <IPAddressResourceRecord>[v4]);

      ptrController.add(_ptr('scanner'));
      await pumpEventQueue();
      expect(states.last.dnsPtrRecords, hasLength(2));

      // Earlier snapshots must not be mutated by later discoveries — every
      // copied layer: the PTR list, the SRV map, its address lists, and the
      // TXT map.
      expect(ptrSnapshot.dnsPtrRecords, hasLength(1));
      expect(ptrSnapshot.dnsSrvRecords, isEmpty);
      expect(srvSnapshot.dnsSrvRecords[srv], isEmpty);
      expect(srvSnapshot.dnsTxtRecords, isEmpty);
      expect(srvSnapshot.dnsPtrRecords, hasLength(1));

      final Future<MDnsState> done = bloc.stream.firstWhere(
        (MDnsState state) => state.status != MDnsStatus.searching,
      );
      await ptrController.close();
      await srvController.close();
      await txtController.close();
      await ipController.close();
      final MDnsState result = await done;

      expect(result.status, MDnsStatus.mDnsFound);
      expect(result.dnsSrvRecords.keys.single, srv);
      expect(result.dnsSrvRecords[srv], <IPAddressResourceRecord>[v4]);
      expect(
        result.dnsTxtRecords[srv.name.toLowerCase()],
        <TxtResourceRecord>[txt],
      );

      await subscription.cancel();
      await bloc.close();
    });

    test('a stopped search retains the records discovered so far', () async {
      final StreamController<PtrResourceRecord> ptrController =
          StreamController<PtrResourceRecord>();
      final StreamController<SrvResourceRecord> srvController =
          StreamController<SrvResourceRecord>();
      final StreamController<TxtResourceRecord> txtController =
          StreamController<TxtResourceRecord>();
      final MockMDnsClient client = _clientWith(
        ptr: () => ptrController.stream,
        srv: () => srvController.stream,
        txt: () => txtController.stream,
      );
      final MDnsBloc bloc = MDnsBloc(clientFactory: () => client);
      final List<MDnsState> states = <MDnsState>[];
      final StreamSubscription<MDnsState> subscription =
          bloc.stream.listen(states.add);

      bloc.add(const MDnsEventStartSearch(serverPointer: _type));
      await pumpEventQueue();
      final PtrResourceRecord ptr = _ptr('printer');
      final SrvResourceRecord srv = _srv('printer');
      final TxtResourceRecord txt = _txt('printer', 'path=/');
      ptrController.add(ptr);
      await pumpEventQueue();
      srvController.add(srv);
      txtController.add(txt);
      await pumpEventQueue();
      expect(states.last.dnsPtrRecords, <PtrResourceRecord>[ptr]);
      expect(states.last.dnsSrvRecords.keys.single, srv);

      bloc.add(const MDnsEventStopSearch());
      await pumpEventQueue();
      expect(states.last.status, MDnsStatus.stopped);
      expect(states.last.dnsPtrRecords, <PtrResourceRecord>[ptr]);
      expect(states.last.dnsSrvRecords.keys.single, srv);
      expect(
        states.last.dnsTxtRecords[srv.name.toLowerCase()],
        <TxtResourceRecord>[txt],
      );

      await ptrController.close();
      await srvController.close();
      await txtController.close();
      await pumpEventQueue();
      expect(states.last.status, MDnsStatus.stopped);

      await subscription.cancel();
      await bloc.close();
    });

    test('retains TXT records when no SRV resolves, ending mDnsScanned',
        () async {
      final PtrResourceRecord ptr = _ptr('printer');
      final MockMDnsClient client = _clientWith(
        ptr: () => Stream<PtrResourceRecord>.fromIterable(<PtrResourceRecord>[
          ptr,
        ]),
        txt: () => Stream<TxtResourceRecord>.fromIterable(<TxtResourceRecord>[
          _txt('printer', 'path=/index.html'),
        ]),
      );
      final MDnsBloc bloc = MDnsBloc(clientFactory: () => client);
      final Future<MDnsState> done = bloc.stream.firstWhere(
        (MDnsState state) => state.status != MDnsStatus.searching,
      );

      bloc.add(const MDnsEventStartSearch(serverPointer: _type, retries: 0));
      final MDnsState result = await done;

      expect(result.status, MDnsStatus.mDnsScanned);
      expect(result.dnsPtrRecords, <PtrResourceRecord>[ptr]);
      expect(
        result.dnsTxtRecords[ptr.domainName.toLowerCase()]!
            .map((TxtResourceRecord record) => record.text),
        <String>['path=/index.html'],
      );

      await bloc.close();
    });

    test('emits error when the client fails to start', () async {
      final MockMDnsClient client = MockMDnsClient();
      when(() => client.start()).thenThrow(const SocketException('no network'));
      // Defensive: the real MDnsClient's stop() silently returns after a
      // failed start, but the bloc must also tolerate a custom client
      // implementation whose stop() throws.
      when(() => client.stop()).thenThrow(
        StateError('Cannot stop mDNS client while it is starting.'),
      );
      final MDnsBloc bloc = MDnsBloc(clientFactory: () => client);
      final Future<MDnsState> done = bloc.stream.firstWhere(
        (MDnsState state) => state.status != MDnsStatus.searching,
      );

      bloc.add(const MDnsEventStartSearch(serverPointer: _type));
      final MDnsState result = await done;

      expect(result.status, MDnsStatus.error);
      expect(result.errorMsg, contains('no network'));

      await bloc.close();
    });

    test('MDnsEventStopSearch cancels the search in flight', () async {
      final StreamController<PtrResourceRecord> ptrController =
          StreamController<PtrResourceRecord>();
      final MockMDnsClient client =
          _clientWith(ptr: () => ptrController.stream);
      final MDnsBloc bloc = MDnsBloc(clientFactory: () => client);
      final List<MDnsState> states = <MDnsState>[];
      final StreamSubscription<MDnsState> subscription =
          bloc.stream.listen(states.add);

      bloc.add(const MDnsEventStartSearch(serverPointer: _type));
      await pumpEventQueue();
      expect(states.last.status, MDnsStatus.searching);

      bloc.add(const MDnsEventStopSearch());
      await pumpEventQueue();
      expect(states.last.status, MDnsStatus.stopped);
      verify(() => client.stop()).called(1);

      // The real client ends its lookup streams when stopped; emulate that
      // and check the cancelled search emits nothing further.
      await ptrController.close();
      await pumpEventQueue();
      expect(
        states.map((MDnsState state) => state.status),
        <MDnsStatus>[MDnsStatus.searching, MDnsStatus.stopped],
      );

      await subscription.cancel();
      await bloc.close();
    });

    test('a stopped search can be followed by a successful new search',
        () async {
      final StreamController<PtrResourceRecord> hanging =
          StreamController<PtrResourceRecord>();
      final MockMDnsClient first = _clientWith(ptr: () => hanging.stream);
      final SrvResourceRecord srv = _srv('printer');
      final MockMDnsClient second = _clientWith(
        ptr: () => Stream<PtrResourceRecord>.fromIterable(<PtrResourceRecord>[
          _ptr('printer'),
        ]),
        srv: () => Stream<SrvResourceRecord>.fromIterable(<SrvResourceRecord>[
          srv,
        ]),
      );
      final List<MockMDnsClient> clients = <MockMDnsClient>[first, second];
      final MDnsBloc bloc = MDnsBloc(clientFactory: () => clients.removeAt(0));
      final List<MDnsState> states = <MDnsState>[];
      final StreamSubscription<MDnsState> subscription =
          bloc.stream.listen(states.add);

      bloc.add(const MDnsEventStartSearch(serverPointer: _type));
      await pumpEventQueue();
      bloc.add(const MDnsEventStopSearch());
      await pumpEventQueue();
      expect(states.last.status, MDnsStatus.stopped);
      verify(() => first.stop()).called(1);

      final Future<MDnsState> done = bloc.stream.firstWhere(
        (MDnsState state) =>
            state.status != MDnsStatus.searching &&
            state.status != MDnsStatus.stopped,
      );
      bloc.add(const MDnsEventStartSearch(serverPointer: _type));
      final MDnsState result = await done;

      expect(result.status, MDnsStatus.mDnsFound);
      expect(result.dnsSrvRecords.keys.single, srv);

      // Unwind the stopped search and check it emits nothing further.
      await hanging.close();
      await pumpEventQueue();
      expect(states.last, result);

      await subscription.cancel();
      await bloc.close();
    });

    test('tolerates nested lookups failing with StateError after a stop',
        () async {
      // A stopped client's lookup() throws StateError ('mDNS client must be
      // started before calling lookup.'); the bloc swallows it for the
      // affected service instead of failing the whole search.
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
      ).thenThrow(
        StateError('mDNS client must be started before calling lookup.'),
      );
      final MDnsBloc bloc = MDnsBloc(clientFactory: () => client);
      final Future<MDnsState> done = bloc.stream.firstWhere(
        (MDnsState state) => state.status != MDnsStatus.searching,
      );

      bloc.add(const MDnsEventStartSearch(serverPointer: _type, retries: 0));
      final MDnsState result = await done;

      expect(result.status, MDnsStatus.mDnsScanned);
      expect(result.dnsPtrRecords, hasLength(1));

      await bloc.close();
    });

    test('MDnsEventStopSearch is a no-op when nothing is running', () async {
      final MDnsBloc bloc = MDnsBloc(clientFactory: MockMDnsClient.new);
      bloc.add(const MDnsEventStopSearch());
      await pumpEventQueue();
      expect(bloc.state, const MDnsState());
      await bloc.close();
    });

    test('a new search supersedes the one in flight', () async {
      final StreamController<PtrResourceRecord> hanging =
          StreamController<PtrResourceRecord>();
      final MockMDnsClient first = _clientWith(ptr: () => hanging.stream);
      final SrvResourceRecord srv = _srv('printer');
      final MockMDnsClient second = _clientWith(
        ptr: () => Stream<PtrResourceRecord>.fromIterable(<PtrResourceRecord>[
          _ptr('printer'),
        ]),
        srv: () => Stream<SrvResourceRecord>.fromIterable(<SrvResourceRecord>[
          srv,
        ]),
      );
      final List<MockMDnsClient> clients = <MockMDnsClient>[first, second];
      final MDnsBloc bloc = MDnsBloc(clientFactory: () => clients.removeAt(0));
      final List<MDnsState> states = <MDnsState>[];
      final StreamSubscription<MDnsState> subscription =
          bloc.stream.listen(states.add);

      bloc.add(const MDnsEventStartSearch(serverPointer: _type));
      await pumpEventQueue();
      expect(states.last.status, MDnsStatus.searching);

      final Future<MDnsState> done = bloc.stream.firstWhere(
        (MDnsState state) => state.status != MDnsStatus.searching,
      );
      bloc.add(const MDnsEventStartSearch(serverPointer: _type));
      final MDnsState result = await done;

      expect(result.status, MDnsStatus.mDnsFound);
      expect(result.dnsSrvRecords.keys.single, srv);
      verify(() => first.stop()).called(1);

      // Unwind the superseded search and check it emits nothing further.
      await hanging.close();
      await pumpEventQueue();
      expect(states.last, result);

      await subscription.cancel();
      await bloc.close();
    });

    test('close() stops the client of a search in flight', () async {
      final StreamController<PtrResourceRecord> hanging =
          StreamController<PtrResourceRecord>();
      final MockMDnsClient client = _clientWith(ptr: () => hanging.stream);
      final MDnsBloc bloc = MDnsBloc(clientFactory: () => client);

      bloc.add(const MDnsEventStartSearch(serverPointer: _type));
      await pumpEventQueue();

      final Future<void> closing = bloc.close();
      await pumpEventQueue();
      verify(() => client.stop()).called(1);

      await hanging.close();
      await closing;
    });
  });
}
