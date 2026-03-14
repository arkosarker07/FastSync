## Flutter wrapper
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

## Keep file_picker
-keep class com.mr.flutter.plugin.filepicker.** { *; }

## Keep permission_handler
-keep class com.baseflow.permissionhandler.** { *; }

## Keep url_launcher
-keep class io.flutter.plugins.urllauncher.** { *; }

## Keep shelf (Dart-side only, but just in case)
-dontwarn io.flutter.**
