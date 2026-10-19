import 'package:flutter/material.dart';

/// Mouse-wheel scrolling that glides instead of jumping a notch at a time.
///
/// Flutter applies each wheel tick instantly on desktop, which reads as
/// stutter. Positions from this controller animate to the target instead, and
/// ticks that arrive mid-animation extend it, so a fast spin stays fluid.
/// Touch, trackpad and scrollbar drags behave exactly as before.
class SmoothScrollController extends ScrollController {
  SmoothScrollController({super.initialScrollOffset, super.keepScrollOffset, super.debugLabel});

  @override
  ScrollPosition createScrollPosition(ScrollPhysics physics, ScrollContext context, ScrollPosition? oldPosition) =>
      _SmoothScrollPosition(
        physics: physics,
        context: context,
        initialPixels: initialScrollOffset,
        keepScrollOffset: keepScrollOffset,
        oldPosition: oldPosition,
        debugLabel: debugLabel,
      );
}

class _SmoothScrollPosition extends ScrollPositionWithSingleContext {
  _SmoothScrollPosition({
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  /// Where the running wheel animation is headed.
  double? _target;

  static const _duration = Duration(milliseconds: 260);

  @override
  void pointerScroll(double delta) {
    if (delta == 0.0) return super.pointerScroll(delta);
    final animating = _target != null && activity is DrivenScrollActivity;
    final from = animating ? _target! : pixels;
    final target = (from + delta).clamp(minScrollExtent, maxScrollExtent);
    if (target == from) return;
    _target = target;
    animateTo(target, duration: _duration, curve: Curves.easeOutCubic).whenComplete(() {
      if (_target == target) _target = null;
    });
  }
}

/// Owns a [SmoothScrollController] for stateless widgets that build a scroll view.
class SmoothScroll extends StatefulWidget {
  const SmoothScroll({super.key, required this.builder});

  final Widget Function(BuildContext context, ScrollController controller) builder;

  @override
  State<SmoothScroll> createState() => _SmoothScrollState();
}

class _SmoothScrollState extends State<SmoothScroll> {
  final _controller = SmoothScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _controller);
}

/// Fades (and lifts slightly) its child in the first time it is built: for
/// content that arrives after a load, so it doesn't just pop into place.
class FadeIn extends StatelessWidget {
  const FadeIn({super.key, required this.child, this.delay = Duration.zero, this.offset = 12});

  final Widget child;
  final Duration delay;

  /// Starting distance below the final position, in pixels.
  final double offset;

  @override
  Widget build(BuildContext context) {
    final total = const Duration(milliseconds: 320) + delay;
    final start = delay.inMicroseconds / total.inMicroseconds;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: total,
      curve: Interval(start, 1, curve: Curves.easeOutCubic),
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, (1 - t) * offset), child: child),
      ),
      child: child,
    );
  }
}
