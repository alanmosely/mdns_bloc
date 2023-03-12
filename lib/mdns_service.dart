import 'package:multicast_dns/multicast_dns.dart';

/// The MDnsService class is a singleton that returns an instance of the MDnsClient
/// class
class MDnsService extends MDnsClient {
  /// A static variable that is used to store the instance of the class
  static MDnsService? _instance;

  MDnsService._internal() {
    _instance = this;
  }

  factory MDnsService() => _instance ?? MDnsService._internal();
}
