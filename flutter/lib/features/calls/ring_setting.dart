import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/nostr_controller.dart';
import '../i18n/i18n.dart';
import '../settings/settings_widgets.dart';
import 'call_platform.dart';
import 'call_wake.dart';

const String kRingWhenClosedHint =
    'Lets people you have had a call with ring this phone while Nymchat is '
    'in the background or closed. With "Friends only", only friends can. Our '
    'servers send an empty push that says nothing about who is calling, and '
    'the phone then fetches and decrypts the call itself. Works for one '
    'identity per phone.';

const String kRingOtherIdentityHint =
    'Another identity on this phone already rings when Nymchat is closed. '
    'Turn it off there first, so our servers cannot tell that two identities '
    'share this phone.';

Map<String, String> ringNativeStrings() => {
      'incoming': tr('Incoming call'),
      'openToSee': tr('Open Nymchat to answer'),
      'channel': tr('Incoming calls'),
      'decline': tr('Decline'),
      'answer': tr('Answer'),
    };

class RingWhenClosedSetting extends ConsumerStatefulWidget {
  const RingWhenClosedSetting({super.key});

  @override
  ConsumerState<RingWhenClosedSetting> createState() =>
      _RingWhenClosedSettingState();
}

class _RingWhenClosedSettingState extends ConsumerState<RingWhenClosedSetting> {
  bool _busy = false;

  String get _self =>
      ref.read(nostrControllerProvider).identity?.pubkey ?? '';

  Future<void> _set(bool on) async {
    if (_busy) return;
    final reg = ref.read(ringRegistrationProvider);
    final platform = ref.read(callPlatformProvider);
    setState(() => _busy = true);
    try {
      if (on) {
        if (await reg.enable(_self)) {
          await platform.ringEnable(ringNativeStrings());
        }
      } else {
        await platform.ringDisable();
        await reg.disable();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final reg = ref.read(ringRegistrationProvider);
    final self = _self;
    final other = reg.ownedByOther(self);
    return FormGroup(
      key: const ValueKey('ringWhenClosed'),
      label: tr('Ring When Nymchat Is Closed'),
      hint: tr(kRingWhenClosedHint),
      amberHint: other ? tr(kRingOtherIdentityHint) : null,
      child: FormSelect<bool>(
        value: reg.enabledFor(self),
        items: [
          (value: false, label: tr('Disabled')),
          (value: true, label: tr('Enabled')),
        ],
        onChanged: (v) {
          if (other && v) return;
          unawaited(_set(v));
        },
      ),
    );
  }
}
