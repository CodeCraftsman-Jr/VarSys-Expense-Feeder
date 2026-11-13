import 'package:flutter/material.dart';

import '../core/theme/palette.dart';

/// The VarSys mark as the app icon draws it: a blue "V" with a light notch on
/// the VarSys navy tile. Same geometry and colours as the launcher icon
/// (tool/gen_brand_assets.js, assets/branding/varsys-icon.svg).
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 96});
  final double size;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(size * 0.28),
    child: SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _MarkPainter()),
    ),
  );
}

class _MarkPainter extends CustomPainter {
  // The favicon's 64-unit grid, mapped into the unit square the same way as
  // the icon generator (centred on the circle through the three tips).
  static const _k = 0.688, _cy = 27.95;
  static const _blue = Color(0xFF3D7BFF), _notch = Color(0xFF9DBBFF);

  static Offset _u(double x, double y) => Offset(0.5 + (x - 32) / 64 * _k, 0.5 + (y - _cy) / 64 * _k);

  static Path _poly(List<Offset> pts) => Path()..addPolygon(pts, true);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Palette.brandNavy);
    canvas.save();
    // Like the launcher, which shows the inner 72dp of the 108dp canvas.
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(size.shortestSide * 1.4);
    canvas.translate(-0.5, -0.5);
    canvas.drawPath(
      _poly([_u(10, 14), _u(22, 14), _u(32, 34), _u(42, 14), _u(54, 14), _u(32, 54)]),
      Paint()..color = _blue,
    );
    canvas.drawPath(_poly([_u(27, 14), _u(37, 14), _u(32, 24)]), Paint()..color = _notch);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
