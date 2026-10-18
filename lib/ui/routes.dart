import 'package:flutter/widgets.dart';

/// Lets pages react when another page covers them or closes on top of them
/// (the song page pauses and resumes its music preview).
final routeObserver = RouteObserver<ModalRoute<void>>();
