/// A common service type to search for: HTTP servers advertised over mDNS.
const String defaultServiceType = '_http._tcp';

/// The default number of additional attempts a search makes when it finds no
/// services, so a search makes at most `defaultRetries + 1` attempts.
const int defaultRetries = 3;

/// The default amount of time each individual mDNS lookup waits for
/// responses.
const Duration defaultTimeout = Duration(seconds: 5);
