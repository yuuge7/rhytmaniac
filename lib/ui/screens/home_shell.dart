import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/native_bridge.dart';
import '../../state/providers.dart';
import '../import_flow.dart';
import 'library_screen.dart';
import 'profile_screen.dart';
import 'settings_screen.dart';

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _tab = 0;
  StreamSubscription<void>? _opened;

  @override
  void initState() {
    super.initState();
    _opened = NativeBridge.instance.fileOpened.listen((_) => _takeOpenedFile());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // First launch: install the bundled demo so there is something to play.
      final settings = ref.read(settingsProvider);
      final library = ref.read(libraryProvider);
      if (!settings.demoInstalled && library.songs.isEmpty) {
        ref.read(importProvider.notifier).installDemo();
      }
      // Medals earned by plays from before medals existed.
      ref.read(progressProvider.notifier).check();
      _takeOpenedFile();
    });
  }

  @override
  void dispose() {
    _opened?.cancel();
    super.dispose();
  }

  /// A file opened with or shared to the app: import it into the library.
  Future<void> _takeOpenedFile() async {
    final file = await NativeBridge.instance.takeOpenedFile();
    if (file == null || !mounted) return;
    // Back to the library, but never past a screen that guards its exit (a
    // run in progress, unsaved edits); the import goes on underneath.
    Navigator.of(context).popUntil((r) => r.isFirst || r.popDisposition == RoutePopDisposition.doNotPop);
    setState(() => _tab = 0);
    await openIncomingFile(context, ref, file);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: const [LibraryScreen(), ProfileScreen(), SettingsScreen()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.library_music_outlined), selectedIcon: Icon(Icons.library_music_rounded), label: 'Library'),
          NavigationDestination(icon: Icon(Icons.person_outline_rounded), selectedIcon: Icon(Icons.person_rounded), label: 'Profile'),
          NavigationDestination(icon: Icon(Icons.tune_outlined), selectedIcon: Icon(Icons.tune_rounded), label: 'Settings'),
        ],
      ),
    );
  }
}
