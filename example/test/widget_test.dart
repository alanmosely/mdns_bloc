import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mdns_bloc/mdns_bloc.dart';
import 'package:mdns_bloc_example/main.dart';
import 'package:mocktail/mocktail.dart';

class _MockMDnsClient extends Mock implements MDnsClient {}

void main() {
  setUpAll(() {
    registerFallbackValue(
      ResourceRecordQuery.serverPointer('$defaultServiceType.local'),
    );
    registerFallbackValue(Duration.zero);
  });

  testWidgets('shows a spinner while searching and a message when done',
      (WidgetTester tester) async {
    final StreamController<PtrResourceRecord> ptrRecords =
        StreamController<PtrResourceRecord>();
    final _MockMDnsClient client = _MockMDnsClient();
    when(() => client.start()).thenAnswer((_) async {});
    when(
      () => client.lookup<PtrResourceRecord>(
        any(),
        timeout: any(named: 'timeout'),
      ),
    ).thenAnswer((_) => ptrRecords.stream);

    await tester.pumpWidget(
      MaterialApp(
        home: BlocProvider(
          create: (_) => MDnsBloc(clientFactory: () => client)
            ..add(const MDnsEventStartSearch(
              serverPointer: defaultServiceType,
              retries: 0,
            )),
          child: const MDnsSearchPage(),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Searching...'), findsOneWidget);

    // Ending the PTR stream lets the search complete without results.
    await ptrRecords.close();
    await tester.pumpAndSettle();

    expect(find.text('No services found'), findsOneWidget);
  });
}
