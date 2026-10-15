import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_v2ray_client/flutter_v2ray.dart';
import 'package:shared_preferences/shared_preferences.dart';

const gold = Color(0xFFD4AF37);
const dnsChannel = MethodChannel('rasam/dns');
final activeMode = ValueNotifier<String>('none'); // none / vpn / dns
late SharedPreferences prefs;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  prefs = await SharedPreferences.getInstance();
  runApp(const RasamApp());
}

class RasamApp extends StatelessWidget {
  const RasamApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: Colors.black,
          colorScheme: const ColorScheme.dark(primary: gold, secondary: gold, surface: Color(0xFF111111)),
          appBarTheme: const AppBarTheme(backgroundColor: Colors.black, foregroundColor: gold),
        ),
        home: const Splash(),
      );
}

class Splash extends StatefulWidget {
  const Splash({super.key});
  @override
  State<Splash> createState() => _SplashState();
}

class _SplashState extends State<Splash> {
  @override
  void initState() {
    super.initState();
    Timer(const Duration(milliseconds: 1800), () {
      if (mounted) Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const Shell()));
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 1400),
            builder: (c, v, _) => Opacity(
              opacity: v,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.bolt, color: gold, size: 40 + 50 * v),
                const SizedBox(height: 12),
                const Text('RASAM', style: TextStyle(color: gold, fontSize: 34, letterSpacing: 8, fontWeight: FontWeight.bold)),
              ]),
            ),
          ),
        ),
      );
}

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int tab = 0;
  @override
  Widget build(BuildContext context) => Scaffold(
        body: IndexedStack(index: tab, children: const [VpnPage(), DnsPage()]),
        bottomNavigationBar: NavigationBar(
          backgroundColor: Colors.black,
          indicatorColor: gold.withAlpha(60),
          selectedIndex: tab,
          onDestinationSelected: (i) => setState(() => tab = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.vpn_key_outlined), selectedIcon: Icon(Icons.vpn_key, color: gold), label: 'VPN'),
            NavigationDestination(icon: Icon(Icons.dns_outlined), selectedIcon: Icon(Icons.dns, color: gold), label: 'DNS'),
          ],
        ),
      );
}

String fmtSpeed(int b) {
  if (b >= 1048576) return '${(b / 1048576).toStringAsFixed(1)} MB/s';
  if (b >= 1024) return '${(b / 1024).toStringAsFixed(0)} KB/s';
  return '$b B/s';
}

void showMsg(BuildContext c, String t) => ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(t)));

// ---------------- Servers and subscriptions ----------------

class Server {
  final String name, link, host, group;
  final int port;
  int? ping;
  Server(this.name, this.link, this.host, this.port, this.group);
  String get proto => link.split('://').first.toUpperCase();
}

class Sub {
  String name, url;
  Sub(this.name, this.url);
}

Server? parseLink(String raw, String group) {
  final link = raw.trim();
  try {
    if (link.startsWith('vmess://')) {
      var b = link.substring(8).replaceAll('-', '+').replaceAll('_', '/');
      b = b.padRight(b.length + (4 - b.length % 4) % 4, '=');
      final j = jsonDecode(utf8.decode(base64.decode(b)));
      final host = j['add'].toString();
      return Server(j['ps']?.toString() ?? host, link, host, int.parse(j['port'].toString()), group);
    }
    if (RegExp(r'^(vless|trojan|hysteria2|hy2|ss)://').hasMatch(link)) {
      final i = link.indexOf('#');
      final base = i < 0 ? link : link.substring(0, i);
      var name = '';
      if (i >= 0) {
        try {
          name = Uri.decodeComponent(link.substring(i + 1));
        } catch (_) {
          name = link.substring(i + 1);
        }
      }
      final u = Uri.parse(base);
      if (u.host.isEmpty) return null;
      return Server(name.isNotEmpty ? name : u.host, link, u.host, u.hasPort ? u.port : 443, group);
    }
  } catch (_) {}
  return null;
}

List<String> decodeSub(String body) {
  var t = body.trim();
  if (!t.contains('://')) {
    try {
      var s = t.replaceAll(RegExp(r'\s'), '').replaceAll('-', '+').replaceAll('_', '/');
      s = s.padRight(s.length + (4 - s.length % 4) % 4, '=');
      t = utf8.decode(base64.decode(s));
    } catch (_) {}
  }
  return t.split(RegExp(r'\s+')).where((l) => l.contains('://')).toList();
}

