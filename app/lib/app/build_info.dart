/// Build identity, stamped by CI with `--dart-define` (see
/// `.github/workflows/build-apk.yml`). Local builds show "local".
class BuildInfo {
  static const gitSha = String.fromEnvironment('GIT_SHA', defaultValue: 'local');
  static const gitRef = String.fromEnvironment('GIT_REF', defaultValue: 'local');
  static const buildNumber = String.fromEnvironment('BUILD_NUMBER', defaultValue: '0');

  static String get shortSha => gitSha.length > 7 ? gitSha.substring(0, 7) : gitSha;

  /// e.g. "build 42 · a1b2c3d · main"
  static String get label => 'build $buildNumber · $shortSha · $gitRef';
}
