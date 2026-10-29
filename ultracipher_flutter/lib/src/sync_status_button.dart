import 'package:flutter/material.dart';
import 'package:ultracipher_flutter/src/core.dart';

import 'commons.dart';
import 'sync.dart';

/// Ein Symbol je [SyncState] (Plan §3.4). Alle statisch: ein endloser
/// Spinner würde `pumpAndSettle` in Tests hängen lassen.
IconData syncStateIcon(SyncState state) {
  switch (state) {
    case SyncState.synced:
      return Icons.cloud_done_outlined;
    case SyncState.syncing:
      return Icons.sync;
    case SyncState.notSynced:
      return Icons.cloud_upload_outlined;
    case SyncState.authRequired:
      return Icons.key_off;
    case SyncState.remoteMissing:
      return Icons.cloud_off;
    case SyncState.noRemote:
      // E4: nur auf diesem Gerät gespeichert.
      return Icons.phone_android;
  }
}

Color? syncStateColor(SyncState state) {
  switch (state) {
    case SyncState.synced:
    case SyncState.syncing:
    case SyncState.noRemote:
      return null;
    case SyncState.notSynced:
      return Colors.amber;
    case SyncState.authRequired:
    case SyncState.remoteMissing:
      return Colors.redAccent;
  }
}

String _duration(Duration d) {
  if (d.inMinutes >= 2) return '${d.inMinutes} min';
  return '${d.inSeconds < 1 ? 1 : d.inSeconds} s';
}

/// Text zum Zustand, für Tooltip und Hinweise. Fehlertexte laufen über
/// [describeError]; die ursprüngliche Ausnahme ([SyncStatus.cause]) wird nie
/// angezeigt.
String syncStatusText(SyncStatus status) {
  var error = status.error == null ? null : describeError(status.error!);
  switch (status.state) {
    case SyncState.synced:
      return 'Synced with GitHub';
    case SyncState.syncing:
      return 'Syncing...';
    case SyncState.notSynced:
      var retryAfter = status.retryAfter;
      var retry = retryAfter == null
          ? ''
          : ' Next try possible in ${_duration(retryAfter)}.';
      if (error == null) {
        return 'Not synced yet. Changes are stored on this device.';
      }
      return 'Not synced: $error.$retry Changes are stored on this device.';
    case SyncState.authRequired:
      return 'GitHub rejected the access${error == null ? '' : ' ($error)'}. '
          'Enter the token again in "GitHub settings".';
    case SyncState.remoteMissing:
      return error ??
          'Database no longer found on GitHub - passphrase changed?';
    case SyncState.noRemote:
      return 'Only stored on this device (no GitHub)';
  }
}

/// Status-Symbol für die Titelleiste: ein Symbol je Zustand, Tooltip mit dem
/// Zustandstext, Antippen ist in jedem Zustand "Sync now" ([onTap]).
class SyncStatusButton extends StatelessWidget {
  final VoidCallback onTap;

  const SyncStatusButton({Key? key, required this.onTap}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SyncStatus>(
      valueListenable: UltracipherApp.instance.syncStatus,
      builder: (context, status, _) => IconButton(
        key: const Key('syncStatusButton'),
        tooltip: '${syncStatusText(status)}\nTap to sync now',
        icon: Icon(syncStateIcon(status.state),
            color: syncStateColor(status.state)),
        onPressed: onTap,
      ),
    );
  }
}
