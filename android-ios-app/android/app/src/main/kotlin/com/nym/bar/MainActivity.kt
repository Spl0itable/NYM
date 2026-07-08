package com.nym.bar

import io.flutter.embedding.android.FlutterFragmentActivity

// local_auth's Android BiometricPrompt requires the host Activity to be a
// FragmentActivity. With the default FlutterActivity, `authenticate()` throws
// PlatformException("no_fragment_activity", …), which surfaced in-app as
// "Biometric authentication failed." Extending FlutterFragmentActivity is the
// plugin's documented requirement and makes fingerprint/face unlock work.
class MainActivity : FlutterFragmentActivity()
