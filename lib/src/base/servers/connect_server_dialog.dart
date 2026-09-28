/// Dialog for connecting a local MCP server.
///
/// Two modes, surfaced as tabs when discovery is wired:
///  - **Manual** — transport-aware form. Streamable HTTP / SSE take a server
///    URL (and, for HTTP, an optional bearer token for an externally-exposed /
///    gated server); stdio takes a local executable (file-picked) + optional
///    arguments. Returns a [ConnectServerRequest] to the caller.
///  - **Discover** — scans the enabled discovery sources (mDNS / BLE / USB /
///    directory) and lists nearby MCP-serving boards with their connection
///    settings; picking one connects it straight through the host (no return
///    value — the connect happens inside the dialog).
///
/// When no [DiscoverScan] is supplied the dialog renders the Manual form alone
/// (no tabs). Styling rides the studio input theme (outlined, notched labels,
/// rounded) and the compact Inter-13 field typography the rest of the chrome
/// uses.
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:brain_kernel/brain_kernel.dart' show KernelTransportKind;

/// The user's local-server connect input.
class ConnectServerRequest {
  const ConnectServerRequest({
    required this.transport,
    this.endpoint,
    this.command,
    this.args = const <String>[],
    this.accessToken,
    this.name,
  });

  final KernelTransportKind transport;

  /// HTTP / SSE target URL.
  final String? endpoint;

  /// stdio executable.
  final String? command;

  /// stdio launch arguments.
  final List<String> args;

  /// Bearer token for a gated HTTP server.
  final String? accessToken;

  final String? name;
}

/// A discovered MCP-serving board / node, ready to connect. [raw] is the
/// original discovery candidate map — the host routes on it (a board with a
/// `connectHint` connects through the extension/BLE seam; a bare http(s) node
/// attaches as a remote streamable-HTTP server).
class DiscoveredServer {
  const DiscoveredServer({
    required this.source,
    required this.name,
    required this.detail,
    required this.raw,
  });

  /// mdns | ble | usb | directory.
  final String source;
  final String name;

  /// Human-readable connection subtitle (endpoint / host:port / serial port /
  /// device id).
  final String detail;

  final Map<String, dynamic> raw;
}

/// Runs one discovery scan across the enabled sources.
typedef DiscoverScan = Future<List<DiscoveredServer>> Function();

/// Connects a picked discovered server through the host.
typedef ConnectDiscovered = Future<void> Function(DiscoveredServer server);

Future<ConnectServerRequest?> showConnectServerDialog(
  BuildContext context, {
  DiscoverScan? scan,
  ConnectDiscovered? connectDiscovered,
}) {
  return showDialog<ConnectServerRequest>(
    context: context,
    builder:
        (_) => _ConnectServerDialog(
          scan: scan,
          connectDiscovered: connectDiscovered,
        ),
  );
}

/// The transports a user can drive directly (inProcess is kernel-internal).
const List<KernelTransportKind> _selectableTransports = <KernelTransportKind>[
  KernelTransportKind.streamableHttp,
  KernelTransportKind.sse,
  KernelTransportKind.stdio,
];

String _transportLabel(KernelTransportKind t) {
  switch (t) {
    case KernelTransportKind.streamableHttp:
      return 'Streamable HTTP';
    case KernelTransportKind.sse:
      return 'SSE';
    case KernelTransportKind.stdio:
      return 'stdio';
    case KernelTransportKind.inProcess:
      return 'in-process';
  }
}

// Match the studio input template — Inter at the compact input size (13), the
// same family the chrome's fields use. The theme already owns the outlined /
// rounded border + fill; this only fixes the value + label typography (which
// otherwise falls back to the larger default text theme).
TextStyle _fieldStyle() => GoogleFonts.inter(fontSize: 13);

InputDecoration _dec(String label, {String? hint}) => InputDecoration(
  labelText: label,
  hintText: hint,
  labelStyle: _fieldStyle(),
);

class _ConnectServerDialog extends StatelessWidget {
  const _ConnectServerDialog({this.scan, this.connectDiscovered});

