import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../data/settings.dart';
import '../../platform/native_bridge.dart';
import '../../state/providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'calibration_screen.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    void set(AppSettings v) => ref.read(settingsProvider.notifier).update(v);

    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, 18, Space.gutter, 0),
            child: Text('Settings', style: AppText.display(30, width: 140, weight: 850)),
          ),
          const SectionLabel('Timing'),
          _Tile(
            title: 'Audio offset',
            subtitle: 'Shifts judgments to match when you hear the music. Calibrate once per pair of headphones.',
            trailing: Text('${s.globalOffsetMs >= 0 ? '+' : ''}${s.globalOffsetMs.round()} ms', style: AppText.data(14, color: Palette.bone)),
          ),
          _SliderRow(
            value: s.globalOffsetMs.clamp(-300, 300),
            min: -300,
            max: 300,
            divisions: 600,
            onChanged: (v) => set(s.copyWith(globalOffsetMs: v.roundToDouble())),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            child: Row(children: [
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CalibrationScreen())),
                icon: const Icon(Icons.graphic_eq_rounded),
                label: const Text('Calibrate'),
              ),
              const SizedBox(width: 8),
              TextButton(onPressed: () => set(s.copyWith(globalOffsetMs: 0)), child: const Text('Reset')),
            ]),
          ),
          const SectionLabel('Gameplay'),
          _Tile(
            title: 'Tiles scroll speed',
            subtitle: 'Multiplies each map’s speed. Stays the same when the song is sped up.',
            trailing: Text('${s.scrollSpeed.toStringAsFixed(2)}×', style: AppText.data(14, color: Palette.bone)),
          ),
          _SliderRow(
            value: s.scrollSpeed,
            min: 0.5,
            max: 2.5,
            divisions: 40,
            onChanged: (v) => set(s.copyWith(scrollSpeed: (v * 20).round() / 20)),
          ),
          _Tile(
            title: 'Default lanes',
            subtitle: 'Used for newly imported songs',
            trailing: SegmentedButton<int>(
              segments: [for (var l = 3; l <= 6; l++) ButtonSegment(value: l, label: Text('$l'))],
              selected: {s.defaultLanes},
              showSelectedIcon: false,
              onSelectionChanged: (v) => set(s.copyWith(defaultLanes: v.first)),
            ),
          ),
          _Tile(
            title: 'Judgment text',
            subtitle: 'Minimal shows misses only',
            trailing: SegmentedButton<JudgmentDisplay>(
              segments: [for (final j in JudgmentDisplay.values) ButtonSegment(value: j, label: Text(j.label))],
              selected: {s.judgmentDisplay},
              showSelectedIcon: false,
              onSelectionChanged: (v) => set(s.copyWith(judgmentDisplay: v.first)),
            ),
          ),
          _Switch('Hit error bar', 'Early and late ticks while you play', s.showHitErrorBar, (v) => set(s.copyWith(showHitErrorBar: v))),
          _Switch('FPS counter', 'For checking performance', s.showFps, (v) => set(s.copyWith(showFps: v))),
          const SectionLabel('Sound and feel'),
          _Tile(title: 'Music volume', trailing: Text('${(s.musicVolume * 100).round()}%', style: AppText.data(14, color: Palette.bone))),
          _SliderRow(value: s.musicVolume, min: 0, max: 1, divisions: 20, onChanged: (v) => set(s.copyWith(musicVolume: v))),
          _Switch('Song preview', 'Play a bit of the song on its page', s.previewMusic, (v) => set(s.copyWith(previewMusic: v))),
          _Switch('Hit sounds', 'A short tick on every hit', s.hitSounds, (v) => set(s.copyWith(hitSounds: v))),
          if (s.hitSounds) ...[
            _Tile(title: 'Hit sound volume', trailing: Text('${(s.hitSoundVolume * 100).round()}%', style: AppText.data(14, color: Palette.bone))),
            _SliderRow(value: s.hitSoundVolume, min: 0, max: 1, divisions: 20, onChanged: (v) => set(s.copyWith(hitSoundVolume: v))),
          ],
          _Switch('Haptics', 'Vibrate lightly on hits', s.haptics, (v) => set(s.copyWith(haptics: v))),
          const SectionLabel('Exports'),
          _Tile(
            title: 'Save exports to',
            subtitle: s.exportFolderUri == null ? 'Download/Rhytmaniac' : s.exportFolderName ?? 'Chosen folder',
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (s.exportFolderUri != null)
                TextButton(onPressed: () => set(s.copyWith(clearExportFolder: true)), child: const Text('Reset')),
              TextButton(
                onPressed: () async {
                  final f = await NativeBridge.instance.pickFolder();
                  if (f != null) set(s.copyWith(exportFolderUri: f.uri, exportFolderName: f.name));
                },
                child: const Text('Change'),
              ),
            ]),
          ),
          const SectionLabel('About'),
          FutureBuilder<PackageInfo>(
            future: PackageInfo.fromPlatform(),
            builder: (context, snap) {
              final version = snap.hasData ? displayVersion(snap.data!) : '…';
              return _Tile(
                title: 'Rhytmaniac',
                subtitle: '$version · Fonts: Anybody, Instrument Sans, Martian Mono (SIL Open Font License)',
                trailing: TextButton(
                  onPressed: () => showLicensePage(context: context, applicationName: 'Rhytmaniac', applicationVersion: version),
                  child: const Text('Licenses'),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.title, this.subtitle, this.trailing});
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(Space.gutter, 8, Space.gutter, 4),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: AppText.body(15, weight: 600)),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(subtitle!, style: AppText.body(12.5, color: Palette.mist)),
              ],
            ]),
          ),
          if (trailing != null) ...[const SizedBox(width: 12), trailing!],
        ]),
      );
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({required this.value, required this.min, required this.max, required this.onChanged, this.divisions});
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Slider(value: value.clamp(min, max), min: min, max: max, divisions: divisions, onChanged: onChanged),
      );
}

class _Switch extends StatelessWidget {
  const _Switch(this.title, this.subtitle, this.value, this.onChanged);
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => SwitchListTile(
        value: value,
        onChanged: onChanged,
        contentPadding: const EdgeInsets.symmetric(horizontal: Space.gutter),
        title: Text(title, style: AppText.body(15, weight: 600)),
        subtitle: Text(subtitle, style: AppText.body(12.5, color: Palette.mist)),
      );
}

/// "v1.4 (build 57)" from the installed package. Release builds carry the
/// x.y version that CI assigned; the trailing ".0" is dropped.
String displayVersion(PackageInfo info) {
  final v = info.version.endsWith('.0') ? info.version.substring(0, info.version.length - 2) : info.version;
  return 'v$v (build ${info.buildNumber})';
}
