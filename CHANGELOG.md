# Changelog

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
