// Adapted from Rivian ThrottledByVersion. Cache only presentation widgets;
// caller invalidates immediately on alerts, status, stale data or local settings.
import 'package:flutter/widgets.dart';

class ThrottledHud extends StatefulWidget {
  final int version, every;
  final Object invalidateKey;
  final Widget Function() builder;
  const ThrottledHud({super.key, required this.version, required this.every,
    required this.invalidateKey, required this.builder});
  @override
  State<ThrottledHud> createState() => _ThrottledHudState();
}
class _ThrottledHudState extends State<ThrottledHud> {
  Widget? _child;
  int _builtAt = 0;
  Object? _key;
  int? _every;
  @override
  void didChangeDependencies() { super.didChangeDependencies(); _child = null; }
  @override
  Widget build(BuildContext context) {
    final delta = widget.version - _builtAt;
    if (_child == null || _key != widget.invalidateKey || _every != widget.every ||
        delta < 0 || delta >= widget.every) {
      _builtAt = widget.version; _key = widget.invalidateKey; _every = widget.every;
      _child = RepaintBoundary(child: widget.builder());
    }
    return _child!;
  }
}
