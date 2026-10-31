// alert renderer — severity banners
// ported from openpilot selfdrive/ui/onroad/alert_renderer.py
//
// three sizes: small (single line), mid (title + subtitle), full (big text).
// three severities: normal (dark), userPrompt (orange), critical (red).

import 'package:flutter/material.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';

// -- constants (alert_renderer.py:16-28) --

const _alertMargin = 40.0;
const _alertPadding = 60.0;
const _alertBorderRadius = 30.0;
const _alertLineSpacing = 45.0;

const _alertFontSmall = 66.0;
const _alertFontMedium = 74.0;
const _alertFontBig = 88.0;

const _alertHeightSmall = 271.0;
const _alertHeightMid = 420.0;

// alert size enum values from cereal
const _sizeNone = 0;
const _sizeSmall = 1;
const _sizeFull = 3;

// status enum values from cereal
const _statusNormal = 0;
const _statusUserPrompt = 1;
const _statusCritical = 2;

// -- colors (alert_renderer.py:34-38) --

const _alertColors = {
  _statusNormal: Color(0xF1151515),
  _statusUserPrompt: Color(0xF1DA6F25),
  _statusCritical: Color(0xF1C92231),
};

class AlertRenderer extends StatelessWidget {
  final UIState uiState;
  final double scale;
  /// 儀表介面用：small / mid 字級 ×0.85、黑底寬度貼合文字（置中），高度同比例縮。
  /// false = 完全照 stock（原版介面）。full alert 一律照 stock 全螢幕。
  final bool compact;
  /// 高度依字級決定（只包住文字 + 上下內距），不用 stock 的固定高度。
  /// 直向道路畫面較矮，固定高度會蓋掉太多畫面。只對 small / mid 有效。
  final bool fitHeight;

  const AlertRenderer({super.key, required this.uiState, required this.scale,
    this.compact = false, this.fitHeight = false});

  static const compactFactor = .85;
  double get _k => compact ? compactFactor : 1.0;

  @override
  Widget build(BuildContext context) {
    if (uiState.alertSize == _sizeNone) return const SizedBox.shrink();

    final bgColor = _alertColors[uiState.alertStatus] ?? _alertColors[_statusNormal]!;
    final size = uiState.alertSize;

    if (size == _sizeFull) return _fullAlert(bgColor);

    // small or mid: positioned at bottom
    final h = (size == _sizeSmall ? _alertHeightSmall : _alertHeightMid) * scale;
    final m = _alertMargin * scale;

    if (fitHeight) {
      // 高度跟文字走：上下內距 = 字級 0.3 倍，貼道路畫面底部、水平置中
      final fs = (size == _sizeSmall ? _alertFontMedium : _alertFontBig) * scale * _k;
      return Positioned(
        left: m, right: m, bottom: m,
        child: Align(alignment: Alignment.bottomCenter, child: Container(
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(_alertBorderRadius * scale * _k),
          ),
          padding: EdgeInsets.symmetric(horizontal: _alertPadding * scale * _k, vertical: fs * .3),
          child: size == _sizeSmall ? _smallContent() : _midContent(),
        )),
      );
    }

    if (compact) {
      // 寬度跟文字走：Align 給寬鬆約束，Container 依內容決定寬度，最寬不超過左右 margin
      final ch = (h - 2 * m) * _k;
      return Positioned(
        left: m, right: m, bottom: m, height: ch,
        child: Align(alignment: Alignment.bottomCenter, child: Container(
          height: ch,
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(_alertBorderRadius * scale * _k),
          ),
          padding: EdgeInsets.symmetric(horizontal: _alertPadding * scale * _k),
          child: size == _sizeSmall ? _smallContent() : _midContent(),
        )),
      );
    }

    return Positioned(
      left: m,
      right: m,
      bottom: m,
      height: h - 2 * m,
      child: Container(
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(_alertBorderRadius * scale),
        ),
        padding: EdgeInsets.symmetric(horizontal: _alertPadding * scale),
        child: size == _sizeSmall ? _smallContent() : _midContent(),
      ),
    );
  }

  /// single bold line, centered
  Widget _smallContent() {
    return Center(
      widthFactor: compact ? 1 : null,   // compact：寬度貼合文字，不撐滿
      child: Text(uiState.alertText1,
        style: TextStyle(
          color: Colors.white,
          fontSize: _alertFontMedium * scale * _k,
          fontWeight: FontWeight.bold,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }

  /// title + subtitle
  Widget _midContent() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: compact || fitHeight ? MainAxisSize.min : MainAxisSize.max,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(uiState.alertText1,
          style: TextStyle(
            color: Colors.white,
            fontSize: _alertFontBig * scale * _k,
            fontWeight: FontWeight.bold,
          ),
          textAlign: TextAlign.center,
        ),
        // fitHeight：標題與副標行距縮成 stock 的 30%（高度只包住文字）
        SizedBox(height: _alertLineSpacing * scale * _k * (fitHeight ? .3 : 1)),
        Text(uiState.alertText2,
          style: TextStyle(
            color: Colors.white,
            fontSize: _alertFontSmall * scale * _k,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  /// full screen alert
  Widget _fullAlert(Color bgColor) {
    final isLong = uiState.alertText1.length > 15;
    final fontSize1 = (isLong ? 132.0 : 177.0) * scale;

    return Positioned.fill(
      child: Container(
        color: bgColor,
        padding: EdgeInsets.all(_alertPadding * scale),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Spacer(flex: 2),
            Text(uiState.alertText1,
              style: TextStyle(
                color: Colors.white,
                fontSize: fontSize1,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const Spacer(),
            Text(uiState.alertText2,
              style: TextStyle(
                color: Colors.white,
                fontSize: _alertFontBig * scale,
              ),
              textAlign: TextAlign.center,
            ),
            const Spacer(flex: 2),
          ],
        ),
      ),
    );
  }
}
