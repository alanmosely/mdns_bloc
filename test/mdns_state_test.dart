import 'package:flutter_test/flutter_test.dart';
import 'package:mdns_bloc/mdns_bloc.dart';

SrvResourceRecord _srv(String name) => SrvResourceRecord(
      name,
      0,
      target: 'host.local',
      port: 8080,
      priority: 1,
      weight: 1,
    );

void main() {
  group('MDnsState', () {
    test('defaults to an empty initial state', () {
      const MDnsState state = MDnsState();
      expect(state.status, MDnsStatus.initial);
      expect(state.dnsPtrRecords, isEmpty);
      expect(state.dnsSrvRecords, isEmpty);
      expect(state.service, isNull);
      expect(state.errorMsg, isEmpty);
    });

    test('supports value equality', () {
      expect(const MDnsState(), const MDnsState());
      expect(
        const MDnsState(status: MDnsStatus.searching),
        isNot(const MDnsState()),
      );
    });

    test('copyWith replaces the given fields', () {
      final MDnsState state = const MDnsState().copyWith(
        status: MDnsStatus.error,
        errorMsg: 'boom',
      );
      expect(state.status, MDnsStatus.error);
      expect(state.errorMsg, 'boom');
    });

    test('copyWith keeps service when the parameter is omitted', () {
      final SrvResourceRecord service = _srv('a._http._tcp.local');
      final MDnsState state = MDnsState(service: service);
      expect(state.copyWith(status: MDnsStatus.stopped).service, service);
    });

    test('copyWith clears service when explicitly passed null', () {
      final MDnsState state = MDnsState(service: _srv('a._http._tcp.local'));
      expect(state.copyWith(service: null).service, isNull);
    });

    test('toString is balanced and mentions the status', () {
      final String description = const MDnsState().toString();
      expect(description, startsWith('MDnsState {'));
      expect(description, endsWith('}'));
      expect(description, contains('MDnsStatus.initial'));
    });
  });
}
