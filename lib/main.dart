import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'data/import_service.dart';
import 'data/library_repository.dart';
import 'data/pack_service.dart';
import 'data/storage.dart';
import 'state/providers.dart';
import 'ui/routes.dart';
import 'ui/screens/home_shell.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Palette.inkDeep,
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  final docs = await getApplicationDocumentsDirectory();
  final paths = AppPaths(p.join(docs.path, 'rhytmaniac'));
  await paths.ensure();
  await paths.cleanTmp();
  final db = await AppDatabase.open(paths.databaseFile);
  final repo = LibraryRepository(paths, db);

  final services = AppServices(
    paths: paths,
    repo: repo,
    importer: ImportService(repo),
    packs: PackService(repo),
    initialSettings: await repo.settings(),
    initialProfile: await repo.profile(),
    initialScores: await repo.scores(),
    initialSongs: await repo.songs(),
    initialBeatmaps: await repo.beatmaps(),
  );

  runApp(ProviderScope(
    overrides: [servicesProvider.overrideWithValue(services)],
    child: const RhytmaniacApp(),
  ));
}

class RhytmaniacApp extends StatelessWidget {
  const RhytmaniacApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rhytmaniac',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      darkTheme: buildTheme(),
      themeMode: ThemeMode.dark,
      navigatorObservers: [routeObserver],
      home: const HomeShell(),
    );
  }
}
