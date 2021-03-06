import 'dart:async';
import 'dart:convert' as cnv;
import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:process/process.dart';
import 'package:screenshots/src/base/file_system.dart';
import 'package:screenshots/src/daemon_client.dart';
import 'package:yaml/yaml.dart';
import 'android/android_sdk.dart';
import 'base/platform.dart';
import 'base/process.dart';
import 'globals.dart';

/// Parse a yaml file.
Map parseYamlFile(String yamlPath) =>
    jsonDecode(jsonEncode(loadYaml(fs.file(yamlPath).readAsStringSync())));

/// Parse a yaml string.
Map parseYamlStr(String yamlString) =>
    jsonDecode(jsonEncode(loadYaml(yamlString)));

/// Clear a named directory if it exists.
/// Create directory if none exists.
void clearDirectory(String dir) {
  _deleteDir(dir);
  fs.directory(dir).createSync(recursive: true);
}

/// Delete a directory if it exists.
void _deleteDir(String dir) {
  if (fs.directory(dir).existsSync()) {
    fs.directory(dir).deleteSync(recursive: true);
  }
}

/// Move files from [srcDir] to [dstDir].
/// If dstDir does not exist, it is created.
void moveFiles(String srcDir, String dstDir) {
  if (!fs.directory(dstDir).existsSync()) {
    fs.directory(dstDir).createSync(recursive: true);
  }
  fs.directory(srcDir).listSync().forEach((file) {
    file.renameSync('$dstDir/${p.basename(file.path)}');
  });
}

/// Creates a list of available iOS simulators.
/// (really just concerned with simulators for now).
/// Provides access to their IDs and status'.
Map getIosSimulators() {
  final simulators = cmd(['xcrun', 'simctl', 'list', 'devices', '--json']);
  final simulatorsInfo = cnv.jsonDecode(simulators)['devices'];
  return transformIosSimulators(simulatorsInfo);
}

/// Transforms latest information about iOS simulators into more convenient
/// format to index into by simulator name.
/// (also useful for testing)
Map transformIosSimulators(Map simsInfo) {
  // transform json to a Map of device name by a map of iOS versions by a list of
  // devices with a map of properties
  // ie, Map<String, Map<String, List<Map<String, String>>>>
  // In other words, just pop-out the device name for 'easier' access to
  // the device properties.
  Map simsInfoTransformed = {};

  simsInfo.forEach((iOSName, sims) {
    // note: 'isAvailable' field does not appear consistently
    //       so using 'availability' as well
    isSimAvailable(sim) =>
        sim['availability'] == '(available)' || sim['isAvailable'] == true;
    for (final sim in sims) {
      // skip if simulator unavailable
      if (!isSimAvailable(sim)) continue;

      // init iOS versions map if not already present
      if (simsInfoTransformed[sim['name']] == null) {
        simsInfoTransformed[sim['name']] = {};
      }

      // init iOS version simulator array if not already present
      // note: there can be multiple versions of a simulator with the same name
      //       for an iOS version, hence the use of an array.
      if (simsInfoTransformed[sim['name']][iOSName] == null) {
        simsInfoTransformed[sim['name']][iOSName] = [];
      }

      // add simulator to iOS version simulator array
      simsInfoTransformed[sim['name']][iOSName].add(sim);
    }
  });
  return simsInfoTransformed;
}

// finds the iOS simulator with the highest available iOS version
Map getHighestIosSimulator(Map iosSims, String simName) {
  final Map iOSVersions = iosSims[simName];
  if (iOSVersions == null) return null; // todo: hack for real device

  // get highest iOS version
  var iOSVersionName = getHighestIosVersion(iOSVersions);

  final iosVersionSims = iosSims[simName][iOSVersionName];
  if (iosVersionSims.length == 0) {
    throw "Error: no simulators found for \'$simName\'";
  }
  // use the first device found for the iOS version
  return iosVersionSims[0];
}

// returns name of highest iOS version names
String getHighestIosVersion(Map iOSVersions) {
  // sort keys in iOS version order
  final iosVersionNames = iOSVersions.keys.toList();
  iosVersionNames.sort((v1, v2) {
    return v1.compareTo(v2);
  });

  // get the highest iOS version
  final iOSVersionName = iosVersionNames.last;
  return iOSVersionName;
}

/// Create list of avds,
List<String> getAvdNames() {
  return cmd(['emulator', '-list-avds']).split('\n');
}

/// Get the highest available avd version for the android emulator.
String getHighestAVD(String deviceName) {
  final emulatorName = deviceName.replaceAll(' ', '_');
  final avds =
      getAvdNames().where((name) => name.contains(emulatorName)).toList();
  // sort list in android API order
  avds.sort((v1, v2) {
    return v1.compareTo(v2);
  });

  return avds.last;
}

