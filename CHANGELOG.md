# Changelog

## 0.3.0

Breaking changes:

* The package is now pure Dart: it depends on `bloc` instead of
  `flutter_bloc`, so it can be used from command-line and server
  applications. Flutter apps keep working (`flutter_bloc` re-exports the
  same `Bloc` class) but must declare `flutter_bloc` in their own
  `pubspec.yaml` if they were relying on `mdns_bloc` to provide it
  transitively.
* Results are now typed: `MDnsState.services` is a list of immutable
  `MDnsService` values (instance `name`, `host`, `port`, SRV
  `priority`/`weight`, resolved `addresses`, and TXT attributes via `txt` /
  `txtAttributes`), replacing `dnsPtrRecords`, `dnsSrvRecords` and
  `dnsTxtRecords`. Instance names announced but never resolved are in
  `MDnsState.discoveredNames`. TXT data belonging to an instance whose SRV
  never resolved is no longer surfaced.
* `MDnsStatus` values renamed to say what they mean: `mDnsScanned` →
  `noneFound`, `mDnsFound` → `found`, `mDnsMatch` → `matched`.
* `MDnsEventStartSearch.serverPointer` is now `serviceType`, its `service`
  is now `serviceName`, and the matched service moved from
  `MDnsState.service` to `MDnsState.match`.
* Errors are no longer stringly-typed: `MDnsState.error` holds the original
  error object (with `stackTrace` alongside), so consumers can match on the
  type; `errorMsg` is replaced by the `errorMessage` getter, null when there
  is no error.
* The event and state hierarchies are `sealed`/`final`, giving exhaustive
  `switch`es over events; the barrel no longer re-exports `multicast_dns`'s
  resource-record types (only `MDnsClient` and the factory typedefs used by
  the `MDnsBloc` constructor).

Fixes:

* A lookup failing while another lookup stream was still open (e.g. Wi-Fi
  dropping mid-scan) used to surface as an unhandled zone error that
  bypassed the bloc; every resolution future now has its errors contained
  from the moment it is created, and a failure promptly cancels the lookups
  still in flight and ends the search with an `MDnsStatus.error` state that
  retains what was discovered before the failure.
* `MDnsClient.start()` is now passed an `onError` handler, so errors
  reported asynchronously by the client's receive socket (interface resets,
  ICMP-triggered UDP errors) stop the search and surface as an error state
  instead of an unhandled zone error. This raises the `multicast_dns` floor
  to `^0.3.3`, the version that added the parameter.
* PTR and SRV deduplication now compares DNS names case-insensitively,
  consistent with the rest of the package, so differently-cased
  announcements of one instance collapse into a single result.
* Emitted states are immutable throughout: terminal states no longer hand
  out the bloc's live internal collections.

Improvements:

* New `MDnsBloc(interfacesFactory: ...)` parameter selects the network
  interfaces every search listens on (e.g. to exclude a VPN interface on
  multi-homed machines); it applies to injected clients too.
* An error during a search no longer burns the remaining retry attempts.
* CI now tests the package against both the oldest supported Dart SDK and
  the latest stable, and the tag-triggered publish workflow runs the full
  analyze/test suite before publishing.

## 0.2.0

* TXT records are now resolved for each discovered service and exposed via
  `MDnsState.dnsTxtRecords`, keyed by service instance name and
  deduplicated by text content.
* Results are emitted progressively: while a search runs, each
  `MDnsStatus.searching` state carries a snapshot of the records discovered
  so far, and a stopped search retains everything found before the
  cancellation. Progressive states hold defensive copies, so earlier
  snapshots are never mutated by later discoveries.
* The example app shows results live while scanning and displays TXT data.

## 0.1.0

Breaking changes:

* Requires Dart `^3.5.0` / Flutter `>=3.24.0`; upgraded to `flutter_bloc` 9.
* Everything is now exported from a single
  `package:mdns_bloc/mdns_bloc.dart` import; the `mdns_event.dart`,
  `mdns_state.dart` and `mdns_constants.dart` libraries moved under
  `lib/src/`.
* Removed the `MDnsService` singleton; `MDnsBloc` now creates a fresh
  `MDnsClient` per search and accepts a `clientFactory` for injection.
* `MDnsState.dnsSrvRecords` is now
  `Map<SrvResourceRecord, List<IPAddressResourceRecord>>`, since a service
  can resolve to several addresses (IPv4 and IPv6) or none.
* Added `MDnsStatus.searching` (emitted while a search is in flight) and
  `MDnsStatus.stopped` (emitted when a search is cancelled).
* Constants renamed: `NAME` → `defaultServiceType`, `RETRIES` →
  `defaultRetries`; added `defaultTimeout`.

Fixes and improvements:

* `MDnsEventStopSearch` now actually cancels the in-flight search and stops
  the client (previously it only changed the state while the search kept
  running).
* Starting a new search cancels the previous one (`restartable` event
  transformer) instead of racing it on a shared client.
* IPv6 (AAAA) records are resolved alongside IPv4, and services whose host
  has no address records are no longer dropped from the results.
* Duplicate PTR/SRV/address announcements are de-duplicated.
* PTR, SRV and address lookups run concurrently, making scans much faster.
* Retry count and per-lookup timeout are configurable on
  `MDnsEventStartSearch`.
* Service instance matching is case-insensitive, as DNS names are.
* `MDnsState.copyWith` can now clear `service` by passing `null` explicitly.
* The bloc stops its client when closed.
* Real unit tests with a mocked client; no network I/O in tests.
* Example app: single `MaterialApp`, stop/refresh actions, shows all
  resolved addresses, declares the required iOS local-network keys and
  Android multicast permissions, and builds with current toolchains
  (declarative Gradle with AGP 8.11 / Kotlin 2.2, iOS 13 minimum). The
  README documents the iOS multicast entitlement needed on physical
  devices.

## 0.0.5

* Alpha: Add MDnsEventStopSearch

## 0.0.4

* Alpha: Add IP address

## 0.0.3

* Alpha: Fix retries

## 0.0.2

* Alpha: Improvements to pub.dev score

## 0.0.1

* Alpha: First release
