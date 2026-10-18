import 'package:flutter/widgets.dart';

import '../models/track.dart';

/// Layout facts and navigation actions the pages need from the app shell.
class ShellScope extends InheritedWidget {
  const ShellScope({
    super.key,
    required this.compact,
    required this.width,
    required this.open,
    required this.openCollection,
    required this.openQueue,
    required this.openNowPlaying,
    required this.openDownloads,
    required this.importFromYoutube,
    required this.addFiles,
    required this.addFolder,
    required super.child,
  });

  /// Phone layout (bottom tabs + mini player).
  final bool compact;

  /// Width of the content area, for column decisions inside pages.
  final double width;

  final void Function(Widget page) open;
  final void Function(Collection collection) openCollection;
  final VoidCallback openQueue;
  final VoidCallback openNowPlaying;
  final VoidCallback openDownloads;

  /// Opens the paste-a-link sheet / dialog.
  final VoidCallback importFromYoutube;
  final VoidCallback addFiles;

  /// Null where folders can't be scanned (mobile).
  final VoidCallback? addFolder;

  static ShellScope of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ShellScope>()!;

  @override
  bool updateShouldNotify(ShellScope old) => compact != old.compact || width != old.width;
}
