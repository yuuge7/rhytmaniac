import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/difficulty.dart';
import '../../core/models/song.dart';
import '../../data/import_service.dart';
import '../../platform/native_bridge.dart';
import '../../state/providers.dart';
import '../import_flow.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/signal_strip.dart';
import 'song_screen.dart';

enum LibrarySort {
  added('Recently added'),
  title('Title'),
  bpm('BPM'),
  stars('Stars'),
  played('Most played');

  const LibrarySort(this.label);
  final String label;
}

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  LibrarySort _sort = LibrarySort.added;
  bool _descending = true;
  String _query = '';
  bool _searching = false;

  /// Shelf: null = all songs, [_favorites] or a collection name.
  String? _shelf;
  static const _favorites = '\u0000favorites';

  /// Filters: stars of the song's maps in the current mode, length in minutes.
  RangeValues _stars = const RangeValues(0, _maxStars);
  RangeValues _minutes = const RangeValues(0, _maxMinutes);
  static const _maxStars = 8.0;
  static const _maxMinutes = 10.0;

  bool get _filtering => _stars != const RangeValues(0, _maxStars) || _minutes != const RangeValues(0, _maxMinutes);

  Future<void> _import() async {
    final file = await NativeBridge.instance.pickFile(importMimeTypes);
    if (file != null && mounted) await importSongFile(context, ref, file);
  }

  /// Lets the player choose what kind of file to bring in.
  Future<void> _chooseImport() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, 8),
            child: Text('Import', style: AppText.display(22, width: 120, weight: 800)),
          ),
          ListTile(
            leading: const Icon(Icons.music_note_rounded),
            title: const Text('Song or video'),
            subtitle: const Text('MP4, MP3, M4A, OGG or WAV. Maps are generated for you.'),
            onTap: () => Navigator.pop(c, 'song'),
          ),
          ListTile(
            leading: const Icon(Icons.radio_button_checked_rounded),
            title: const Text('osu! beatmap set'),
            subtitle: const Text('An .osz file. osu! and osu!mania difficulties become Circles and Tiles.'),
            onTap: () => Navigator.pop(c, 'osz'),
          ),
          ListTile(
            leading: const Icon(Icons.inventory_2_outlined),
            title: const Text('Rhytmaniac song pack'),
            subtitle: const Text('A .rhpack.zip shared from another phone.'),
            onTap: () => Navigator.pop(c, 'pack'),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    switch (choice) {
      case 'song':
        await _import();
      case 'osz':
        await _importOsz();
      case 'pack':
        await _importPack();
    }
  }

  Future<void> _importOsz() async {
    // .osz has no registered type on most phones, so show every file.
    final file = await NativeBridge.instance.pickFile(const ['*/*']);
    if (file != null && mounted) await importOszFile(context, ref, file);
  }

  Future<void> _importPack() async {
    final file = await NativeBridge.instance.pickFile(const ['application/zip', 'application/octet-stream']);
    if (file != null && mounted) await importPackFile(context, ref, file);
  }

  bool _passesFilters(LibraryState lib, Song s, GameMode mode) {
    if (_shelf == _favorites && !s.favorite) return false;
    if (_shelf != null && _shelf != _favorites && !(ref.read(collectionsProvider)[_shelf]?.contains(s.id) ?? false)) return false;
    final minutes = s.durationMs / 60000;
    if (minutes < _minutes.start || (_minutes.end < _maxMinutes && minutes > _minutes.end)) return false;
    if (_stars != const RangeValues(0, _maxStars)) {
      final hi = _stars.end >= _maxStars ? double.infinity : _stars.end;
      if (!lib.mapsFor(s.id, mode).any((m) => m.stars >= _stars.start && m.stars <= hi)) return false;
    }
    return true;
  }

  List<Song> _sorted(LibraryState lib, GameMode mode) {
    final q = _query.trim().toLowerCase();
    final list = lib.songs
        .where((s) => q.isEmpty || s.title.toLowerCase().contains(q) || s.artist.toLowerCase().contains(q))
        .where((s) => _passesFilters(lib, s, mode))
        .toList();
    int cmp(Song a, Song b) => switch (_sort) {
          LibrarySort.added => a.addedAt.compareTo(b.addedAt),
          LibrarySort.title => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
          LibrarySort.bpm => a.bpm.compareTo(b.bpm),
          LibrarySort.stars => lib.maxStars(a.id, mode).compareTo(lib.maxStars(b.id, mode)),
          LibrarySort.played => a.playCount.compareTo(b.playCount),
        };
    list.sort((a, b) => _descending ? cmp(b, a) : cmp(a, b));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final lib = ref.watch(libraryProvider);
    final mode = ref.watch(modeProvider);
    final jobs = ref.watch(importProvider);
    final songs = _sorted(lib, mode);

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _chooseImport,
        backgroundColor: Palette.action,
        foregroundColor: Palette.onAction,
        icon: const Icon(Icons.add_rounded),
        label: Text('Import', style: AppText.body(15, weight: 650, color: Palette.onAction)),
      ),
      body: SafeArea(
        bottom: false,
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _header(context, lib, mode)),
            if (jobs.isNotEmpty)
              SliverList.list(children: [for (final j in jobs) _ImportCard(job: j)]),
            if (lib.songs.isEmpty && jobs.isEmpty)
              SliverFillRemaining(hasScrollBody: false, child: _EmptyLibrary(onImport: _chooseImport))
            else if (songs.isEmpty && _query.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text('No songs match “$_query”.', style: AppText.body(15, color: Palette.mist), textAlign: TextAlign.center),
                ),
              )
            else if (songs.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(children: [
                    Text(
                      _shelf == _favorites && !_filtering
                          ? 'No favorites yet. Star a song on its page.'
                          : 'No songs here with these filters.',
                      style: AppText.body(15, color: Palette.mist),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: () => setState(() {
                        _shelf = null;
                        _stars = const RangeValues(0, _maxStars);
                        _minutes = const RangeValues(0, _maxMinutes);
                      }),
                      child: const Text('Show all songs'),
                    ),
                  ]),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(Space.gutter, 4, Space.gutter, 96),
                sliver: SliverList.separated(
                  itemCount: songs.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, i) => _SongCard(song: songs[i], mode: mode),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, LibraryState lib, GameMode mode) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.gutter, 14, 8, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text('Rhytmaniac', style: AppText.display(30, width: 150, weight: 850, letterSpacing: -1)),
                ),
              ),
              IconButton(
                tooltip: 'Random song',
                onPressed: lib.songs.isEmpty ? null : () => _random(lib, mode),
                icon: const Icon(Icons.shuffle_rounded),
              ),
              IconButton(
                tooltip: 'Search',
                onPressed: () => setState(() {
                  _searching = !_searching;
                  if (!_searching) _query = '';
                }),
                icon: Icon(_searching ? Icons.close_rounded : Icons.search_rounded),
              ),
              PopupMenuButton<String>(
                tooltip: 'More',
                icon: const Icon(Icons.more_vert_rounded),
                color: Palette.raised,
                onSelected: (v) {
                  if (v == 'pack') _importPack();
                  if (v == 'osz') _importOsz();
                  if (v == 'demo') ref.read(importProvider.notifier).installDemo();
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'osz', child: Text('Import osu! beatmap…')),
                  const PopupMenuItem(value: 'pack', child: Text('Import song pack…')),
                  if (!lib.songs.any((s) => s.isDemo)) const PopupMenuItem(value: 'demo', child: Text('Add demo song')),
                ],
              ),
            ],
          ),
          Text(
            lib.songs.isEmpty ? 'Your songs, mapped automatically' : '${lib.songs.length} song${lib.songs.length == 1 ? '' : 's'} · ${lib.beatmaps.length} difficulties',
            style: AppText.body(13.5, color: Palette.mist),
          ),
          if (_searching) ...[
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextField(
                autofocus: true,
                onChanged: (v) => setState(() => _query = v),
                decoration: const InputDecoration(hintText: 'Search title or artist', prefixIcon: Icon(Icons.search_rounded, size: 20)),
              ),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              ModeSwitch(mode: mode, onChanged: (m) => ref.read(modeProvider.notifier).set(m)),
              const Spacer(),
              IconButton(
                tooltip: 'Filters',
                onPressed: _openFilters,
                icon: Badge(
                  isLabelVisible: _filtering,
                  backgroundColor: Palette.amber,
                  smallSize: 7,
                  child: const Icon(Icons.filter_list_rounded),
                ),
              ),
              PopupMenuButton<LibrarySort>(
                tooltip: 'Sort',
                color: Palette.raised,
                onSelected: (s) => setState(() {
                  if (s == _sort) {
                    _descending = !_descending;
                  } else {
                    _sort = s;
                    _descending = s != LibrarySort.title;
                  }
                }),
                itemBuilder: (_) => [
                  for (final s in LibrarySort.values)
                    PopupMenuItem(
                      value: s,
                      child: Row(children: [
                        Expanded(child: Text(s.label)),
                        if (s == _sort) Icon(_descending ? Icons.south_rounded : Icons.north_rounded, size: 16, color: Palette.amber),
                      ]),
                    ),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                  child: Row(children: [
                    Icon(Icons.sort_rounded, size: 18, color: Palette.mist),
                    const SizedBox(width: 6),
                    Text(_sort.label, style: AppText.body(13.5, weight: 550, color: Palette.mist)),
                  ]),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          _shelves(lib),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  /// All songs, favorites and the player's collections.
  Widget _shelves(LibraryState lib) {
    final collections = ref.watch(collectionsProvider);
    final names = collections.keys.toList()..sort();
    final have = {for (final s in lib.songs) s.id};
    if (names.isEmpty && !lib.songs.any((s) => s.favorite) && _shelf == null) return const SizedBox.shrink();
    Widget chip(String label, String? value, {IconData? icon}) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: GestureDetector(
            onLongPress: value == null || value == _favorites ? null : () => _editCollection(value),
            child: ChoiceChip(
              avatar: icon == null ? null : Icon(icon, size: 16),
              label: Text(label),
              selected: _shelf == value,
              onSelected: (_) => setState(() => _shelf = value),
            ),
          ),
        );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        chip('All', null),
        chip('Favorites', _favorites, icon: Icons.star_rounded),
        for (final n in names) chip('$n · ${collections[n]!.where(have.contains).length}', n),
      ]),
    );
  }

  Future<void> _editCollection(String name) async {
    final c = TextEditingController(text: name);
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Collection'),
        content: TextField(controller: c, autofocus: true, decoration: const InputDecoration(hintText: 'Name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 'delete'), child: const Text('Delete')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, 'rename'), child: const Text('Rename')),
        ],
      ),
    );
    final notifier = ref.read(collectionsProvider.notifier);
    if (r == 'delete') {
      await notifier.delete(name);
      if (_shelf == name) setState(() => _shelf = null);
    } else if (r == 'rename' && c.text.trim().isNotEmpty && c.text.trim() != name) {
      await notifier.rename(name, c.text.trim());
      if (_shelf == name) setState(() => _shelf = c.text.trim());
    }
  }

  Future<void> _openFilters() async {
    var stars = _stars, minutes = _minutes;
    String fmtStars(double v) => v >= _maxStars ? '${_maxStars.round()}+★' : '${v.toStringAsFixed(1)}★';
    String fmtMin(double v) => v >= _maxMinutes ? '${_maxMinutes.round()}+ min' : '${v.toStringAsFixed(1)} min';
    final ok = await showModalBottomSheet<bool>(
      context: context,
      builder: (c) => StatefulBuilder(builder: (c, set) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, 12),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Filters', style: AppText.display(22, width: 120, weight: 800)),
              const SizedBox(height: 14),
              Row(children: [
                Text('Stars', style: AppText.body(15, weight: 600)),
                const Spacer(),
                Text('${fmtStars(stars.start)} – ${fmtStars(stars.end)}', style: AppText.data(13, color: Palette.bone)),
              ]),
              RangeSlider(values: stars, min: 0, max: _maxStars, divisions: 32, onChanged: (v) => set(() => stars = v)),
              Text('A song shows when one of its maps in this mode is in range.', style: AppText.body(12, color: Palette.mist)),
              const SizedBox(height: 14),
              Row(children: [
                Text('Length', style: AppText.body(15, weight: 600)),
                const Spacer(),
                Text('${fmtMin(minutes.start)} – ${fmtMin(minutes.end)}', style: AppText.data(13, color: Palette.bone)),
              ]),
              RangeSlider(values: minutes, min: 0, max: _maxMinutes, divisions: 20, onChanged: (v) => set(() => minutes = v)),
              const SizedBox(height: 8),
              Row(children: [
                TextButton(
                  onPressed: () => set(() {
                    stars = const RangeValues(0, _maxStars);
                    minutes = const RangeValues(0, _maxMinutes);
                  }),
                  child: const Text('Reset'),
                ),
                const Spacer(),
                FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Apply')),
              ]),
            ]),
          ),
        );
      }),
    );
    if (ok == true) {
      setState(() {
        _stars = stars;
        _minutes = minutes;
      });
    }
  }

  /// Opens a random song from what the library currently shows.
  void _random(LibraryState lib, GameMode mode) {
    final pool = _sorted(lib, mode);
    final from = pool.isEmpty ? lib.songs : pool;
    final song = from[math.Random().nextInt(from.length)];
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => SongScreen(songId: song.id)));
  }
}