/// Adds prefix to all files in a directory
Future prefixFilesInDir(String dirPath, String prefix) async {
  await for (final file
      in fs.directory(dirPath).list(recursive: false, followLinks: false)) {
    await file
        .rename(p.dirname(file.path) + '/' + prefix + p.basename(file.path));
  }
}

/// Converts [_enum] value to [String].
String getStringFromEnum(dynamic _enum) => _enum.toString().split('.').last;

/// Converts [String] to [enum].
T getEnumFromString<T>(List<T> values, String value, {bool allowNull = false}) {
  return values.firstWhere((type) => getStringFromEnum(type) == value,
      orElse: () => allowNull
          ? null
          : throw 'Fatal: \'$value\' is not a valid enum value for $values.');
}

/// Returns locale of currently attached android device.
String getAndroidDeviceLocale(String deviceId) {
// ro.product.locale is available on first boot but does not update,
// persist.sys.locale is empty on first boot but updates with locale changes
  String locale = cmd([
    getAdbPath(),
    '-s',
    deviceId,
    'shell',
    'getprop',
    'persist.sys.locale'
  ]).trim();
  if (locale.isEmpty) {
    locale = cmd([
      getAdbPath(),
      '-s',
      deviceId,
      'shell',
      'getprop ro.product.locale'
    ]).trim();
  }
  return locale;
}

/// Returns locale of simulator with udid [udId].
String getIosSimulatorLocale(String udId) {
  final env = platform.environment;
  final settingsPath =
      '${env['HOME']}/Library/Developer/CoreSimulator/Devices/$udId/data/Library/Preferences/.GlobalPreferences.plist';
  final localeInfo = cnv
      .jsonDecode(cmd(['plutil', '-convert', 'json', '-o', '-', settingsPath]));
  final locale = localeInfo['AppleLocale'];
  return locale;
}

/// Get android emulator id from a running emulator with id [deviceId].
/// Returns emulator id as [String].
String getAndroidEmulatorId(String deviceId) {
  // get name of avd of running emulator
  return cmd([getAdbPath(), '-s', deviceId, 'emu', 'avd', 'name'])
      .split('\r\n')
      .map((line) => line.trim())
      .first;
}

/// Find android device id with matching [emulatorId].
/// Returns matching android device id as [String].
String findAndroidDeviceId(String emulatorId) {
  final devicesIds = getAndroidDeviceIds();
  if (devicesIds.isEmpty) return null;
  return devicesIds.firstWhere(
      (deviceId) => emulatorId == getAndroidEmulatorId(deviceId),
      orElse: () => null);
}

/// Get the list of running android devices by id.
List<String> getAndroidDeviceIds() {
  return cmd([getAdbPath(), 'devices'])
      .trim()
      .split('\n')
      .sublist(1) // remove first line
      .map((device) => device.split('\t').first)
      .toList();
}

/// Stop an android emulator.
Future stopAndroidEmulator(String deviceId, String stagingDir) async {
  cmd([getAdbPath(), '-s', deviceId, 'emu', 'kill']);
  // wait for emulator to stop
  await streamCmd([
    '$stagingDir/resources/script/android-wait-for-emulator-to-stop',
    deviceId
  ]);
}

/// Wait for android device/emulator locale to change.
Future<String> waitAndroidLocaleChange(String deviceId, String toLocale) async {
  final regExp = RegExp(
      'ContactsProvider: Locale has changed from .* to \\[${toLocale.replaceFirst('-', '_')}\\]|ContactsDatabaseHelper: Switching to locale \\[${toLocale.replaceFirst('-', '_')}\\]');
//  final regExp = RegExp(
//      'ContactsProvider: Locale has changed from .* to \\[${toLocale.replaceFirst('-', '_')}\\]');
//  final regExp = RegExp(
//      'ContactsProvider: Locale has changed from .* to \\[${toLocale.replaceFirst('-', '_')}\\]|ContactsDatabaseHelper: Locale change completed');
  final line =
      await waitSysLogMsg(deviceId, regExp, toLocale.replaceFirst('-', '_'));
  return line;
}

/// Filters a list of devices to get real ios devices.
List<DaemonDevice> getIosDevices(List<DaemonDevice> devices) {
  final iosDevices = devices
      .where((device) => device.platform == 'ios' && !device.emulator)
      .toList();
  return iosDevices;
}

/// Filters a list of devices to get real android devices.
List<DaemonDevice> getAndroidDevices(List<DaemonDevice> devices) {
  final iosDevices = devices
      .where((device) => device.platform != 'ios' && !device.emulator)
      .toList();
  return iosDevices;
}

