import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

/// Hands memory freed by the engine, mpv and FFmpeg back to the OS.
///
/// glibc keeps freed blocks in its per-thread arenas for reuse, so after a
/// song change or a long scroll the process stays at its peak size.
/// `malloc_trim` releases what's free. It walks every arena, which can take
/// a while in a big process, so it runs in a background isolate rather than
/// on the UI thread. Linux (glibc) only; elsewhere this does nothing.
abstract final class MemoryTrim {
  static int Function(int)? _lookup() {
    try {
      return DynamicLibrary.process().lookupFunction<Int32 Function(IntPtr), int Function(int)>('malloc_trim');
    } catch (_) {
      return null; // not glibc (e.g. musl)
    }
  }

  // Not in widget tests either: their fake clock fails on timers left running.
  static final bool _available =
      Platform.isLinux && !Platform.environment.containsKey('FLUTTER_TEST') && _lookup() != null;

  static void _trim() => Isolate.run(() => _lookup()?.call(0)).ignore();

  static Timer? _soon;
  static Timer? _every;

  /// Trims a few seconds from now (after a song change has settled), and
  /// once a minute from then on.
  static void schedule() {
    if (!_available) return;
    _every ??= Timer.periodic(const Duration(minutes: 1), (_) => _trim());
    _soon?.cancel();
    _soon = Timer(const Duration(seconds: 4), _trim);
  }

  static void stop() {
    _soon?.cancel();
    _every?.cancel();
    _soon = _every = null;
  }
}