Future<List<String>> fetchSub(String url) async {
  final c = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final req = await c.getUrl(Uri.parse(url));
    req.headers.set('User-Agent', 'v2rayNG/1.8.0');
    final res = await req.close().timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    final body = await res.transform(utf8.decoder).join();
    return decodeSub(body);
  } finally {
    c.close();
  }
}

class VpnPage extends StatefulWidget {
  const VpnPage({super.key});
  @override
  State<VpnPage> createState() => _VpnPageState();
}

class _VpnPageState extends State<VpnPage> {
  List<Server> servers = [];
  List<Sub> subs = [];
  String? selLink;
  String status = 'Disconnected';
  String duration = '00:00:00';
  int upSpeed = 0;
  int downSpeed = 0;
  Timer? connTimer;
  late final V2ray v2ray;

  void onStatus(dynamic st) {
    if (!mounted) return;
    final state = st.state.toString().toUpperCase();
    setState(() {
      duration = st.duration.toString();
      upSpeed = st.uploadSpeed as int;
      downSpeed = st.downloadSpeed as int;
      if (state == 'CONNECTED') {
        status = 'Connected';
        activeMode.value = 'vpn';
        connTimer?.cancel();
      } else if (state.startsWith('CONNECTING')) {
        status = 'Connecting…';
      } else if (state == 'DISCONNECTED') {
        status = 'Disconnected';
        if (activeMode.value == 'vpn') activeMode.value = 'none';
        connTimer?.cancel();
      }
    });
  }

  @override
  void initState() {
    super.initState();
    v2ray = V2ray(onStatusChanged: onStatus);
    v2ray.initialize(notificationIconResourceType: 'mipmap', notificationIconResourceName: 'ic_launcher').catchError((_) {});
    final raw = prefs.getString('servers2');
    if (raw != null) {
      for (final e in jsonDecode(raw) as List) {
        final s = parseLink(e['l'], e['g']);
        if (s != null) servers.add(s);
      }
    } else {
      for (final l in prefs.getStringList('servers') ?? <String>[]) {
        final s = parseLink(l, 'Manual');
        if (s != null) servers.add(s);
      }
    }
    final sraw = prefs.getString('subs');
    if (sraw != null) {
      subs = (jsonDecode(sraw) as List).map((e) => Sub(e['n'], e['u'])).toList();
    }
    selLink = prefs.getString('sel') ?? (servers.isNotEmpty ? servers.first.link : null);
  }

  void save() {
    prefs.setString('servers2', jsonEncode(servers.map((s) => {'l': s.link, 'g': s.group}).toList()));
    prefs.setString('subs', jsonEncode(subs.map((s) => {'n': s.name, 'u': s.url}).toList()));
    if (selLink != null) prefs.setString('sel', selLink!);
  }

  Future<int> updateSub(Sub s) async {
    final links = await fetchSub(s.url);
    final fresh = <Server>[];
    for (final l in links) {
      final p = parseLink(l, s.name);
      if (p != null) fresh.add(p);
    }
    if (fresh.isEmpty) throw Exception('No servers found in this subscription');
    servers.removeWhere((e) => e.group == s.name);
    servers.addAll(fresh);
    if (selLink == null || !servers.any((e) => e.link == selLink)) selLink = servers.first.link;
    save();
    return fresh.length;
  }

