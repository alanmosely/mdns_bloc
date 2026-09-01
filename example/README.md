# mdns_bloc_example

Demonstrates how to use the mdns_bloc package: it searches the local network
for `_http._tcp` services when it starts, shows the services it finds (name,
addresses and port), and lets you stop the search or run it again from the
app bar.

Note that mDNS needs platform permissions — this example already declares the
iOS local-network keys and Android multicast permissions. See the
[package README](../README.md) for details.