  final DiscoverScan? scan;
  final ConnectDiscovered? connectDiscovered;

  @override
  Widget build(BuildContext context) {
    // No discovery wired → the manual form alone, no tab chrome.
    if (scan == null) {
      return AlertDialog(
        title: const Text('Connect Server'),
        content: const SizedBox(width: 460, child: _ManualConnectForm()),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Cancel', style: _fieldStyle()),
          ),
        ],
      );
    }
    return DefaultTabController(
      length: 2,
      child: AlertDialog(
        title: const Text('Connect Server'),
        content: SizedBox(
          width: 460,
          height: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TabBar(
                labelStyle: _fieldStyle().copyWith(fontWeight: FontWeight.w600),
                unselectedLabelStyle: _fieldStyle(),
                tabs: const <Widget>[
                  Tab(text: 'Manual'),
                  Tab(text: 'Discover'),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: TabBarView(
                  children: <Widget>[
                    const SingleChildScrollView(child: _ManualConnectForm()),
                    _DiscoverTab(
                      scan: scan!,
                      connectDiscovered: connectDiscovered,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Cancel', style: _fieldStyle()),
          ),
        ],
      ),
    );
  }
}

/// The transport-aware manual connect form. Pops the enclosing dialog with a
/// [ConnectServerRequest] on submit.
class _ManualConnectForm extends StatefulWidget {
  const _ManualConnectForm();

  @override
  State<_ManualConnectForm> createState() => _ManualConnectFormState();
}

class _ManualConnectFormState extends State<_ManualConnectForm> {
  KernelTransportKind _transport = KernelTransportKind.streamableHttp;
  final _url = TextEditingController();
  final _token = TextEditingController();
  final _command = TextEditingController();
  final _args = TextEditingController();
  final _name = TextEditingController();
  String? _error;

  bool get _isStdio => _transport == KernelTransportKind.stdio;

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    _command.dispose();
    _args.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _pickCommand() async {
    final picked = await FilePicker.platform.pickFiles();
    final path = picked?.files.single.path;
    if (path != null) _command.text = path;
  }

  void _submit() {
    final name = _name.text.trim();
    if (_isStdio) {
      final command = _command.text.trim();
      if (command.isEmpty) {
        setState(() => _error = 'Choose the server executable.');
        return;
      }
      final args =
          _args.text
              .trim()
              .split(RegExp(r'\s+'))
              .where((a) => a.isNotEmpty)
              .toList();
      Navigator.of(context).pop(
        ConnectServerRequest(
          transport: KernelTransportKind.stdio,
          command: command,
          args: args,
          name: name.isEmpty ? null : name,
        ),
      );
      return;
    }
    final endpoint = _url.text.trim();
    final uri = Uri.tryParse(endpoint);
    if (endpoint.isEmpty ||
        uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      setState(() => _error = 'Enter a valid http(s) server URL.');
      return;
    }
    final token = _token.text.trim();
    Navigator.of(context).pop(
      ConnectServerRequest(
        transport: _transport,
        endpoint: endpoint,
        accessToken: token.isEmpty ? null : token,
        name: name.isEmpty ? null : name,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        DropdownButtonFormField<KernelTransportKind>(
          initialValue: _transport,
          style: _fieldStyle().copyWith(
            color: Theme.of(context).colorScheme.onSurface,
          ),
          decoration: _dec('Transport'),
          items: <DropdownMenuItem<KernelTransportKind>>[
            for (final t in _selectableTransports)
              DropdownMenuItem<KernelTransportKind>(
                value: t,
                child: Text(_transportLabel(t), style: _fieldStyle()),
              ),
          ],
          onChanged: (t) {
            if (t != null) {
              setState(() {
                _transport = t;
                _error = null;
              });
            }
          },
        ),
        const SizedBox(height: 12),
        if (_isStdio) ...<Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _command,
                  style: _fieldStyle(),
                  decoration: _dec(
                    'Command',
                    hint: 'Path to the server executable',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _pickCommand,
                icon: const Icon(Icons.folder_open_outlined, size: 18),
                label: Text('Browse', style: _fieldStyle()),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _args,
            style: _fieldStyle(),
            decoration: _dec('Arguments (optional)', hint: 'Space-separated'),
            onSubmitted: (_) => _submit(),
          ),
        ] else ...<Widget>[
          TextField(
            controller: _url,
            autofocus: true,
            style: _fieldStyle(),
            decoration: _dec(
              'MCP Server URL',
              hint: 'https://my-server.example.com/mcp',
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _token,
            obscureText: true,
            style: _fieldStyle(),
            decoration: _dec(
              'Access token (optional)',
              hint: 'Bearer token for a gated server',
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
        const SizedBox(height: 12),
        TextField(
          controller: _name,
          style: _fieldStyle(),
          decoration: _dec('Display name (optional)'),
          onSubmitted: (_) => _submit(),
        ),
        if (_error != null) ...<Widget>[
          const SizedBox(height: 12),
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _submit,
            child: Text(
              'Connect',
              style: _fieldStyle().copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ],
    );
  }
}

/// Scans the enabled discovery sources and lists nearby boards; picking one
/// connects it straight through [connectDiscovered], then closes the dialog.
class _DiscoverTab extends StatefulWidget {
  const _DiscoverTab({required this.scan, this.connectDiscovered});

  final DiscoverScan scan;
  final ConnectDiscovered? connectDiscovered;

  @override
  State<_DiscoverTab> createState() => _DiscoverTabState();
}

class _DiscoverTabState extends State<_DiscoverTab> {
  late Future<List<DiscoveredServer>> _future;
  bool _connecting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _future = widget.scan();
  }

  void _rescan() {
    setState(() {
      _error = null;
      _future = widget.scan();
    });
  }

  Future<void> _connect(DiscoveredServer server) async {
    final connect = widget.connectDiscovered;
    if (connect == null || _connecting) return;
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      await connect(server);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _error = 'Connect failed: $e';
        });
      }
    }
  }

  IconData _sourceIcon(String source) {
    switch (source) {
      case 'ble':
        return Icons.bluetooth;
      case 'usb':
        return Icons.usb;
      case 'directory':
        return Icons.folder_shared_outlined;
      case 'mdns':
      default:
        return Icons.lan_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                'Nearby servers',
                style: _fieldStyle().copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            IconButton(
              tooltip: 'Rescan',
              onPressed: _connecting ? null : _rescan,
              icon: const Icon(Icons.refresh, size: 18),
            ),
          ],
        ),
        if (_connecting) const LinearProgressIndicator(minHeight: 2),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 4),
            child: Text(
              _error!,
              style: _fieldStyle().copyWith(color: scheme.error),
            ),
          ),
        const SizedBox(height: 4),
        Expanded(
          child: FutureBuilder<List<DiscoveredServer>>(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(height: 12),
                      Text('Scanning…', style: _fieldStyle()),
                    ],
                  ),
                );
              }
              if (snapshot.hasError) {
                return Center(
                  child: Text(
                    'Scan failed: ${snapshot.error}',
                    style: _fieldStyle().copyWith(color: scheme.error),
                  ),
                );
              }
              final servers = snapshot.data ?? const <DiscoveredServer>[];
              if (servers.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'No servers found. Enable sources in '
                      'Settings → Auto discovery, then rescan.',
                      textAlign: TextAlign.center,
                      style: _fieldStyle().copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                );
              }
              return ListView.separated(
                itemCount: servers.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final s = servers[i];
                  return ListTile(
                    dense: true,
                    enabled: !_connecting,
                    leading: Icon(_sourceIcon(s.source), size: 20),
                    title: Text(
                      s.name,
                      style: _fieldStyle().copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      '${s.source} · ${s.detail}',
                      style: _fieldStyle().copyWith(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    trailing: const Icon(Icons.link, size: 18),
                    onTap: () => _connect(s),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
