/// The four-line stripe — Azul/Amarela/Verde/Vermelha side by side.
/// The app's signature motif (born in the splash "platform"): used as a
/// header accent, divider, and brand mark.
import 'package:flutter/material.dart';

import 'models.dart';

class LineStripe extends StatelessWidget {
  final double height;
  final double gap;
  final double? width; // null = expand to parent width
  final List<String>? lines; // null = all four; pass a subset to scope it

  const LineStripe({super.key, this.height = 4, this.gap = 3, this.width, this.lines});

  @override
  Widget build(BuildContext context) {
    final stripe = Row(
      children: [
        for (final (i, line) in (lines ?? lineOrder).indexed) ...[
          if (i > 0) SizedBox(width: gap),
          Expanded(
            child: Container(
              height: height,
              decoration: BoxDecoration(
                color: Color(lineColors[line]!),
                borderRadius: BorderRadius.circular(height / 2),
              ),
            ),
          ),
        ],
      ],
    );
    return width == null ? stripe : SizedBox(width: width, child: stripe);
  }
}

/// A panel header with the stripe underneath — keeps every panel on-brand.
class StripeHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final Widget? trailing;
  final List<String>? lines; // null = all four; scope it to a train/station's lines

  const StripeHeader({
    super.key,
    required this.icon,
    required this.title,
    this.trailing,
    this.lines,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(icon, color: Colors.black87, size: 22),
            const SizedBox(width: 8),
            Expanded(
              child: Text(title,
                  style: const TextStyle(
                      color: Colors.black87, fontSize: 20, fontWeight: FontWeight.w800)),
            ),
            if (trailing != null) trailing!,
          ],
        ),
        const SizedBox(height: 10),
        LineStripe(lines: lines),
      ],
    );
  }
}
