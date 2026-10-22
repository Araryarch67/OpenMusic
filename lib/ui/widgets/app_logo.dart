import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// OpenMusic's mark, drawn from the same shapes as the app icon
/// (assets/icon/openmusic-transparent.svg). The light parts take the theme's
/// text colour, so the mark reads on light themes too; the orange stays.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 16});

  final double size;

  static const orange = Color(0xFFFF7A1A);

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(painter: _LogoPainter(AppColors.textPrimary)),
  );
}

class _LogoPainter extends CustomPainter {
  _LogoPainter(this.light);

  final Color light;

  // The design's 1440-unit square; the mark spans x 368…1111, y 328…1111.
  static const _left = 368.0, _top = 328.0, _right = 1111.0, _bottom = 1111.0;
  static const _radius = 94.0; // the left chevron's rounded tip

  @override
  void paint(Canvas canvas, Size size) {
    final k = math.min(size.width / (_right - _left), size.height / (_bottom - _top));
    canvas
      ..translate((size.width - (_right - _left) * k) / 2, (size.height - (_bottom - _top) * k) / 2)
      ..scale(k)
      ..translate(-_left, -_top);
    Path poly(List<Offset> points) => Path()..addPolygon(points, true);
    final white = Paint()..color = light;

    canvas
      ..drawPath(poly(const [Offset(720, 328), Offset(831, 439.5), Offset(720, 551), Offset(609, 439.5)]), white)
      ..drawPath(poly(const [Offset(720, 888), Offset(831, 999.5), Offset(720, 1111), Offset(609, 999.5)]), white);

    // Left chevron: its outer corner (328.5, 719.5) rounded off.
    final t = _radius / math.sqrt2;
    final cx = 328.5 + _radius * math.sqrt2;
    canvas.drawPath(
      Path()
        ..moveTo(580, 468)
        ..lineTo(691, 579.5)
        ..lineTo(552, 719.5)
        ..lineTo(691, 859.5)
        ..lineTo(580, 971)
        ..lineTo(cx - t, 719.5 + t)
        ..arcToPoint(Offset(cx - t, 719.5 - t), radius: const Radius.circular(_radius))
        ..close(),
      white,
    );
    canvas.drawPath(
      poly(const [
        Offset(859, 468),
        Offset(1111, 719.5),
        Offset(859, 971),
        Offset(748, 859.5),
        Offset(887, 719.5),
        Offset(748, 579.5),
      ]),
      Paint()..color = AppLogo.orange,
    );
  }

  @override
  bool shouldRepaint(_LogoPainter old) => old.light != light;
}