  Future<int> addSub(String url) async {
    final u = url.trim();
    final uri = Uri.tryParse(u);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https') || uri.host.isEmpty) {
      throw Exception('Enter a valid http(s) link');
    }
    var name = uri.host;
    var n = 2;
    while (subs.any((x) => x.name == name) || name == 'Manual') {
      name = '${uri.host} $n';
      n++;
    }
    final s = Sub(name, u);
    final cnt = await updateSub(s);
    subs.add(s);
    save();
    return cnt;
  }

  void removeSub(Sub s) {
    servers.removeWhere((e) => e.group == s.name);
    subs.remove(s);
    if (selLink != null && !servers.any((e) => e.link == selLink)) {
      selLink = servers.isNotEmpty ? servers.first.link : null;
    }
    save();
  }

  Future<void> importClipboard() async {
    final d = await Clipboard.getData('text/plain');
    final text = (d?.text ?? '').trim();
    if (text.startsWith('http://') || text.startsWith('https://')) {
      try {
        final n = await addSub(text.split(RegExp(r'\s+')).first);
        setState(() {});
        if (mounted) showMsg(context, 'Subscription added: $n servers');
      } catch (e) {
        if (mounted) showMsg(context, 'Failed: ${e.toString().replaceFirst('Exception: ', '')}');
      }
      return;
    }
    var n = 0;
    for (final l in text.split(RegExp(r'\s+'))) {
      final s = parseLink(l, 'Manual');
      if (s != null && !servers.any((e) => e.link == s.link)) {
        servers.add(s);
        n++;
      }
    }
    if (selLink == null && servers.isNotEmpty) selLink = servers.first.link;
    save();
    setState(() {});
    if (mounted) showMsg(context, n > 0 ? '$n server(s) added' : 'No valid link found in the clipboard');
  }

  Future<void> pingAll() async {
    for (final s in servers) {
      final sw = Stopwatch()..start();
      try {
        final sock = await Socket.connect(s.host, s.port, timeout: const Duration(seconds: 4));
        sock.destroy();
        s.ping = sw.elapsedMilliseconds;
      } catch (_) {
        s.ping = -1;
      }
      if (mounted) setState(() {});
    }
  }

  void subsSheet() {
    final ctl = TextEditingController();
    var busy = false;
    var info = '';
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF111111),
      builder: (c) => StatefulBuilder(builder: (c, ss) {
        Future<void> run(Future<String> Function() f) async {
          ss(() {
            busy = true;
            info = '';
          });
          try {
            info = await f();
          } catch (e) {
            info = 'Failed: ${e.toString().replaceFirst('Exception: ', '')}';
          }
          ss(() => busy = false);
          if (mounted) setState(() {});
        }

        return Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(c).viewInsets.bottom + 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Subscriptions', style: TextStyle(color: gold, fontSize: 18)),
            const SizedBox(height: 8),
            TextField(
              controller: ctl,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: 'Subscription link (https://...)', prefixIcon: Icon(Icons.link, color: gold)),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: gold, foregroundColor: Colors.black),
                  onPressed: busy
                      ? null
                      : () => run(() async {
                            final n = await addSub(ctl.text);
                            ctl.clear();
                            return 'Added: $n servers';
                          }),
                  child: const Text('Add'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: busy || subs.isEmpty
                      ? null
                      : () => run(() async {
                            var total = 0;
                            for (final s in List<Sub>.from(subs)) {
                              total += await updateSub(s);
                            }
                            return 'Updated: $total servers';
                          }),
                  child: const Text('Update all'),
                ),
              ),
            ]),
            if (busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator(color: gold)),
            if (info.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: Text(info, style: const TextStyle(color: Colors.white70))),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: subs
                    .map((s) => ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(s.name),
                          subtitle: Text('${servers.where((e) => e.group == s.name).length} servers', style: const TextStyle(fontSize: 12)),
                          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                            IconButton(
                              icon: const Icon(Icons.refresh, color: gold),
                              onPressed: busy ? null : () => run(() async => 'Updated: ${await updateSub(s)} servers'),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline),
                              onPressed: busy
                                  ? null
                                  : () {
                                      removeSub(s);
                                      ss(() {});
                                      setState(() {});
                                    },
                            ),
                          ]),
                        ))
                    .toList(),
              ),
            ),
          ]),
        );
      }),
    );
  }

  Future<void> toggle() async {
    if (status != 'Disconnected') {
      connTimer?.cancel();
      try {
        await v2ray.stopV2Ray();
      } catch (_) {}
      setState(() => status = 'Disconnected');
      if (activeMode.value == 'vpn') activeMode.value = 'none';
      return;
    }
    if (activeMode.value == 'dns') {
      return showMsg(context, 'DNS is on. Turn it off in the DNS tab first. VPN and DNS can\'t run together.');
    }
    final found = servers.where((e) => e.link == selLink).toList();
    if (found.isEmpty) return showMsg(context, 'Add a server first');
    final srv = found.first;
    dynamic parser;
    try {
      parser = V2ray.parseFromURL(srv.link);
    } catch (_) {
      return showMsg(context, 'This link type isn\'t supported yet (${srv.proto})');
    }
    setState(() => status = 'Connecting…');
    try {
      final ok = await v2ray.requestPermission();
      if (!ok) {
        if (mounted) setState(() => status = 'Disconnected');
        if (mounted) showMsg(context, 'VPN permission was not granted');
        return;
      }
      connTimer?.cancel();
      connTimer = Timer(const Duration(seconds: 25), () {
        if (mounted && status == 'Connecting…') {
          setState(() => status = 'Disconnected');
          showMsg(context, 'Connection timed out');
        }
      });
      await v2ray.startV2Ray(
        remark: srv.name,
        config: parser.getFullConfiguration(),
        blockedApps: null,
        bypassSubnets: null,
        proxyOnly: false,
      );
    } catch (e) {
      connTimer?.cancel();
      if (mounted) {
        setState(() => status = 'Disconnected');
        showMsg(context, 'Error: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final on = status == 'Connected';
    final groups = <String, List<Server>>{};
    for (final s in servers) {
      groups.putIfAbsent(s.group, () => []).add(s);
    }
    final items = <Object>[];
    for (final g in groups.entries) {
      items.add(g.key);
      items.addAll(g.value);
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('RASAM', style: TextStyle(letterSpacing: 4, fontWeight: FontWeight.bold)),
        actions: [
          IconButton(tooltip: 'Ping all', icon: const Icon(Icons.speed), onPressed: pingAll),
          IconButton(tooltip: 'Import from clipboard', icon: const Icon(Icons.paste), onPressed: importClipboard),
          IconButton(tooltip: 'Subscriptions', icon: const Icon(Icons.cloud_download_outlined), onPressed: subsSheet),
        ],
      ),
      body: Column(children: [
        const SizedBox(height: 24),
        GestureDetector(
          onTap: toggle,
          child: Container(
            width: 130,
            height: 130,
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: gold, width: 3), color: on ? gold : Colors.transparent),
            child: Icon(Icons.power_settings_new, size: 56, color: on ? Colors.black : gold),
          ),
        ),
        const SizedBox(height: 12),
        Text(status, style: const TextStyle(color: gold, fontSize: 18)),
        if (on) Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('$duration   ↓ ${fmtSpeed(downSpeed)}   ↑ ${fmtSpeed(upSpeed)}', style: const TextStyle(color: Colors.white60, fontSize: 12)),
        ),
        const Divider(color: Colors.white12, height: 32),
        Expanded(
          child: items.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('No servers yet.\nCopy a config link (vless://, vmess://...) or a subscription link, then tap the paste button.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white54)),
                  ),
                )
              : ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (c, i) {
                    final it = items[i];
                    if (it is String) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: Text('$it  (${groups[it]!.length})', style: const TextStyle(color: gold, fontSize: 13)),
                      );
                    }
                    final s = it as Server;
                    return Dismissible(
                      key: ValueKey('${s.group}|${s.link}'),
                      onDismissed: (_) {
                        servers.remove(s);
                        if (selLink == s.link) selLink = servers.isNotEmpty ? servers.first.link : null;
                        save();
                        setState(() {});
                      },
                      background: Container(color: Colors.red.shade900),
                      child: ListTile(
                        leading: Icon(selLink == s.link ? Icons.radio_button_checked : Icons.radio_button_off, color: gold),
                        title: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text('${s.proto} · ${s.host}:${s.port}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
                        trailing: Text(s.ping == null ? '' : s.ping == -1 ? '✕' : '${s.ping}ms', style: TextStyle(color: s.ping == -1 ? Colors.red : gold)),
                        onTap: () {
                          setState(() => selLink = s.link);
                          save();
                        },
                      ),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}

// ---------------- DNS ----------------

const dnsPresets = [
  ['Shecan', '178.22.122.100', '185.51.200.2'],
  ['Electro', '78.157.42.100', '78.157.42.101'],
  ['Google', '8.8.8.8', '8.8.4.4'],
  ['Cloudflare', '1.1.1.1', '1.0.0.1'],
  ['Quad9', '9.9.9.9', '149.112.112.112'],
];

bool validIp(String s) {
  final m = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$').firstMatch(s.trim());
  if (m == null) return false;
  return List.generate(4, (i) => int.parse(m.group(i + 1)!)).every((n) => n <= 255);
}

class DnsPage extends StatefulWidget {
  const DnsPage({super.key});
  @override
  State<DnsPage> createState() => _DnsPageState();
}

class _DnsPageState extends State<DnsPage> {
  final p1 = TextEditingController();
  final p2 = TextEditingController();
  bool busy = false;
  List<List<String>> custom = [];

  bool get on => activeMode.value == 'dns';
  void _r() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    activeMode.addListener(_r);
    p1.text = prefs.getString('dns1') ?? '178.22.122.100';
    p2.text = prefs.getString('dns2') ?? '185.51.200.2';
    final raw = prefs.getString('dnsCustom');
    if (raw != null) {
      custom = (jsonDecode(raw) as List).map((e) => [e['n'].toString(), e['p'].toString(), e['s'].toString()]).toList();
    }
    _sync();
  }

  Future<void> _sync() async {
    try {
      final v = await dnsChannel.invokeMethod<bool>('isRunning');
      if (v == true) activeMode.value = 'dns';
    } catch (_) {}
  }

  @override
  void dispose() {
    activeMode.removeListener(_r);
    super.dispose();
  }

  void saveCustom() => prefs.setString('dnsCustom', jsonEncode(custom.map((e) => {'n': e[0], 'p': e[1], 's': e[2]}).toList()));

  Future<void> toggle() async {
    if (busy) return;
    if (on) {
      try {
        await dnsChannel.invokeMethod('stop');
      } catch (_) {}
      activeMode.value = 'none';
      return;
    }
    if (activeMode.value == 'vpn') {
      return showMsg(context, 'VPN is on. Disconnect it first. VPN and DNS can\'t run together.');
    }
    if (!validIp(p1.text)) return showMsg(context, 'The primary DNS address isn\'t valid');
    if (p2.text.trim().isNotEmpty && !validIp(p2.text)) return showMsg(context, 'The secondary DNS address isn\'t valid');
    prefs.setString('dns1', p1.text.trim());
    prefs.setString('dns2', p2.text.trim());
    setState(() => busy = true);
    try {
      final ok = await dnsChannel.invokeMethod<bool>('start', {'primary': p1.text.trim(), 'secondary': p2.text.trim()});
      if (ok == true) {
        activeMode.value = 'dns';
      } else if (mounted) {
        showMsg(context, 'Permission was not granted');
      }
    } on MissingPluginException {
      if (mounted) showMsg(context, 'This build has no DNS support');
    } on PlatformException catch (e) {
      if (mounted) showMsg(context, 'Error: ${e.message}');
    }
    if (mounted) setState(() => busy = false);
  }

  void serversSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF111111),
      isScrollControlled: true,
      builder: (c) => StatefulBuilder(builder: (c, ss) {
        Widget tile(List<String> e, {bool deletable = false}) => ListTile(
              title: Text(e[0]),
              subtitle: Text('${e[1]}  /  ${e[2]}', style: const TextStyle(fontSize: 12)),
              trailing: deletable
                  ? IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () {
                        custom.remove(e);
                        saveCustom();
                        ss(() {});
                      },
                    )
                  : null,
              onTap: () {
                setState(() {
                  p1.text = e[1];
                  p2.text = e[2];
                });
                Navigator.pop(c);
              },
            );
        return SafeArea(
          child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(16), children: [
            const Text('DNS servers', style: TextStyle(color: gold, fontSize: 18)),
            const SizedBox(height: 4),
            ...dnsPresets.map((e) => tile(e)),
            if (custom.isNotEmpty) const Padding(padding: EdgeInsets.only(top: 12), child: Text('Your servers', style: TextStyle(color: gold, fontSize: 13))),
            ...custom.map((e) => tile(e, deletable: true)),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.bookmark_add_outlined),
              label: const Text('Save current addresses'),
              onPressed: () {
                if (!validIp(p1.text)) return;
                final s = p2.text.trim();
                if (!custom.any((e) => e[1] == p1.text.trim() && e[2] == s)) {
                  custom.add([p1.text.trim(), p1.text.trim(), s]);
                  saveCustom();
                }
                ss(() {});
              },
            ),
          ]),
        );
      }),
    );
  }

  Widget field(TextEditingController c, String label) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: TextField(
          controller: c,
          enabled: !on,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: label, prefixIcon: const Icon(Icons.public, color: gold), border: const UnderlineInputBorder()),
        ),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          toolbarHeight: 72,
          title: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('DNS', style: TextStyle(fontWeight: FontWeight.bold)),
            Text('Configuring IPv4', style: TextStyle(fontSize: 14, color: Colors.white60)),
          ]),
        ),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          field(p1, 'Primary server'),
          field(p2, 'Secondary server'),
          const SizedBox(height: 20),
          SizedBox(
            height: 52,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: gold, side: const BorderSide(color: gold)),
              icon: const Icon(Icons.list_alt),
              label: const Text('Default DNS addresses'),
              onPressed: on ? null : serversSheet,
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            height: 54,
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: gold, foregroundColor: Colors.black),
              onPressed: toggle,
              child: Text(on ? 'STOP' : 'START', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
          ),
          const SizedBox(height: 24),
          Center(child: Text(on ? 'Active' : 'Inactive', style: TextStyle(color: on ? gold : Colors.white54, fontSize: 26))),
          const SizedBox(height: 16),
          const Text('DNS runs on its own, separate from VPN. Only DNS requests go to the addresses above.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white38, fontSize: 12)),
        ]),
      );
}
