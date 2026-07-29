/// Builders for the external channel connectors, mapping a declarative
/// [ChannelConnectorConfig] (`params` = resolved credentials + options) to a
/// live `mcp_channel` connector.
///
/// A representative set — `slack` · `telegram` · `email` · `kakao` — covering
/// the platforms named by the goal (a messenger and mail) plus two common bots. The
/// remaining `mcp_channel` connectors (`discord` · `teams` · `webhook` ·
/// `wecom` · `youtube`) plug in under the identical pattern; see README.
///
/// No connection opens at build time — the connector starts when the host calls
/// `start()` (the connect tool does this). `mcp_channel` core is not modified.
library;

import 'package:mcp_channel/mcp_channel.dart';

import 'channel_provisioner.dart';

/// Chat/API connectors reach their platform over HTTPS — available everywhere.
const Set<ChannelPlatform> _everywhere = {
  ChannelPlatform.mobile,
  ChannelPlatform.desktop,
  ChannelPlatform.web,
};

/// IMAP e-mail uses a dart:io socket — mobile + desktop only.
const Set<ChannelPlatform> _socket = {
  ChannelPlatform.mobile,
  ChannelPlatform.desktop,
};

/// Register the external connector builders on [registry].
void registerChannelConnectors(ChannelDriverRegistry registry) {
  // Slack — bot token + signing secret.
  registry.registerConnector(
    'slack',
    platforms: _everywhere,
    builder: (c) => SlackConnector(
      config: SlackConfig(
        botToken: requireParam(c, 'botToken'),
        signingSecret: requireParam(c, 'signingSecret'),
        appToken: c.params['appToken'] as String?,
        workspaceId: c.params['workspaceId'] as String?,
      ),
    ),
  );

  // Telegram — bot token.
  registry.registerConnector(
    'telegram',
    platforms: _everywhere,
    builder: (c) => TelegramConnector(
      config: TelegramConfig(
        botToken: requireParam(c, 'botToken'),
        webhookUrl: c.params['webhookUrl'] as String?,
        webhookSecret: c.params['webhookSecret'] as String?,
      ),
    ),
  );

  // KakaoTalk — bot id (skill webhook).
  registry.registerConnector(
    'kakao',
    platforms: _everywhere,
    builder: (c) => KakaoConnector(
      config: KakaoConfig(
        botId: requireParam(c, 'botId'),
        webhookPath: (c.params['webhookPath'] as String?) ?? '/kakao/skill',
        validationToken: c.params['validationToken'] as String?,
      ),
    ),
  );

  // E-mail — generic IMAP provider (host + credentials). Gmail / Outlook /
  // inbound-webhook providers plug in via the other EmailProvider modes.
  registry.registerConnector(
    'email',
    platforms: _socket,
    builder: (c) => EmailConnector(
      config: EmailConfig(
        provider: EmailProvider.imap,
        botEmail: requireParam(c, 'botEmail'),
        imap: ImapConfig(
          host: requireParam(c, 'host'),
          port: (c.params['port'] as num?)?.toInt() ?? 993,
          useSsl: c.params['useSsl'] as bool? ?? true,
          username: requireParam(c, 'username'),
          password: requireParam(c, 'password'),
          folder: (c.params['folder'] as String?) ?? 'INBOX',
        ),
      ),
    ),
  );
}
