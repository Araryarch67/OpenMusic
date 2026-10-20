import 'dart:async';
import 'dart:ffi';
import 'dart:io';

/// Hands memory freed by the engine, mpv and FFmpeg back to the OS.
///
/// glibc keeps freed blocks in its per-thread arenas for reuse, so after a
/// song change or a long scroll the process stays at its peak size.
/// `malloc_trim` releases what's free; it takes a few milliseconds.
/// Linux (glibc) only; elsewhere this does nothing.
abstract final class MemoryTrim {
  static final int Function(int)? _trim = () {
    if (!Platform.isLinux) return null;
    try {
      return DynamicLibrary.process().lookupFunction<Int32 Function(IntPtr), int Function(int)>('malloc_trim');
    } catch (_) {
      return null; // not glibc (e.g. musl)
    }
  }();

  static Timer? _soon;
  static Timer? _every;

  /// Trims a few seconds from now (after a song change has settled), and
  /// once a minute from then on.
  static void schedule() {
    final trim = _trim;
    if (trim == null) return;
    _every ??= Timer.periodic(const Duration(minutes: 1), (_) => trim(0));
    _soon?.cancel();
    _soon = Timer(const Duration(seconds: 4), () => trim(0));
  }

  static void stop() {
    _soon?.cancel();
    _every?.cancel();
    _soon = _every = null;
  }
}
