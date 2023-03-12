import 'package:equatable/equatable.dart';

/// An abstract class that represents events across the discovery process
abstract class MDnsEvent extends Equatable {
  const MDnsEvent();

  @override
  List<Object?> get props => [];
}

/// A class that represents the start of the discovery process
class MDnsEventStartSearch extends MDnsEvent {
  final String serverPointer;
  final String? service;

  const MDnsEventStartSearch({required this.serverPointer, this.service});

  @override
  List<Object?> get props => [serverPointer, service];
}
