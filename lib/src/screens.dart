import 'dart:async';
import 'dart:convert';
import 'package:resource/resource.dart';
import 'globals.dart';
import 'utils.dart' as utils;

/// Manage screens file.
class Screens {
  static const _screensPath = 'resources/screens.yaml';
  Map _screens;

  /// Get screens yaml file from resources and parse.
  Future<void> init() async {
    final resource = Resource("package:screenshots/$_screensPath");
    String screens = await resource.readAsString(encoding: utf8);
    _screens = utils.parseYamlStr(screens);
  }

  /// Get screen information
  Map get screens => _screens;

  /// Get screen properties for [deviceName].
  Map getScreen(String deviceName) {
    Map screenProps;
    screens.values.forEach((osScreens) {
      osScreens.values.forEach((_screenProps) {
        if (_screenProps['devices'].contains(deviceName)) {
          screenProps = _screenProps;
        }
      });
    });
    return screenProps;
  }

  /// Get [DeviceType] for [deviceName].
  DeviceType getDeviceType(String deviceName) {
    DeviceType deviceType;
    screens.forEach((_deviceType, osScreens) {
      osScreens.values.forEach((osScreen) {
        if (osScreen['devices'].contains(deviceName)) {
          deviceType = utils.getEnumFromString(DeviceType.values, _deviceType);
        }
      });
    });
    return deviceType;
  }
}
