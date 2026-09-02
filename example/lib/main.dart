import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:mdns_bloc/mdns_bloc.dart';

void main() {
  runApp(const MyApp());
}

/// The service instance the example highlights when it is discovered.
const String _exampleService = 'example._http._tcp.local';

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'mdns_bloc example',
      home: BlocProvider(
        create: (_) => MDnsBloc()
          ..add(const MDnsEventStartSearch(
            serviceType: defaultServiceType,
            serviceName: _exampleService,
          )),
        child: const MDnsSearchPage(),
      ),
    );
  }
}

class MDnsSearchPage extends StatelessWidget {
  const MDnsSearchPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<MDnsBloc, MDnsState>(
      builder: (BuildContext context, MDnsState state) {
        final bool searching = state.status == MDnsStatus.initial ||
            state.status == MDnsStatus.searching;
        return Scaffold(
          appBar: AppBar(
            title: Text(_title(state.status)),
            actions: <Widget>[
              if (searching)
                IconButton(
                  icon: const Icon(Icons.stop),
                  tooltip: 'Stop searching',
                  onPressed: () =>
                      context.read<MDnsBloc>().add(const MDnsEventStopSearch()),
                )
              else
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Search again',
                  onPressed: () => context.read<MDnsBloc>().add(
                        const MDnsEventStartSearch(
                          serviceType: defaultServiceType,
                          serviceName: _exampleService,
                        ),
                      ),
                ),
            ],
          ),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: _MDnsSearchBody(state: state),
            ),
          ),
        );
      },
    );
  }

  String _title(MDnsStatus status) {
    switch (status) {
      case MDnsStatus.initial:
      case MDnsStatus.searching:
        return 'mDNS Scanning';
      case MDnsStatus.noneFound:
      case MDnsStatus.found:
      case MDnsStatus.matched:
        return 'mDNS Scanning Complete';
      case MDnsStatus.stopped:
        return 'mDNS Scanning Stopped';
      case MDnsStatus.error:
        return 'Error mDNS Scanning';
    }
  }
}

class _MDnsSearchBody extends StatelessWidget {
  const _MDnsSearchBody({required this.state});

  final MDnsState state;

  @override
  Widget build(BuildContext context) {
    switch (state.status) {
      case MDnsStatus.initial:
        return const _Spinner();
      case MDnsStatus.searching:
        // Results stream into the state while the search runs; show them as
        // they arrive, with a progress bar while the scan is still going.
        if (state.services.isEmpty) {
          return const _Spinner();
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const LinearProgressIndicator(),
            Expanded(child: _ServiceList(state: state)),
          ],
        );
      case MDnsStatus.noneFound:
        return const Center(child: Text('No services found'));
      case MDnsStatus.stopped:
        if (state.services.isEmpty) {
          return const Center(child: Text('Search stopped'));
        }
        return _ServiceList(state: state);
      case MDnsStatus.found:
      case MDnsStatus.matched:
        return _ServiceList(state: state);
      case MDnsStatus.error:
        return Text(
          'There was an error in scanning: ${state.errorMessage}\n\n'
          'Final state was: $state',
        );
    }
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
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
    );
  }
}

class _ServiceList extends StatelessWidget {
  const _ServiceList({required this.state});

  final MDnsState state;

  @override
  Widget build(BuildContext context) {
    final List<MDnsService> services = state.services;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            'Detected ${services.length} '
            'service${services.length == 1 ? '' : 's'}:',
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: services.length,
            itemBuilder: (BuildContext context, int index) {
              final MDnsService service = services[index];
              final String addressText = service.addresses.isEmpty
                  ? 'no address resolved'
                  : service.addresses
                      .map((InternetAddress address) => address.address)
                      .join(', ');
              final String txtText = service.txt.join('; ');
              final String subtitle = txtText.isEmpty
                  ? '$addressText — port ${service.port}'
                  : '$addressText — port ${service.port}\n$txtText';
              return ListTile(
                title: Text(service.name),
                subtitle: Text(subtitle),
                isThreeLine: txtText.isNotEmpty,
                tileColor: service == state.match ? Colors.lightBlue : null,
              );
            },
          ),
        ),
      ],
    );
  }
}
