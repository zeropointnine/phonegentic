import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class Add2CallIcon extends StatelessWidget {
  final double size;
  final Color color;

  const Add2CallIcon({
    super.key,
    this.size = 48,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      'assets/phone_plus.svg',
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    );
  }
}
