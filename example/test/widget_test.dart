import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mdns_bloc/mdns_bloc.dart';
import 'package:mdns_bloc_example/main.dart';
import 'package:mocktail/mocktail.dart';
import 'package:multicast_dns/multicast_dns.dart';

class _MockMDnsClient extends Mock implements MDnsClient {}

void main() {
  setUpAll(() {
    registerFallbackValue(
      ResourceRecordQuery.serverPointer('$defaultServiceType.local'),
    );
    registerFallbackValue(Duration.zero);
  });

  _MockMDnsClient clientWith({
    Stream<PtrResourceRecord>? ptr,
    Stream<SrvResourceRecord>? srv,
    Stream<TxtResourceRecord>? txt,
  }) {
    final _MockMDnsClient client = _MockMDnsClient();
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
    ).thenAnswer((_) => ptr ?? const Stream<PtrResourceRecord>.empty());
    when(
      () => client.lookup<SrvResourceRecord>(
        any(),
        timeout: any(named: 'timeout'),
      ),
    ).thenAnswer((_) => srv ?? const Stream<SrvResourceRecord>.empty());
    when(
      () => client.lookup<IPAddressResourceRecord>(
        any(),
        timeout: any(named: 'timeout'),
      ),
    ).thenAnswer((_) => const Stream<IPAddressResourceRecord>.empty());
    when(
      () => client.lookup<TxtResourceRecord>(
        any(),
        timeout: any(named: 'timeout'),
      ),
    ).thenAnswer((_) => txt ?? const Stream<TxtResourceRecord>.empty());
    return client;
  }

  Widget app(MDnsClient client) {
    return MaterialApp(
      home: BlocProvider(
        create: (_) => MDnsBloc(clientFactory: () => client)
          ..add(const MDnsEventStartSearch(
            serviceType: defaultServiceType,
            retries: 0,
          )),
        child: const MDnsSearchPage(),
      ),
    );
  }

  testWidgets('shows a spinner while searching and a message when done',
      (WidgetTester tester) async {
    final StreamController<PtrResourceRecord> ptrRecords =
        StreamController<PtrResourceRecord>();
    final _MockMDnsClient client = clientWith(ptr: ptrRecords.stream);

    await tester.pumpWidget(app(client));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Searching...'), findsOneWidget);

    // Ending the PTR stream lets the search complete without results.
    await ptrRecords.close();
    await tester.pumpAndSettle();

    expect(find.text('No services found'), findsOneWidget);
  });

  testWidgets('lists a resolved service with its port and TXT data',
      (WidgetTester tester) async {
    const String instance = 'printer.$defaultServiceType.local';
    final StreamController<PtrResourceRecord> ptrRecords =
        StreamController<PtrResourceRecord>();
    final _MockMDnsClient client = clientWith(
      ptr: ptrRecords.stream,
      srv: Stream<SrvResourceRecord>.fromIterable(<SrvResourceRecord>[
        SrvResourceRecord(
          instance,
          1 << 40,
          target: 'printer.local',
          port: 8080,
          priority: 1,
          weight: 1,
        ),
      ]),
      txt: Stream<TxtResourceRecord>.fromIterable(<TxtResourceRecord>[
        TxtResourceRecord(instance, 1 << 40, text: 'path=/index.html'),
      ]),
    );

    await tester.pumpWidget(app(client));
    await tester.pump();

    // The service streams in while the search is still running.
    ptrRecords.add(
      PtrResourceRecord(
        '$defaultServiceType.local',
        1 << 40,
        domainName: instance,
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text(instance), findsOneWidget);

    await ptrRecords.close();
    await tester.pumpAndSettle();

    // The completed list shows the service with its address-less subtitle
    // and flattened TXT data.
    expect(find.text('Detected 1 service:'), findsOneWidget);
    expect(
      find.text('no address resolved — port 8080\npath=/index.html'),
      findsOneWidget,
    );
  });
}
