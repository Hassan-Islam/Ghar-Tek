import 'package:flutter/material.dart';

/// Global theme notifier — update this to switch between light and dark mode.
final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier<ThemeMode>(ThemeMode.light);