class _SongCard extends ConsumerWidget {
  const _SongCard({required this.song, required this.mode});
  final Song song;
  final GameMode mode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lib = ref.watch(libraryProvider);
    final paths = ref.read(servicesProvider).paths;
    final maps = lib.mapsFor(song.id, mode);
    return Material(
      color: Palette.surface,
      borderRadius: BorderRadius.circular(Space.radius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => SongScreen(songId: song.id))),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SongArt(song: song, coverPath: song.coverFile == null ? null : paths.coverFile(song.id, song.coverFile!), size: 52),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          if (song.favorite) ...[
                            const Icon(Icons.star_rounded, size: 16, color: Palette.amber),
                            const SizedBox(width: 4),
                          ],
                          Flexible(
                            child: Text(song.title,
                                maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.display(17, width: 108, weight: 720, letterSpacing: -0.2)),
                          ),
                        ]),
                        const SizedBox(height: 3),
                        Text(song.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body(13, color: Palette.mist)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('${song.bpm.round()} BPM', style: AppText.data(11.5, color: Palette.bone)),
                      const SizedBox(height: 4),
                      Text(formatDuration(song.durationMs), style: AppText.data(11)),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 10),
              SignalStrip(fingerprint: song.fingerprint, height: 26),
              const SizedBox(height: 10),
              Row(
                children: [
                  if (maps.isEmpty)
                    Text('No ${mode.label} difficulties yet', style: AppText.body(12.5, color: Palette.dim))
                  else
                    Expanded(
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [for (final m in maps.take(7)) StarBadge(m.stars, compact: true)],
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ImportCard extends ConsumerWidget {
  const _ImportCard({required this.job});
  final ImportJob job;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = job.progress;
    final failed = p.stage == ImportStage.failed;
    final done = p.stage == ImportStage.done;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.gutter, 4, Space.gutter, 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        decoration: BoxDecoration(
          color: Palette.surface,
          borderRadius: BorderRadius.circular(Space.radius),
          border: Border.all(color: failed ? Palette.danger.withValues(alpha: 0.5) : Palette.line),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.title ?? 'Importing', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body(14.5, weight: 600)),
                  const SizedBox(height: 4),
                  Text(
                    failed ? (p.error ?? 'Import failed') : done ? 'Ready to play' : '${p.stage.label}…',
                    style: AppText.body(12.5, color: failed ? Palette.danger : Palette.mist),
                  ),
                  if (!failed && !done) ...[
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(value: p.progress.clamp(0.02, 1.0), minHeight: 4),
                    ),
                  ],
                ],
              ),
            ),
            if (failed || done)
              IconButton(
                tooltip: 'Dismiss',
                onPressed: () => ref.read(importProvider.notifier).dismiss(job.id),
                icon: const Icon(Icons.close_rounded, size: 20),
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text('${(p.progress * 100).round()}%', style: AppText.data(12, color: Palette.bone)),
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({required this.onImport});
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 120),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 220,
            child: SignalStrip(
              fingerprint: [for (var i = 0; i < 28; i++) [0.3 + 0.5 * ((i * 7) % 11) / 11, 0.2 + 0.6 * ((i * 5) % 9) / 9, 0.1 + 0.4 * ((i * 3) % 7) / 7]],
              height: 64,
              opacity: 0.8,
            ),
          ),
          const SizedBox(height: 28),
          Text('Bring your own music', style: AppText.display(24, width: 125, weight: 800), textAlign: TextAlign.center),
          const SizedBox(height: 10),
          Text(
            'Import an MP4, MP3, M4A or WAV from your phone. Rhytmaniac finds the beat and builds Tiles and Circles maps from Easy to Expert. osu! beatmap sets (.osz) work too.',
            style: AppText.body(14.5, color: Palette.mist),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          FilledButton.icon(onPressed: onImport, icon: const Icon(Icons.add_rounded), label: const Text('Import')),
        ],
      ),
    );
  }
}
