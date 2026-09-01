/// Bloc wrapper over `multicast_dns` which performs service discovery over
/// multicast DNS (mDNS), Bonjour and Avahi.
library;

export 'package:multicast_dns/multicast_dns.dart'
    show
        IPAddressResourceRecord,
        MDnsClient,
        PtrResourceRecord,
        ResourceRecord,
        ResourceRecordQuery,
        SrvResourceRecord;

export 'src/mdns_bloc.dart';
export 'src/mdns_constants.dart';
export 'src/mdns_event.dart';
export 'src/mdns_state.dart';
