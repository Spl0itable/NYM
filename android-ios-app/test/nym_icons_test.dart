import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/widgets/nym_icons.dart';

void main() {
  // Guards the exact-PWA icon set: a typo in any path/markup would render blank
  // (or throw) on-device, so assert every glyph parses into an SvgPicture and
  // renders without surfacing an exception.
  testWidgets('every NymIcons glyph parses + renders without error',
      (tester) async {
    const icons = <(String, String)>[
      ('chevronLeft', NymIcons.chevronLeft),
      ('chevronRight', NymIcons.chevronRight),
      ('starOutline', NymIcons.starOutline),
      ('starFilled', NymIcons.starFilled),
      ('shareNodes', NymIcons.shareNodes),
      ('phone', NymIcons.phone),
      ('video', NymIcons.video),
      ('bell', NymIcons.bell),
      ('starFlair', NymIcons.starFlair),
      ('settings', NymIcons.settings),
      ('info', NymIcons.info),
      ('logout', NymIcons.logout),
      ('menu', NymIcons.menu),
      ('bellOff', NymIcons.bellOff),
      ('transfers', NymIcons.transfers),
      ('groupGlyph', NymIcons.groupGlyph),
      ('friendBadge', NymIcons.friendBadge),
      ('lock', NymIcons.lock),
      ('close', NymIcons.close),
      ('composerImage', NymIcons.composerImage),
      ('composerFile', NymIcons.composerFile),
      ('composerEmoji', NymIcons.composerEmoji),
      ('translate', NymIcons.translate),
      // Sidebar nav-title icons.
      ('globe', NymIcons.globe),
      ('search', NymIcons.search),
      ('plus', NymIcons.plus),
      ('chevronDown', NymIcons.chevronDown),
      ('reorderUp', NymIcons.reorderUp),
      ('reorderDown', NymIcons.reorderDown),
      // Message/user context-menu glyphs.
      ('ctxReact', NymIcons.ctxReact),
      ('ctxMention', NymIcons.ctxMention),
      ('ctxPm', NymIcons.ctxPm),
      ('ctxSlap', NymIcons.ctxSlap),
      ('ctxHug', NymIcons.ctxHug),
      ('ctxAddToGroup', NymIcons.ctxAddToGroup),
      ('ctxZap', NymIcons.ctxZap),
      ('ctxGiftCredits', NymIcons.ctxGiftCredits),
      ('ctxQuote', NymIcons.ctxQuote),
      ('ctxCopy', NymIcons.ctxCopy),
      ('ctxFriend', NymIcons.ctxFriend),
      ('ctxReport', NymIcons.ctxReport),
      ('ctxEdit', NymIcons.ctxEdit),
      ('ctxDelete', NymIcons.ctxDelete),
      ('ctxMakeMod', NymIcons.ctxMakeMod),
      ('ctxRevokeMod', NymIcons.ctxRevokeMod),
      ('ctxTransferOwner', NymIcons.ctxTransferOwner),
      ('ctxKick', NymIcons.ctxKick),
      ('ctxBan', NymIcons.ctxBan),
      ('ctxBlock', NymIcons.ctxBlock),
      ('ctxEditProfile', NymIcons.ctxEditProfile),
      // Group context-menu owner/member controls.
      ('groupEditDescription', NymIcons.groupEditDescription),
      ('groupChangeAvatar', NymIcons.groupChangeAvatar),
      ('groupChangeBanner', NymIcons.groupChangeBanner),
      ('groupResetInvite', NymIcons.groupResetInvite),
      ('groupAddMembers', NymIcons.groupAddMembers),
      ('groupLeave', NymIcons.groupLeave),
      ('checkboxChecked', NymIcons.checkboxChecked),
      ('checkboxUnchecked', NymIcons.checkboxUnchecked),
      ('sidebarBlock', NymIcons.sidebarBlock),
      ('sidebarFavorite', NymIcons.sidebarFavorite),
      ('sidebarHide', NymIcons.sidebarHide),
      // Call controls.
      ('callMic', NymIcons.callMic),
      ('callMicOff', NymIcons.callMicOff),
      ('callScreenShare', NymIcons.callScreenShare),
      ('callReact', NymIcons.callReact),
      ('callChat', NymIcons.callChat),
      ('callPresenter', NymIcons.callPresenter),
      ('callSwitchCam', NymIcons.callSwitchCam),
      ('send', NymIcons.send),
      // Modal-internal glyphs (settings / identity / wallpaper).
      ('revealArrowRight', NymIcons.revealArrowRight),
      ('revealArrowDown', NymIcons.revealArrowDown),
      ('nsecEye', NymIcons.nsecEye),
      ('warningTriangle', NymIcons.warningTriangle),
      ('upload', NymIcons.upload),
      ('fileOffer', NymIcons.fileOffer),
      ('addReaction', NymIcons.addReaction),
    ];

    for (final (name, svg) in icons) {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: NymSvgIcon(svg, size: 18, color: const Color(0xFF112233)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$name threw while rendering');
      expect(find.byType(SvgPicture), findsOneWidget, reason: '$name missing');
    }
  });
}
