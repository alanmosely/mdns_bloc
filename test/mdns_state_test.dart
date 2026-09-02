import 'dart:io';

import 'package:mdns_bloc/mdns_bloc.dart';
import 'package:test/test.dart';

MDnsService _service(String instance, {int port = 8080}) => MDnsService(
      name: '$instance._http._tcp.local',
      host: 'host.local',
      port: port,
      addresses: <InternetAddress>[InternetAddress('192.168.1.10')],
      txt: const <String>['path=/'],
    );

void main() {
  group('MDnsState', () {
    test('defaults to an empty initial state', () {
      const MDnsState state = MDnsState();
      expect(state.status, MDnsStatus.initial);
      expect(state.services, isEmpty);
      expect(state.discoveredNames, isEmpty);
      expect(state.match, isNull);
      expect(state.error, isNull);
      expect(state.errorMessage, isNull);
      expect(state.stackTrace, isNull);
    });

    test('supports value equality', () {
      expect(const MDnsState(), const MDnsState());
      expect(
        MDnsState(services: <MDnsService>[_service('a')]),
        MDnsState(services: <MDnsService>[_service('a')]),
      );
      expect(
        const MDnsState(),
        isNot(const MDnsState(status: MDnsStatus.searching)),
      );
    });

    test('copyWith replaces the given fields', () {
      final MDnsState state = const MDnsState().copyWith(
        status: MDnsStatus.searching,
        discoveredNames: <String>['a._http._tcp.local'],
      );
      expect(state.status, MDnsStatus.searching);
      expect(state.discoveredNames, <String>['a._http._tcp.local']);
      expect(state.services, isEmpty);
    });

    test('copyWith keeps match and error when the parameters are omitted', () {
      final MDnsService match = _service('a');
      final MDnsState state = MDnsState(
        match: match,
        error: const SocketException('boom'),
      );
      final MDnsState copy = state.copyWith(status: MDnsStatus.error);
      expect(copy.match, match);
      expect(copy.error, isA<SocketException>());
    });

    test('copyWith keeps record collections when omitted', () {
      final MDnsState state = MDnsState(
        services: <MDnsService>[_service('a')],
        discoveredNames: const <String>['a._http._tcp.local'],
      );
      final MDnsState copy = state.copyWith(status: MDnsStatus.stopped);
      expect(copy.services, state.services);
      expect(copy.discoveredNames, state.discoveredNames);
    });

    test('copyWith clears match and error when explicitly passed null', () {
      final MDnsState state = MDnsState(
        match: _service('a'),
        error: const SocketException('boom'),
        stackTrace: StackTrace.current,
      );
      final MDnsState copy =
          state.copyWith(match: null, error: null, stackTrace: null);
      expect(copy.match, isNull);
      expect(copy.error, isNull);
      expect(copy.stackTrace, isNull);
    });

    test('errorMessage describes the error', () {
      final MDnsState state =
          MDnsState(error: const SocketException('no network'));
      expect(state.errorMessage, contains('no network'));
    });

    test('toString is balanced and mentions the status', () {
      final String description = const MDnsState().toString();
      expect(description, contains('MDnsStatus.initial'));
      expect(
        '{'.allMatches(description).length,
        '}'.allMatches(description).length,
      );
    });
  });
}
