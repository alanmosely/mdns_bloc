import 'dart:io';

import 'package:mdns_bloc/mdns_bloc.dart';
import 'package:test/test.dart';

void main() {
  group('MDnsService', () {
    test('supports value equality', () {
      MDnsService build() => MDnsService(
            name: 'printer._http._tcp.local',
            host: 'host.local',
            port: 8080,
            addresses: <InternetAddress>[InternetAddress('192.168.1.10')],
            txt: const <String>['path=/'],
          );
      expect(build(), build());
      expect(
        build(),
        isNot(const MDnsService(
          name: 'printer._http._tcp.local',
          host: 'host.local',
          port: 9090,
        )),
      );
    });

    test('txtAttributes parses key=value and bare-key attributes', () {
      const MDnsService service = MDnsService(
        name: 'printer._http._tcp.local',
        host: 'host.local',
        port: 8080,
        txt: <String>['path=/index.html', 'flag', 'empty='],
      );
      expect(service.txtAttributes, <String, String?>{
        'path': '/index.html',
        'flag': null,
        'empty': '',
      });
    });

    test('txtAttributes keeps the first occurrence of a key, ignoring case',
        () {
      const MDnsService service = MDnsService(
        name: 'printer._http._tcp.local',
        host: 'host.local',
        port: 8080,
        txt: <String>['path=/first', 'PATH=/second', 'path=/third'],
      );
      expect(service.txtAttributes, <String, String?>{'path': '/first'});
    });

    test('toString mentions the name, host and port', () {
      const MDnsService service = MDnsService(
        name: 'printer._http._tcp.local',
        host: 'host.local',
        port: 8080,
      );
      final String description = service.toString();
      expect(description, contains('printer._http._tcp.local'));
      expect(description, contains('host.local'));
      expect(description, contains('8080'));
    });
  });
}
