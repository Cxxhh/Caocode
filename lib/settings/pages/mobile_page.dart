import 'dart:async';

import 'package:bao_link/bao_link.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ide/ide_button.dart';
import '../../l10n/l10n.dart';
import '../../link/link_host.dart';
import '../../link/qr_view.dart';
import '../../theme/codicons.dart';
import 'settings_widgets.dart';

/// Settings → Mobile: whether phones may connect, where they reach this
/// computer (its addresses, the port, public ones given), pairing one by
/// QR code, and the phones paired. The relay is listed, not there yet.
class MobileSettingsPage extends StatefulWidget {
  const MobileSettingsPage({super.key, required this.host});

  final LinkHost host;

  @override
  State<MobileSettingsPage> createState() => _MobileSettingsPageState();
}

class _MobileSettingsPageState extends State<MobileSettingsPage> {
  /// What was typed as the port, when it is not one.
  String? _invalidPort;

  bool _copied = false;
  Timer? _copiedTimer;

  /// Ticks while a code shows, for it to say when it expired.
  Timer? _ticker;

  LinkHost get _host => widget.host;

  @override
  void initState() {
    super.initState();
    _host.addListener(_changed);
    unawaited(_host.refreshEndpoints());
    _ticker = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_host.offer != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _host.removeListener(_changed);
    _copiedTimer?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _setPort(String text) {
    final port = int.tryParse(text);
    if (port == null || port <= 0 || port > 65535) {
      setState(() => _invalidPort = text);
      return;
    }
    setState(() => _invalidPort = null);
    unawaited(_host.setPort(port));
  }

  void _copy(String link) {
    unawaited(Clipboard.setData(ClipboardData(text: link)));
    _copiedTimer?.cancel();
    setState(() => _copied = true);
    _copiedTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final host = _host;
    final endpoints = host.endpoints;
    final invalidPort = _invalidPort;
    return SettingsPage(
      title: l10n.settingsSectionMobile,
      description: l10n.mobileSettingsDescription,
      children: [
        SettingsCard(
          children: [
            SettingsSwitchRow(
              label: l10n.mobileAllow,
              description: l10n.mobileAllowDescription,
              value: host.enabled,
              onChanged: (value) => unawaited(host.setEnabled(value)),
            ),
            SettingsSwitchRow(
              label: l10n.mobileDiscoverable,
              description: l10n.mobileDiscoverableDescription,
              value: host.discoverable,
              onChanged: host.setDiscoverable,
            ),
            SettingsRow(
              label: l10n.mobileStatus,
              description: switch (host.status) {
                LinkHostStatus.off => l10n.mobileStatusOff,
                LinkHostStatus.starting => l10n.mobileStatusStarting,
                LinkHostStatus.listening => l10n.mobileStatusListening(
                  host.port,
                ),
                LinkHostStatus.failed => l10n.mobileStatusFailed(
                  host.error ?? '',
                ),
              },
            ),
            SettingsRow(
              label: l10n.mobileAddresses,
              description: l10n.mobileAddressesDescription,
              below: [
                if (endpoints.isEmpty)
                  Text(
                    l10n.mobileAddressesNone,
                    style: SettingsText.description,
                  )
                else
                  SelectableText(
                    endpoints.join('\n'),
                    style: SettingsText.path,
                  ),
              ],
              trailing: IdeButton(
                label: l10n.mobileAddressesRefresh,
                icon: Codicons.refresh,
                secondary: true,
                onPressed: () => unawaited(host.refreshEndpoints()),
              ),
            ),
            SettingsRow(
              label: l10n.mobilePort,
              description: invalidPort == null
                  ? l10n.mobilePortDescription
                  : l10n.mobilePortInvalid(invalidPort),
              trailing: SettingsTextField(
                value: '${host.port}',
                hint: '$defaultLinkPort',
                width: 100,
                semanticLabel: l10n.mobilePort,
                onSubmitted: _setPort,
              ),
            ),
            SettingsRow(
              label: l10n.mobilePublicAddress,
              description: l10n.mobilePublicAddressDescription,
              trailing: SettingsTextField(
                value: host.publicAddresses.join(', '),
                hint: 'home.example.com:${host.port}',
                semanticLabel: l10n.mobilePublicAddress,
                onSubmitted: (text) => host.setPublicAddresses(text.split(',')),
              ),
            ),
            SettingsRow(
              label: l10n.mobileRelay,
              description: l10n.mobileRelayDescription,
              trailing: Text(
                l10n.mobileRelayUnavailable,
                style: SettingsText.description,
              ),
            ),
          ],
        ),
        SettingsGroup(title: l10n.mobilePair, children: [_pairing(context)]),
        SettingsGroup(
          title: l10n.mobilePhones,
          children: [
            if (host.phones.isEmpty) SettingsRow(label: l10n.mobilePhonesNone),
            for (final phone in host.phones)
              SettingsRow(
                label: phone.name.isEmpty ? phone.fingerprint : phone.name,
                description: [
                  if (phone.system.isNotEmpty) phone.system,
                  if (host.isConnected(phone.id))
                    l10n.mobilePhoneConnected
                  else if (phone.lastSeen case final seen?)
                    l10n.mobilePhoneLastSeen(_time(seen)),
                ].join(' · '),
                trailing: IdeButton(
                  label: l10n.mobilePhoneRemove,
                  icon: Codicons.trash,
                  secondary: true,
                  onPressed: () => host.unpair(phone),
                ),
              ),
            SettingsRow(
              label: l10n.mobileThisComputerKey,
              description: l10n.mobileThisComputerKeyDescription,
              below: [
                SelectableText(host.fingerprint, style: SettingsText.path),
              ],
            ),
          ],
        ),
      ],
    );
  }

  /// The pairing card's row: a button to show a code; the code; the
  /// safety code to compare once a phone scanned it; who was paired.
  Widget _pairing(BuildContext context) {
    final l10n = context.l10n;
    final host = _host;
    final offer = host.offer;
    final pending = host.pending;
    if (pending != null) {
      final name = pending.name.isEmpty ? pending.system : pending.name;
      if (pending.needsApproval) {
        // Found nearby, with no code scanned: allowed here, or not.
        return SettingsRow(
          label: l10n.mobilePairRequestTitle(name),
          description: l10n.mobilePairRequestBody,
          below: [
            Text(
              pending.code.join('  '),
              style: SettingsText.path.copyWith(
                fontSize: 26,
                fontWeight: FontWeight.w600,
                letterSpacing: 2,
              ),
            ),
            if (!pending.approved)
              SettingsButtons(
                children: [
                  IdeButton(
                    label: l10n.mobilePairAllow,
                    icon: Codicons.check,
                    onPressed: host.approvePending,
                  ),
                  IdeButton(
                    label: l10n.mobilePairMismatch,
                    secondary: true,
                    onPressed: host.rejectPending,
                  ),
                ],
              ),
          ],
        );
      }
      return SettingsRow(
        label: l10n.mobilePairVerifyTitle(name),
        description: l10n.mobilePairVerifyBody,
        below: [
          Text(
            pending.code.join('  '),
            style: SettingsText.path.copyWith(
              fontSize: 26,
              fontWeight: FontWeight.w600,
              letterSpacing: 2,
            ),
          ),
        ],
        trailing: IdeButton(
          label: l10n.mobilePairMismatch,
          secondary: true,
          onPressed: host.rejectPending,
        ),
      );
    }
    if (offer != null) {
      final expired = offer.expiredAt(DateTime.now());
      final link = offer.uri;
      return SettingsRow(
        label: l10n.mobilePair,
        description: expired
            ? l10n.mobilePairExpired
            : [
                l10n.mobilePairExpires(host.offerLifetime.inMinutes),
                if (host.advertised) l10n.mobilePairNearbyHint,
              ].join(' '),
        below: [
          if (!expired)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: QrView(data: link),
            ),
          SettingsButtons(
            children: [
              IdeButton(
                label: l10n.mobilePairNewCode,
                icon: Codicons.refresh,
                secondary: true,
                onPressed: () => unawaited(host.beginPairing()),
              ),
              if (!expired)
                IdeButton(
                  label: _copied
                      ? l10n.mobilePairCopied
                      : l10n.mobilePairCopyLink,
                  icon: _copied ? Codicons.check : Codicons.copy,
                  secondary: true,
                  onPressed: () => _copy(link),
                ),
              IdeButton(
                label: l10n.mobilePairCancel,
                secondary: true,
                onPressed: host.endPairing,
              ),
            ],
          ),
        ],
      );
    }
    final paired = host.justPaired;
    return SettingsRow(
      label: l10n.mobilePair,
      description: paired == null
          ? l10n.mobilePairDescription
          : l10n.mobilePaired(paired.name),
      trailing: IdeButton(
        label: l10n.mobilePairShow,
        icon: Codicons.deviceMobile,
        onPressed: host.supported ? () => unawaited(host.beginPairing()) : null,
      ),
    );
  }

  static String _time(DateTime time) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }
}
