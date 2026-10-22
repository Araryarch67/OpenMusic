# shared_preferences_android 2.5 is called from Dart through JNI, by class and
# method signature, and ships no keep rules for the Kotlin types in those
# signatures. R8 renamed kotlin.coroutines.Continuation, so looking up
# SharedPreferencesApiRegistrar.getAll failed (NoSuchMethodError) and every
# release build opened to a black screen.
-keep class io.flutter.plugins.sharedpreferences.** { *; }
-keep class kotlin.coroutines.Continuation { *; }
-keep class kotlin.coroutines.intrinsics.** { *; }
-keep class kotlin.enums.EnumEntries { *; }
-keep class kotlin.jvm.internal.DefaultConstructorMarker { *; }
-keep class kotlin.Result { *; }
-keep class kotlin.Result$Failure { *; }
-keep class kotlin.Unit { *; }
