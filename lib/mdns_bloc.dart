import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:mdns_bloc/mdns_constants.dart';
import 'package:multicast_dns/multicast_dns.dart';

import 'mdns_event.dart';
import 'mdns_service.dart';
import 'mdns_state.dart';

class MDnsBloc extends Bloc<MDnsEvent, MDnsState> {
  MDnsBloc() : super(const MDnsState()) {
    on<MDnsEventStartSearch>(_onStart);
  }

  /// A late final variable that is assigned to the instance of the MDnsClient class.
  late final MDnsClient mDnsService = MDnsService();

  /// _onStart() is a function that is called when the MDnsEventStartSearch event is emitted
  ///
  /// Args:
  ///   event (MDnsEventStartSearch): This is the event that was emitted by the UI
  ///   emit (Emitter<MDnsState>): This is the function that you use to emit a new state
  Future<void> _onStart(
    MDnsEventStartSearch event,
    Emitter<MDnsState> emit,
  ) async {
    try {
      emit(
        state.copyWith(
          status: MDnsStatus.initial,
        ),
      );

      await mDnsService.start();
      int retries = 0;
      List<PtrResourceRecord> dnsPtrRecords = <PtrResourceRecord>[];
      Map<String, SrvResourceRecord> dnsSrvRecords =
          <String, SrvResourceRecord>{};
      SrvResourceRecord? service;

      while (dnsSrvRecords.isEmpty && retries <= RETRIES) {
        await for (PtrResourceRecord ptr
            in mDnsService.lookup<PtrResourceRecord>(
                ResourceRecordQuery.serverPointer(event.serverPointer))) {
          dnsPtrRecords.add(ptr);
          await for (SrvResourceRecord srv
              in mDnsService.lookup<SrvResourceRecord>(
                  ResourceRecordQuery.service(ptr.domainName))) {
            await for (IPAddressResourceRecord ip
                in mDnsService.lookup<IPAddressResourceRecord>(
                    ResourceRecordQuery.addressIPv4(srv.target))) {
              dnsSrvRecords[srv.name] = srv;
              if (srv.name == event.service) {
                service = srv;
              }
            }
          }
        }
      }

      if (dnsSrvRecords.isNotEmpty) {
        if (service != null) {
          emit(
            state.copyWith(
              status: MDnsStatus.mDnsMatch,
              dnsPtrRecords: dnsPtrRecords,
              dnsSrvRecords: dnsSrvRecords,
              service: service,
            ),
          );
        } else {
          emit(
            state.copyWith(
              status: MDnsStatus.mDnsFound,
              dnsPtrRecords: dnsPtrRecords,
              dnsSrvRecords: dnsSrvRecords,
              service: null,
            ),
          );
        }
      } else {
        emit(
          state.copyWith(
            status: MDnsStatus.mDnsScanned,
            dnsPtrRecords: dnsPtrRecords,
          ),
        );
      }
    } catch (e) {
      emit(state.copyWith(status: MDnsStatus.error, errorMsg: e.toString()));
    } finally {
      mDnsService.stop();
    }
  }
}