/// Get device for deviceName from list of devices.
DaemonDevice getDevice(List<DaemonDevice> devices, String deviceName) {
  return devices.firstWhere(
      (device) => device.iosModel == null
          ? device.name == deviceName
          : device.iosModel.contains(deviceName),
      orElse: () => null);
}

/// Get device for deviceId from list of devices.
DaemonDevice getDeviceFromId(List<DaemonDevice> devices, String deviceId) {
  return devices.firstWhere((device) => device.id == deviceId,
      orElse: () => null);
}

/// Wait for message to appear in sys log and return first matching line
Future<String> waitSysLogMsg(
    String deviceId, RegExp regExp, String locale) async {
  cmd([getAdbPath(), '-s', deviceId, 'logcat', '-c']);
  await Future.delayed(Duration(milliseconds: 1000)); // wait for log to clear
  // -b main ContactsDatabaseHelper:I '*:S'
  final delegate = await runCommand([
    getAdbPath(),
    '-s',
    deviceId,
    'logcat',
    '-b',
    'main',
    '*:S',
    'ContactsDatabaseHelper:I',
    'ContactsProvider:I',
    '-e',
    locale
  ]);
  final process = ProcessWrapper(delegate);
  return await process.stdout
//      .transform<String>(cnv.Utf8Decoder(reportErrors: false)) // from flutter tools
      .transform<String>(cnv.Utf8Decoder(allowMalformed: true))
      .transform<String>(const cnv.LineSplitter())
      .firstWhere((line) {
    printTrace(line);
    return regExp.hasMatch(line);
  }, orElse: () => null);
}

/// Find the emulator info of an named emulator available to boot.
DaemonEmulator findEmulator(
    List<DaemonEmulator> emulators, String emulatorName) {
  // find highest by avd version number
  emulators.sort(emulatorComparison);
  return emulators.lastWhere((emulator) => emulator.name == emulatorName,
      orElse: () => null);
}

int emulatorComparison(DaemonEmulator a, DaemonEmulator b) =>
    a.id.compareTo(b.id);

/// Get [RunMode] from [String].
RunMode getRunModeEnum(String runMode) {
  return getEnumFromString<RunMode>(RunMode.values, runMode);
}

/// Test for recordings in [recordDir].
Future<bool> isRecorded(String recordDir) async =>
    !(await fs.directory(recordDir).list().isEmpty);

/// Test for CI environment.
bool isCI() {
  return platform.environment['CI'] == 'true';
}

/// Convert a posix path to platform path (windows/posix).
String toPlatformPath(String posixPath, {p.Context context}) {
  const posixPathSeparator = '/';
  final splitPath = posixPath.split(posixPathSeparator);
  if (context != null) {
    // for testing
    return context.joinAll(splitPath);
  }
  return p.joinAll(splitPath);
}

/// Path to the `adb` executable.
String checkAdbPath() {
  void printAdbPathError() {
    print('#############################################################\n');
    print("# 'adb' must be in the PATH to use Screenshots\n");
    print("# You can usually add it to the PATH using\n"
        "# export PATH='\$HOME/Library/Android/sdk/platform-tools:\$PATH'  \n");
    print('#############################################################\n');
  }

  String androidHome = getAndroidHome();
  if (androidHome == null) {
    return null;
  }
  final adbName = platform.isWindows ? 'adb.exe' : 'adb';
  final String adbPath = p.join(androidHome, 'platform-tools/${adbName}');
  final absPath = p.absolute(adbPath);
  if (!fs.file(adbPath).existsSync()) {
    printAdbPathError();
  }
  return absPath;
}

/// Path to the `emulator` executable.
String getEmulatorPath() {
  void printEmulatorPathError() {
    print('#############################################################\n');
    print("# 'emulator' must be in the PATH to use Screenshots\n");
    print("# You can usually add it to the PATH using\n"
        "# export PATH='\$HOME/Library/Android/sdk/emulator:\$PATH'  \n");
    print('#############################################################\n');
  }

  String androidHome = getAndroidHome();
  if (androidHome == null) {
    return null;
  }
  final emulatorName = platform.isWindows ? 'emulator.exe' : 'emulator';
  final String emulatorPath = p.join(androidHome, 'emulator/${emulatorName}');
  final absPath = p.absolute(emulatorPath);
  if (!fs.file(emulatorPath).existsSync()) {
    printEmulatorPathError();
  }
  return absPath;
}

String getAndroidHome() {
  final String androidHome = platform.environment['ANDROID_HOME'] ??
      platform.environment['ANDROID_SDK_ROOT'];
  if (androidHome == null) {
    print('The ANDROID_SDK_ROOT and ANDROID_HOME environment variables are '
        'missing. At least one of these variables must point to the Android '
        'SDK directory.');
  }
  return androidHome;
}
