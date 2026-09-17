import 'package:ai/recording_flow.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ScreenSize', () {
    test('parses physical wm size output', () {
      final size = ScreenSize.tryParseWmSizeOutput('Physical size: 1600x900');

      expect(size?.width, 1600);
      expect(size?.height, 900);
      expect(size?.isSupportedAutomationResolution, isTrue);
    });

    test('prefers override size over physical size', () {
      final size = ScreenSize.tryParseWmSizeOutput(
        'Physical size: 1920x1080\nOverride size: 900x1600',
      );

      expect(size?.width, 900);
      expect(size?.height, 1600);
      expect(size?.isSupportedAutomationResolution, isTrue);
    });

    test('rejects unsupported resolution', () {
      const size = ScreenSize(width: 1280, height: 720);

      expect(size.isSupportedAutomationResolution, isFalse);
    });

    test('scales recorded coordinates to playback resolution', () {
      const source = ScreenSize(width: 1600, height: 900);
      const target = ScreenSize(width: 900, height: 1600);

      expect(source.scalePointTo(x: 800, y: 450, target: target), (450, 800));
      expect(source.scalePointTo(x: 1600, y: 900, target: target), (900, 1600));
    });

    test('keeps coordinates unchanged when source size is unavailable', () {
      const source = ScreenSize(width: 0, height: 0);
      const target = ScreenSize(width: 900, height: 1600);

      expect(source.scalePointTo(x: 120, y: 240, target: target), (120, 240));
    });

    test('returns null for unrecognized wm size output', () {
      expect(ScreenSize.tryParseWmSizeOutput('unknown'), isNull);
    });
  });
}
