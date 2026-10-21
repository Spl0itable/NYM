import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../widgets/nym_icons.dart';
import '../../mesh/mesh_controller.dart';
import '../share_actions.dart';
import 'nearby_inbox.dart';
import 'nearby_interaction.dart';
import 'nearby_link.dart';
import 'nearby_share_sheet.dart';

List<ShareAction> nearbyShareActions(Ref ref) => [
      ShareAction(
        id: 'nearby',
        order: kShareOrderNearby,
        label: 'Share nearby',
        icon: NymIcons.bluetooth,
        isAvailable: (ref, t) =>
            t.hasCode &&
            ref.watch(nearbyMeshRunningProvider) &&
            !(t.isOwnProfile && ref.watch(nearbyGhostActiveProvider)),
        run: (context, ref, t) => NearbyShareSheet.open(context, t),
      ),
    ];

void startNearbyInbox(Ref ref, MeshController controller) {
  final router = NearbyMeshRouter(
    peerLookup: (id) =>
        NearbySender.fromPeer(controller.service?.peerById(id)),
    onShare: (from, link) =>
        ref.read(nearbyInboxProvider.notifier).receive(from, link),
    onToken: (token) => unawaited(ref.read(nearbyNiHubProvider).deliver(token)),
  );
  controller.onServiceChanged = router.attach;
  ref.onDispose(router.dispose);
}
