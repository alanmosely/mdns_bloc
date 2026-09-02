
![logo]

[![pub package][pub_badge]][pub_link]
[![ci][ci_badge]][ci_link]
[![License: MIT][license_badge]][license_link]

# mdns_bloc

Dart library to perform service discovery over multicast DNS (mDNS, also
known as Bonjour or Avahi), using [Bloc][bloc_link]. It wraps
[`multicast_dns`][multicast_dns_link] behind a small bloc so your UI only has
to react to states. Pure Dart — usable from Flutter apps (via
[`flutter_bloc`][flutter_bloc_link]) and from command-line or server
applications alike.

## Features

* Searches for services by type (e.g. `_http._tcp`), resolving PTR → SRV →
  A/AAAA and TXT records into typed, immutable `MDnsService` values, with
  duplicates removed.
* Progressive results: while the search runs, each `searching` state carries
  a snapshot of the services discovered so far.
* Optionally matches a specific service instance name (case-insensitively).
* Configurable per-lookup timeout, retry count, and network interfaces.
* Cancellable: stop a search with an event (keeping what was found), or
  start a new search to supersede the one in flight.
* Errors — including socket errors reported mid-search — surface as an
  `error` state carrying the original exception, never as unhandled zone
  errors.
* Each search runs on its own `MDnsClient`, injectable for tests.

## Usage

```dart
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:mdns_bloc/mdns_bloc.dart';

BlocProvider(
  create: (_) => MDnsBloc()
    ..add(const MDnsEventStartSearch(
      serviceType: '_http._tcp',
      serviceName: 'example._http._tcp.local', // optional instance to match
    )),
  child: BlocBuilder<MDnsBloc, MDnsState>(
    builder: (context, state) {
      switch (state.status) {
        case MDnsStatus.initial:
        case MDnsStatus.searching:
          return const CircularProgressIndicator();
        case MDnsStatus.noneFound:
          return const Text('No services found');
        case MDnsStatus.stopped:
          return const Text('Search stopped');
        case MDnsStatus.found:
        case MDnsStatus.matched:
          return Text('Found ${state.services.length} services');
        case MDnsStatus.error:
          return Text('Error: ${state.errorMessage}');
      }
    },
  ),
);
```

Stop a running search with:

```dart
context.read<MDnsBloc>().add(const MDnsEventStopSearch());
```

`MDnsEventStartSearch` also accepts `retries` (extra attempts when nothing is
found, default 3) and `timeout` (how long each individual lookup waits,
default 5 seconds). Starting a new search while one is running cancels the
old one.

On multi-homed machines (VPNs, virtual adapters) you can control which
network interfaces searches use:

```dart
MDnsBloc(
  interfacesFactory: (type) async => (await NetworkInterface.list(
    type: type,
  ))
      .where((interface) => !interface.name.startsWith('utun'))
      .toList(),
);
```

### States

| `MDnsStatus` | Meaning                                                         |
| ------------ | --------------------------------------------------------------- |
| `initial`    | No search started yet.                                          |
| `searching`  | A search is in flight; the state carries the services discovered so far. |
| `noneFound`  | The search completed without resolving any services.            |
| `found`      | Services were resolved (no instance name matched/requested).    |
| `matched`    | A service matching the requested instance name was found; see `state.match`. |
| `stopped`    | The search was cancelled by `MDnsEventStopSearch`; services found before the cancellation are retained. |
| `error`      | The search failed; see `state.error` / `state.errorMessage`.    |

Discovered services are in `state.services`, a list of immutable
`MDnsService` values: instance `name`, `host`, `port`, SRV
`priority`/`weight`, the resolved IPv4/IPv6 `addresses`, and the TXT
attributes as both raw strings (`txt`) and a parsed map (`txtAttributes`).
`state.discoveredNames` additionally lists every instance name announced
over the wire, including ones that never resolved. On failure `state.error`
holds the original error object (often a `SocketException`), so you can
match on its type rather than its message.

## Platform setup

mDNS needs platform permissions; without them searches silently find nothing
or fail.

### iOS (and macOS 11+)

Since iOS 14 the local network is permission-gated. Add to your app's
`Info.plist` the reason for local-network access and the Bonjour service
types you query:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>This app uses the local network to discover services advertised over mDNS/Bonjour.</string>
<key>NSBonjourServices</key>
<array>
  <string>_http._tcp</string>
</array>
```

On **physical iOS 14+ devices** the two Info.plist keys are not sufficient on
their own: `multicast_dns` sends and receives raw UDP multicast rather than
using the Bonjour APIs, so the app must additionally be signed with the
restricted [`com.apple.developer.networking.multicast`][multicast_entitlement_link]
entitlement, which you [request from Apple][multicast_request_link]. Without
it, discovery works in the simulator but on a device fails (typically
`SocketException: No route to host, errno = 65`) or silently finds nothing.

> **Note:** discovery on physical iOS devices with the multicast entitlement
> has not yet been verified with this package — reports welcome on the
> [issue tracker][issue_tracker_link].

For sandboxed macOS apps also enable the network client/server entitlements
(`com.apple.security.network.client` and `com.apple.security.network.server`);
the multicast entitlement is not required on macOS.

### Android

Add to `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>
<uses-permission android:name="android.permission.CHANGE_WIFI_MULTICAST_STATE"/>
```

Some devices only deliver multicast packets while a
[multicast lock][multicast_lock_link] is held; if discovery finds nothing on
a device, acquire one (e.g. through a plugin) before searching.

## Testing

`MDnsBloc` takes a `clientFactory`, so you can substitute a mock
`MDnsClient` (e.g. with [`mocktail`][mocktail_link]) and test your UI without
touching the network:

```dart
final bloc = MDnsBloc(clientFactory: () => myMockClient);
```

See [`test/mdns_bloc_test.dart`][bloc_test_link] for examples.

[logo]: https://raw.githubusercontent.com/alanmosely/mdns_bloc/master/logo.png
[pub_badge]: https://img.shields.io/pub/v/mdns_bloc.svg
[pub_link]: https://pub.dev/packages/mdns_bloc
[ci_badge]: https://github.com/alanmosely/mdns_bloc/actions/workflows/ci.yaml/badge.svg
[ci_link]: https://github.com/alanmosely/mdns_bloc/actions/workflows/ci.yaml
[license_badge]: https://img.shields.io/badge/license-MIT-blue.svg
[license_link]: https://opensource.org/licenses/MIT
[bloc_link]: https://bloclibrary.dev
[flutter_bloc_link]: https://pub.dev/packages/flutter_bloc
[multicast_dns_link]: https://pub.dev/packages/multicast_dns
[multicast_entitlement_link]: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.multicast
[multicast_request_link]: https://developer.apple.com/contact/request/networking-multicast
[multicast_lock_link]: https://developer.android.com/reference/android/net/wifi/WifiManager.MulticastLock
[mocktail_link]: https://pub.dev/packages/mocktail
[bloc_test_link]: https://github.com/alanmosely/mdns_bloc/blob/master/test/mdns_bloc_test.dart
[issue_tracker_link]: https://github.com/alanmosely/mdns_bloc/issues
