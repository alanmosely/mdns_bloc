import 'package:flutter/material.dart';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:mdns_bloc/mdns_bloc.dart';
import 'package:mdns_bloc/mdns_event.dart';
import 'package:mdns_bloc/mdns_state.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => MDnsBloc()
        ..add(const MDnsEventStartSearch(
            serverPointer: '_http._tcp', service: 'example._http._tcp.local')),
      child: const MyAppView(),
    );
  }
}

class MyAppView extends StatelessWidget {
  const MyAppView({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<MDnsBloc, MDnsState>(builder: (context, state) {
      switch (state.status) {
        case MDnsStatus.initial:
          return MaterialApp(
              home: Scaffold(
                  appBar: AppBar(
                    title: const Text('mDNS Scanning'),
                  ),
                  body: SafeArea(
                      child: Container(
                          padding: const EdgeInsets.all(12.0),
                          child: Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: const [
                                SizedBox(
                                  width: 60,
                                  height: 60,
                                  child: CircularProgressIndicator(),
                                ),
                                Padding(
                                  padding: EdgeInsets.only(top: 16),
                                  child: Text('Searching...'),
                                ),
                              ],
                            ),
                          )))));
        case MDnsStatus.mDnsScanned:
          return MaterialApp(
              home: Scaffold(
                  appBar: AppBar(
                    title: const Text('mDNS Scanning Complete'),
                    actions: [
                      IconButton(
                          icon: const Icon(Icons.refresh),
                          onPressed: () {
                            context.read<MDnsBloc>().add(
                                const MDnsEventStartSearch(
                                    serverPointer: '_http._tcp'));
                          }),
                    ],
                  ),
                  body: SafeArea(
                      child: Container(
                          padding: const EdgeInsets.all(12.0),
                          child: const Center(
                            child: Text('No services found'),
                          )))));
        case MDnsStatus.mDnsFound:
        case MDnsStatus.mDnsMatch:
          return MaterialApp(
              home: Scaffold(
                  appBar: AppBar(
                    title: const Text('mDNS Scanning Complete'),
                    actions: [
                      IconButton(
                          icon: const Icon(Icons.refresh),
                          onPressed: () {
                            context.read<MDnsBloc>().add(
                                const MDnsEventStartSearch(
                                    serverPointer: '_http._tcp'));
                          }),
                    ],
                  ),
                  body: SafeArea(
                      child: Container(
                          padding: const EdgeInsets.all(12.0),
                          child: Column(
                              mainAxisSize: MainAxisSize.max,
                              mainAxisAlignment: MainAxisAlignment.start,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Flexible(
                                  child: Container(
                                    padding: const EdgeInsets.all(12.0),
                                    child: Text(
                                        "Detected ${state.dnsSrvRecords.length} service${state.dnsSrvRecords.length > 1 ? 's' : ''}:"),
                                  ),
                                ),
                                Expanded(
                                    child: ListView.builder(
                                  shrinkWrap: true,
                                  itemCount: state.dnsSrvRecords.length,
                                  itemBuilder: (context, index) {
                                    var keys =
                                        state.dnsSrvRecords.keys.toList();
                                    var name = keys[index].name;
                                    return ListTile(
                                      title: Text(
                                          '$name - ${state.dnsSrvRecords[keys[index]]?.address.address}'),
                                      tileColor: name == state.service?.name
                                          ? Colors.lightBlue
                                          : null,
                                    );
                                  },
                                ))
                              ])))));
        case MDnsStatus.error:
          return MaterialApp(
              home: Scaffold(
                  appBar: AppBar(
                    title: const Text('Error mDNS Scanning'),
                  ),
                  body: SafeArea(
                      child: Container(
                    padding: const EdgeInsets.all(12.0),
                    child: Text(
                        'There was an error in scanning: ${state.errorMsg}.\n\n\nFinal state was: $state'),
                  ))));
      }
    });
  }
}
