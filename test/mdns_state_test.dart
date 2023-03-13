// ignore_for_file: inference_failure_on_function_invocation

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mdns_bloc/mdns_bloc.dart';
import 'package:mdns_bloc/mdns_event.dart';
import 'package:mdns_bloc/mdns_state.dart';
import 'package:multicast_dns/multicast_dns.dart';

void main() {
  group('MDnsBloc', () {
    late MDnsBloc mDnsBloc;

    WidgetsFlutterBinding.ensureInitialized();

    setUp(() {
      mDnsBloc = MDnsBloc();
    });

    test('check initial state', () {
      expect(
          mDnsBloc.state,
          const MDnsState(
            status: MDnsStatus.initial,
          ));
    });

    blocTest(
      'emits MDnsStatus.initial and empty collections when MDnsEventStartSearch is added',
      build: () => mDnsBloc,
      act: (bloc) => bloc.add(const MDnsEventStartSearch(
          serverPointer: 'serverPointer', service: 'service')),
      expect: () => [
        const MDnsState(
          status: MDnsStatus.initial,
          dnsPtrRecords: <PtrResourceRecord>[],
          dnsSrvRecords: <SrvResourceRecord, IPAddressResourceRecord>{},
          errorMsg: '',
        )
      ],
    );
  });
}
