import 'dart:io';
import 'dart:typed_data';

import 'package:launch_at_startup/src/app_auto_launcher.dart';
import 'package:win32_registry/win32_registry.dart'
    if (dart.library.html) 'noop.dart';

bool isRunningInMsix(String packageName) {
  final String resolvedExecutable = Platform.resolvedExecutable;
  final bool isMsix =
      resolvedExecutable.contains('WindowsApps') &&
      resolvedExecutable.contains(packageName);
  return isMsix;
}

class AppAutoLauncherImplWindows extends AppAutoLauncher {
  AppAutoLauncherImplWindows({
    required super.appName,
    required String appPath,
    List<String> args = const [],
  }) : super(appPath: appPath, args: args) {
    final argsSuffix = args.isEmpty ? '' : ' ${args.join(' ')}';
    _registryValue = '"$appPath"$argsSuffix';
    _unquotedRegistryValue = '$appPath$argsSuffix';
  }

  late String _registryValue;

  // Unquoted entries break on paths with spaces and get rewritten, see
  // https://github.com/GopeedLab/gopeed/issues/1338.
  late String _unquotedRegistryValue;

  RegistryKey get _regKey => CURRENT_USER.open(
    r'Software\Microsoft\Windows\CurrentVersion\Run',
    config: const RegistryOpenConfig(access: RegistryAccess.all),
  );

  RegistryKey get _startupApprovedRegKey => CURRENT_USER.open(
    r'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run',
    config: const RegistryOpenConfig(access: RegistryAccess.all),
  );

  static const int _startupApprovedRegKeyBytesLength = 12;

  @override
  Future<bool> isEnabled() async {
    final regKey = _regKey;
    final startupApprovedRegKey = _startupApprovedRegKey;
    try {
      var value = regKey.getString(appName);
      if (value == _unquotedRegistryValue) {
        regKey.setValue(appName, RegistryValue.string(_registryValue));
        value = _registryValue;
      }
      return value == _registryValue &&
          _isStartupApproved(startupApprovedRegKey);
    } finally {
      regKey.close();
      startupApprovedRegKey.close();
    }
  }

  @override
  Future<bool> enable() async {
    final regKey = _regKey;
    final startupApprovedRegKey = _startupApprovedRegKey;
    try {
      regKey.setValue(appName, RegistryValue.string(_registryValue));

      final bytes = Uint8List(_startupApprovedRegKeyBytesLength);
      // "2" as a first byte in this register means that autostart is enabled.
      bytes[0] = 2;
      startupApprovedRegKey.setValue(appName, RegistryValue.binary(bytes));
      return true;
    } finally {
      regKey.close();
      startupApprovedRegKey.close();
    }
  }

  @override
  Future<bool> disable() async {
    final regKey = _regKey;
    final startupApprovedRegKey = _startupApprovedRegKey;
    try {
      _removeValue(regKey, appName);
      _removeValue(startupApprovedRegKey, appName);
      return true;
    } finally {
      regKey.close();
      startupApprovedRegKey.close();
    }
  }

  // https://renenyffenegger.ch/notes/Windows/registry/tree/HKEY_CURRENT_USER/Software/Microsoft/Windows/CurrentVersion/Explorer/StartupApproved/Run/index
  // Odd first byte will prevent the app from autostarting
  // Empty or any other value will allow the app to autostart
  bool _isStartupApproved(RegistryKey startupApprovedRegKey) {
    final value = startupApprovedRegKey.getBinary(appName);

    if (value == null) {
      return true;
    }

    if (value.isEmpty) {
      return true;
    }

    return value[0].isEven;
  }

  void _removeValue(RegistryKey key, String value) {
    if (key.getValue(value) != null) {
      key.removeValue(value);
    }
  }
}

class AppAutoLauncherImplWindowsMsix extends AppAutoLauncher {
  AppAutoLauncherImplWindowsMsix({
    required super.appName,
    required super.appPath,
    required this.packageName,
    super.args,
  });

  final String packageName;

  File get _shortcutFile {
    return File(
      '${Platform.environment['APPDATA']}\\Microsoft\\Windows\\Start Menu\\Programs\\Startup\\$appName.lnk',
    );
  }

  @override
  Future<bool> isEnabled() async {
    return _shortcutFile.existsSync();
  }

  @override
  Future<bool> enable() async {
    final String script =
        '''
    \$TargetPath = "$appPath"
    \$ShortcutFile = "\$env:APPDATA\\Microsoft\\Windows\\Start Menu\\Programs\\Startup\\$appName.lnk"
    \$WScriptShell = New-Object -ComObject WScript.Shell
    \$Shortcut = \$WScriptShell.CreateShortcut(\$ShortcutFile)
    \$Shortcut.TargetPath = \$TargetPath
    \$Shortcut.Arguments = "${args.join(' ')}"
    \$Shortcut.Save()
  ''';
    final result = Process.runSync('powershell', ['-Command', script]);
    if (result.stderr != null && result.stderr!.isNotEmpty) {
      throw Exception('Failed to create shortcut: ${result.stderr}');
    }
    return _shortcutFile.existsSync();
  }

  @override
  Future<bool> disable() async {
    if (_shortcutFile.existsSync()) {
      final String script =
          '''
    Remove-Item -Path "\$env:APPDATA\\Microsoft\\Windows\\Start Menu\\Programs\\Startup\\$appName.lnk"
  ''';
      final result = Process.runSync('powershell', ['-Command', script]);
      if (result.stderr != null && result.stderr!.isNotEmpty) {
        throw Exception('Failed to delete shortcut: ${result.stderr}');
      }
    }
    return !_shortcutFile.existsSync();
  }
}
