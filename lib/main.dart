import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_v2ray_client/flutter_v2ray.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

const accent = Color(0xFF10B981);
const bgColor = Color(0xFF0B0D0E);
const cardColor = Color(0xFF15181B);
const cardColor2 = Color(0xFF101315);
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
          scaffoldBackgroundColor: bgColor,
          colorScheme: const ColorScheme.dark(primary: accent, secondary: accent, surface: cardColor),
          appBarTheme: const AppBarTheme(backgroundColor: bgColor, foregroundColor: accent),
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
                Container(
                  width: 40 + 50 * v,
                  height: 40 + 50 * v,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: cardColor, borderRadius: BorderRadius.circular(22), border: Border.all(color: accent, width: 2)),
                  child: Text('R', style: TextStyle(color: accent, fontSize: 24 + 34 * v, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(height: 12),
                const Text('RASAM', style: TextStyle(color: accent, fontSize: 34, letterSpacing: 8, fontWeight: FontWeight.bold)),
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
          backgroundColor: bgColor,
          indicatorColor: accent.withAlpha(60),
          selectedIndex: tab,
          onDestinationSelected: (i) => setState(() => tab = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.vpn_key_outlined), selectedIcon: Icon(Icons.vpn_key, color: accent), label: 'VPN'),
            NavigationDestination(icon: Icon(Icons.dns_outlined), selectedIcon: Icon(Icons.dns, color: accent), label: 'DNS'),
          ],
        ),
      );
}

String fmtSpeed(int b) {
  if (b >= 1048576) return '${(b / 1048576).toStringAsFixed(1)} MB/s';
  if (b >= 1024) return '${(b / 1024).toStringAsFixed(0)} KB/s';
  return '$b B/s';
}

String fmtBytes(int b) {
  if (b >= 1073741824) return '${(b / 1073741824).toStringAsFixed(1)} GB';
  if (b >= 1048576) return '${(b / 1048576).toStringAsFixed(1)} MB';
  if (b >= 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
  return '$b B';
}

void showMsg(BuildContext c, String t) => ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(t)));

// ---------------- Servers and subscriptions ----------------

class Server {
  final String name, link, host, group;
  final int port;
  int? ping;
  int? sortPing;
  Server(this.name, this.link, this.host, this.port, this.group);
  String get proto => link.split('://').first.toUpperCase();
}

class Sub {
  String name, url;
  int? used, total, expire;
  Sub(this.name, this.url);
}

class SubData {
  final List<String> links;
  final int? used, total, expire;
  SubData(this.links, this.used, this.total, this.expire);
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

String renameLink(String link, String name) {
  if (link.startsWith('vmess://')) {
    var b = link.substring(8).replaceAll('-', '+').replaceAll('_', '/');
    b = b.padRight(b.length + (4 - b.length % 4) % 4, '=');
    final j = jsonDecode(utf8.decode(base64.decode(b))) as Map<String, dynamic>;
    j['ps'] = name;
    return 'vmess://${base64.encode(utf8.encode(jsonEncode(j)))}';
  }
  final i = link.indexOf('#');
  final base = i < 0 ? link : link.substring(0, i);
  return '$base#${Uri.encodeComponent(name)}';
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

Future<SubData> fetchSub(String url) async {
  final c = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final req = await c.getUrl(Uri.parse(url));
    req.headers.set('User-Agent', 'v2rayNG/1.8.0');
    final res = await req.close().timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    final infoList = res.headers['subscription-userinfo'];
    int? up, down, total, expire;
    if (infoList != null && infoList.isNotEmpty) {
      for (final part in infoList.first.split(';')) {
        final kv = part.trim().split('=');
        if (kv.length != 2) continue;
        final v = int.tryParse(kv[1].trim());
        switch (kv[0].trim()) {
          case 'upload':
            up = v;
            break;
          case 'download':
            down = v;
            break;
          case 'total':
            total = v;
            break;
          case 'expire':
            expire = v;
            break;
        }
      }
    }
    final body = await res.transform(utf8.decoder).join();
    final used = (up != null || down != null) ? (up ?? 0) + (down ?? 0) : null;
    return SubData(decodeSub(body), used, total, expire);
  } finally {
    c.close();
  }
}

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});
  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  bool done = false;

  Future<void> pickImage() async {
    try {
      final x = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (x == null) return;
      final ctl = MobileScannerController();
      final cap = await ctl.analyzeImage(x.path);
      await ctl.dispose();
      String? v;
      if (cap != null) {
        for (final b in cap.barcodes) {
          final r = b.rawValue;
          if (r != null && r.isNotEmpty) {
            v = r;
            break;
          }
        }
      }
      if (!mounted) return;
      if (v == null) {
        showMsg(context, 'No QR code found in this image');
        return;
      }
      done = true;
      Navigator.pop(context, v);
    } catch (e) {
      if (mounted) showMsg(context, 'Could not read the image: $e');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Scan QR code'),
          actions: [IconButton(tooltip: 'Choose image', icon: const Icon(Icons.image_outlined), onPressed: pickImage)],
        ),
        body: MobileScanner(
          errorBuilder: (context, error, child) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('Camera error: ${error.errorCode.name}', textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Text(error.errorDetails?.message ?? '', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                const SizedBox(height: 20),
                FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: accent, foregroundColor: Colors.black),
                  icon: const Icon(Icons.image_outlined),
                  label: const Text('Choose a QR image instead'),
                  onPressed: pickImage,
                ),
              ]),
            ),
          ),
          onDetect: (capture) {
            if (done) return;
            for (final b in capture.barcodes) {
              final v = b.rawValue;
              if (v != null && v.isNotEmpty) {
                done = true;
                Navigator.pop(context, v);
                return;
              }
            }
          },
        ),
      );
}

BoxDecoration raised({double r = 14, bool selected = false}) => BoxDecoration(
      borderRadius: BorderRadius.circular(r),
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: selected ? [accent.withAlpha(48), accent.withAlpha(16)] : const [Color(0xFF1D2227), Color(0xFF121518)],
      ),
      border: Border.all(color: selected ? accent : Colors.white.withAlpha(24)),
      boxShadow: [
        BoxShadow(color: Colors.black.withAlpha(160), blurRadius: 12, offset: const Offset(0, 5)),
        if (selected) BoxShadow(color: accent.withAlpha(60), blurRadius: 16),
      ],
    );

class GlowPainter extends CustomPainter {
  final double t;
  final bool on;
  final bool connecting;
  GlowPainter({required this.t, required this.on, required this.connecting});

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    const base = 52.0;
    final pulse = 0.5 + 0.5 * math.sin(t * 2 * math.pi);
    final haloR = base + 30 + (on ? 11 * pulse : 4 * pulse);
    final halo = Paint()
      ..shader = RadialGradient(colors: [accent.withAlpha(on ? 120 : 40), accent.withAlpha(0)]).createShader(Rect.fromCircle(center: c, radius: haloR));
    canvas.drawCircle(c, haloR, halo);
    if (on || connecting) {
      const n = 3;
      for (var i = 0; i < n; i++) {
        final p = (t * (connecting ? 2 : 1) + i / n) % 1.0;
        final ring = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = accent.withAlpha(((1 - p) * (connecting ? 170 : 110)).toInt());
        canvas.drawCircle(c, base + 4 + p * 38, ring);
      }
    }
  }

  @override
  bool shouldRepaint(GlowPainter old) => old.t != t || old.on != on || old.connecting != connecting;
}

class PowerButton extends StatefulWidget {
  final Animation<double> anim;
  final String status;
  final VoidCallback onTap;
  const PowerButton({super.key, required this.anim, required this.status, required this.onTap});
  @override
  State<PowerButton> createState() => _PowerButtonState();
}

class _PowerButtonState extends State<PowerButton> {
  bool down = false;

  @override
  Widget build(BuildContext context) {
    final on = widget.status == 'Connected';
    final connecting = widget.status == 'Connecting…';
    return GestureDetector(
      onTapDown: (_) => setState(() => down = true),
      onTapUp: (_) => setState(() => down = false),
      onTapCancel: () => setState(() => down = false),
      onTap: widget.onTap,
      child: SizedBox(
        width: 190,
        height: 190,
        child: AnimatedBuilder(
          animation: widget.anim,
          builder: (context, _) => CustomPaint(
            painter: GlowPainter(t: widget.anim.value, on: on, connecting: connecting),
            child: Center(
              child: AnimatedScale(
                scale: down ? 0.93 : 1.0,
                duration: const Duration(milliseconds: 120),
                child: Container(
                  width: 104,
                  height: 104,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      center: const Alignment(-0.35, -0.5),
                      radius: 1.0,
                      colors: on ? const [Color(0xFF6EE7B7), accent, Color(0xFF047857)] : const [Color(0xFF2B3238), Color(0xFF181C20), Color(0xFF0B0D0F)],
                    ),
                    border: Border.all(color: on ? const Color(0xFF6EE7B7) : accent.withAlpha(160), width: 2),
                    boxShadow: [
                      BoxShadow(color: accent.withAlpha(on ? 150 : 50), blurRadius: on ? 34 : 16, spreadRadius: on ? 3 : 0),
                      const BoxShadow(color: Colors.black87, blurRadius: 14, offset: Offset(0, 8)),
                    ],
                  ),
                  child: Icon(Icons.power_settings_new, size: 48, color: on ? Colors.black : accent),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class Aurora extends StatelessWidget {
  final Animation<double> anim;
  const Aurora({super.key, required this.anim});

  Widget blob(double s, int a) => Container(
        width: s,
        height: s,
        decoration: BoxDecoration(shape: BoxShape.circle, gradient: RadialGradient(colors: [accent.withAlpha(a), accent.withAlpha(0)])),
      );

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: AnimatedBuilder(
          animation: anim,
          builder: (context, _) {
            final t = anim.value * 2 * math.pi;
            return Stack(children: [
              Positioned(top: -120 + 20 * math.sin(t), left: -90 + 30 * math.cos(t), child: blob(340, 44)),
              Positioned(top: 260 + 24 * math.cos(t), right: -150 + 20 * math.sin(t), child: blob(300, 28)),
            ]);
          },
        ),
      );
}

class VpnPage extends StatefulWidget {
  const VpnPage({super.key});
  @override
  State<VpnPage> createState() => _VpnPageState();
}

class _VpnPageState extends State<VpnPage> with SingleTickerProviderStateMixin {
  late final AnimationController glow;
  List<Server> servers = [];
  List<Sub> subs = [];
  String? selLink;
  String status = 'Disconnected';
  String duration = '00:00:00';
  int upSpeed = 0;
  int downSpeed = 0;
  bool updating = false;
  final Set<String> collapsed = {};
  final Set<String> busySubs = {};
  Timer? connTimer;
  Timer? testTimer;
  bool wantOn = false;
  final DateTime launch = DateTime.now();
  DateTime? lastStopCall;
  String testInfo = '';
  late final V2ray v2ray;

  void onStatus(dynamic st) {
    if (!mounted) return;
    final state = st.state.toString().toUpperCase();
    if (state == 'CONNECTED' && !wantOn) {
      if (DateTime.now().difference(launch).inSeconds < 5) {
        wantOn = true;
      } else {
        final now = DateTime.now();
        if (lastStopCall == null || now.difference(lastStopCall!).inSeconds >= 3) {
          lastStopCall = now;
          v2ray.stopV2Ray().catchError((_) {});
        }
        return;
      }
    }
    if (!wantOn && state.startsWith('CONNECTING')) return;
    final wasConnected = status == 'Connected';
    setState(() {
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
        duration = '00:00:00';
        upSpeed = 0;
        downSpeed = 0;
        testInfo = '';
        return;
      }
      duration = st.duration.toString();
      upSpeed = st.uploadSpeed as int;
      downSpeed = st.downloadSpeed as int;
    });
    if (state == 'CONNECTED' && !wasConnected) {
      testTimer?.cancel();
      testTimer = Timer(const Duration(seconds: 3), testConnection);
    }
  }

  Future<void> testConnection() async {
    if (!mounted || status != 'Connected') return;
    setState(() => testInfo = 'Testing…');
    try {
      final d = await v2ray.getConnectedServerDelay();
      if (!mounted) return;
      final ms = (d as num).toInt();
      setState(() => testInfo = ms > 0 ? 'Internet OK · $ms ms' : 'No internet through this server');
    } catch (_) {
      if (mounted) setState(() => testInfo = 'No internet through this server');
    }
  }

  @override
  void initState() {
    super.initState();
    glow = AnimationController(vsync: this, duration: const Duration(seconds: 4))..repeat();
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
      subs = (jsonDecode(sraw) as List).map((e) {
        final s = Sub(e['n'], e['u']);
        s.used = e['us'] as int?;
        s.total = e['t'] as int?;
        s.expire = e['e'] as int?;
        return s;
      }).toList();
    }
    selLink = prefs.getString('sel') ?? (servers.isNotEmpty ? servers.first.link : null);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await autoUpdate();
      await pingList(servers);
    });
  }

  @override
  void dispose() {
    glow.dispose();
    connTimer?.cancel();
    testTimer?.cancel();
    super.dispose();
  }

  void save() {
    prefs.setString('servers2', jsonEncode(servers.map((s) => {'l': s.link, 'g': s.group}).toList()));
    prefs.setString('subs', jsonEncode(subs.map((s) => {'n': s.name, 'u': s.url, 'us': s.used, 't': s.total, 'e': s.expire}).toList()));
    if (selLink != null) prefs.setString('sel', selLink!);
  }

  Future<void> autoUpdate() async {
    if (subs.isEmpty) return;
    setState(() => updating = true);
    var fail = 0;
    for (final s in List<Sub>.from(subs)) {
      try {
        await updateSub(s);
      } catch (_) {
        fail++;
      }
      if (mounted) setState(() {});
    }
    if (!mounted) return;
    setState(() => updating = false);
    if (fail > 0) showMsg(context, 'Couldn\'t update $fail subscription(s)');
  }

  Future<int> updateSub(Sub s) async {
    final data = await fetchSub(s.url);
    final fresh = <Server>[];
    for (final l in data.links) {
      final p = parseLink(l, s.name);
      if (p != null) fresh.add(p);
    }
    if (fresh.isEmpty) throw Exception('No servers found in this subscription');
    servers.removeWhere((e) => e.group == s.name);
    servers.addAll(fresh);
    s.used = data.used;
    s.total = data.total;
    s.expire = data.expire;
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

  Future<void> importText(String raw) async {
    final text = raw.trim();
    if (text.isEmpty) return showMsg(context, 'Nothing to import');
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
    if (mounted) showMsg(context, n > 0 ? '$n server(s) added' : 'No valid link found');
  }

  Future<void> importClipboard() async {
    final d = await Clipboard.getData('text/plain');
    await importText(d?.text ?? '');
  }

  Future<void> scanQr() async {
    final v = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => const ScanPage()));
    if (v != null && mounted) await importText(v);
  }

  Future<void> pingList(List<Server> list) async {
    await Future.wait(list.map((s) async {
      final sw = Stopwatch()..start();
      try {
        final sock = await Socket.connect(s.host, s.port, timeout: const Duration(seconds: 4));
        sock.destroy();
        s.ping = sw.elapsedMilliseconds;
      } catch (_) {
        s.ping = -1;
      }
      if (mounted) setState(() {});
    }));
    for (final s in list) {
      s.sortPing = s.ping;
    }
    if (mounted) setState(() {});
  }

  Future<bool> confirm(String text) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: cardColor,
        content: Text(text),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    return r == true;
  }

  Future<void> deleteServer(Server s) async {
    if (!await confirm('Delete "${s.name}"?')) return;
    servers.remove(s);
    if (selLink == s.link) selLink = servers.isNotEmpty ? servers.first.link : null;
    save();
    setState(() {});
  }

  Future<void> editServer(Server s) async {
    final nameC = TextEditingController(text: s.name);
    final linkC = TextEditingController(text: s.link);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: cardColor,
        title: const Text('Edit config'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: nameC, decoration: const InputDecoration(labelText: 'Name')),
            const SizedBox(height: 12),
            TextField(controller: linkC, minLines: 2, maxLines: 5, decoration: const InputDecoration(labelText: 'Link')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true) return;
    var link = linkC.text.trim();
    final newName = nameC.text.trim();
    if (link == s.link && newName.isNotEmpty && newName != s.name) {
      try {
        link = renameLink(link, newName);
      } catch (_) {
        if (mounted) showMsg(context, 'Could not rename this config');
        return;
      }
    }
    final ns = parseLink(link, s.group);
    if (ns == null) {
      if (mounted) showMsg(context, 'Invalid link');
      return;
    }
    final i = servers.indexOf(s);
    if (i < 0) return;
    servers[i] = ns;
    if (selLink == s.link) selLink = ns.link;
    save();
    setState(() {});
  }

  void shareServer(Server s) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: cardColor,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: accent, fontSize: 16)),
            const SizedBox(height: 12),
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(12),
              child: QrImageView(data: s.link, size: 240, backgroundColor: Colors.white),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: accent, foregroundColor: Colors.black),
                icon: const Icon(Icons.copy),
                label: const Text('Copy link'),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: s.link));
                  Navigator.pop(c);
                  showMsg(context, 'Link copied');
                },
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Future<void> toggle() async {
    if (status != 'Disconnected') {
      connTimer?.cancel();
      testTimer?.cancel();
      wantOn = false;
      lastStopCall = DateTime.now();
      testInfo = '';
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
    wantOn = true;
    setState(() => status = 'Connecting…');
    try {
      final ok = await v2ray.requestPermission();
      if (!ok) {
        wantOn = false;
        if (mounted) setState(() => status = 'Disconnected');
        if (mounted) showMsg(context, 'VPN permission was not granted');
        return;
      }
      connTimer?.cancel();
      connTimer = Timer(const Duration(seconds: 25), () {
        if (mounted && status == 'Connecting…') {
          wantOn = false;
          v2ray.stopV2Ray().catchError((_) {});
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
        notificationDisconnectButtonName: 'Stop',
      );
    } catch (e) {
      connTimer?.cancel();
      wantOn = false;
      if (mounted) {
        setState(() => status = 'Disconnected');
        showMsg(context, 'Error: $e');
      }
    }
  }

  int sortKey(Server s) => (s.sortPing == null || s.sortPing! < 0) ? 1 << 30 : s.sortPing!;

  List<Server> sorted(List<Server> l) {
    final idx = {for (var i = 0; i < l.length; i++) l[i]: i};
    final c = List<Server>.from(l);
    c.sort((a, b) {
      final d = sortKey(a).compareTo(sortKey(b));
      return d != 0 ? d : idx[a]!.compareTo(idx[b]!);
    });
    return c;
  }

  // ---------- UI pieces ----------

  Widget statBox(IconData i, String label, String v) => Expanded(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: raised(r: 12),
          child: Column(children: [
            Icon(i, color: accent, size: 18),
            const SizedBox(height: 4),
            Text(v, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
            Text(label, style: const TextStyle(fontSize: 11, color: Colors.white54)),
          ]),
        ),
      );

  Widget actBtn(IconData i, VoidCallback f) => InkWell(
        onTap: f,
        borderRadius: BorderRadius.circular(18),
        child: Padding(padding: const EdgeInsets.all(8), child: Icon(i, size: 20, color: Colors.white70)),
      );

  Widget serverTile(Server s) {
    final selected = selLink == s.link;
    final Color pc = s.ping == null
        ? Colors.white38
        : s.ping == -1
            ? Colors.redAccent
            : s.ping! < 250
                ? Colors.greenAccent
                : s.ping! < 500
                    ? Colors.orangeAccent
                    : Colors.redAccent;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      decoration: raised(r: 14, selected: selected),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          setState(() => selLink = s.link);
          save();
        },
        child: SizedBox(
          height: 64,
          child: Row(children: [
            Container(
              width: 36,
              decoration: BoxDecoration(color: selected ? accent : Colors.white12, borderRadius: const BorderRadius.horizontal(left: Radius.circular(13))),
              child: Center(
                child: RotatedBox(
                  quarterTurns: 3,
                  child: Text(s.proto, style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: selected ? Colors.black : Colors.white70)),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 6),
                Row(children: [
                  Expanded(child: Text(s.group == 'Manual' ? 'manual' : s.group, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Colors.white54))),
                  if (s.ping != null)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(color: pc.withAlpha(40), borderRadius: BorderRadius.circular(8)),
                      child: Text(s.ping == -1 ? '✕' : '${s.ping} ms', style: TextStyle(fontSize: 11, color: pc)),
                    ),
                ]),
              ]),
            ),
            actBtn(Icons.edit_outlined, () => editServer(s)),
            actBtn(Icons.share_outlined, () => shareServer(s)),
            actBtn(Icons.delete_outline, () => deleteServer(s)),
            const SizedBox(width: 4),
          ]),
        ),
      ),
    );
  }

  Widget section({required String id, required String title, required Widget info, required List<Server> list, required Widget trailing}) {
    final isOpen = !collapsed.contains(id);
    return Column(children: [
      Container(
        margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        decoration: raised(r: 16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => setState(() {
            if (isOpen) {
              collapsed.add(id);
            } else {
              collapsed.remove(id);
            }
          }),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
            child: Row(children: [
              Icon(isOpen ? Icons.expand_more : Icons.chevron_right, color: accent),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('$title (${list.length})', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  info,
                ]),
              ),
              trailing,
            ]),
          ),
        ),
      ),
      if (isOpen) ...list.map(serverTile),
    ]);
  }

  Widget subInfo(Sub s) {
    if (s.used == null && s.total == null && s.expire == null) {
      return const Text('No information', style: TextStyle(fontSize: 12, color: Colors.white54));
    }
    final total = s.total ?? 0;
    final used = s.used ?? 0;
    int? days;
    if (s.expire != null && s.expire! > 0) {
      days = ((s.expire! * 1000 - DateTime.now().millisecondsSinceEpoch) / 86400000).ceil();
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (total > 0)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: LinearProgressIndicator(value: (used / total).clamp(0.0, 1.0).toDouble(), color: accent, backgroundColor: Colors.white12, minHeight: 4),
        ),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text('${fmtBytes(used)} / ${total > 0 ? fmtBytes(total) : '∞'}', style: const TextStyle(fontSize: 12, color: Colors.white54)),
        if (days != null) Text(days <= 0 ? 'Expired' : '$days days left', style: const TextStyle(fontSize: 12, color: Colors.white54)),
      ]),
    ]);
  }

  Widget subTrailing(Sub s, List<Server> list) => Row(mainAxisSize: MainAxisSize.min, children: [
        busySubs.contains(s.name)
            ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: accent)))
            : IconButton(
                icon: const Icon(Icons.refresh, color: accent),
                onPressed: () async {
                  setState(() => busySubs.add(s.name));
                  try {
                    final n = await updateSub(s);
                    if (mounted) showMsg(context, 'Updated: $n servers');
                  } catch (e) {
                    if (mounted) showMsg(context, 'Failed: ${e.toString().replaceFirst('Exception: ', '')}');
                  }
                  if (mounted) setState(() => busySubs.remove(s.name));
                },
              ),
        IconButton(icon: const Icon(Icons.speed, color: accent), onPressed: () => pingList(list)),
        PopupMenuButton<String>(
          onSelected: (v) async {
            if (v == 'delete' && await confirm('Delete subscription "${s.name}" and its servers?')) {
              removeSub(s);
              setState(() {});
            }
          },
          itemBuilder: (_) => const [PopupMenuItem(value: 'delete', child: Text('Delete subscription'))],
        ),
      ]);

  @override
  Widget build(BuildContext context) {
    final on = status == 'Connected';
    final local = sorted(servers.where((e) => e.group == 'Manual').toList());
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: 'Scan QR code', icon: const Icon(Icons.qr_code_scanner), onPressed: scanQr),
        title: const Text('RASAM', style: TextStyle(letterSpacing: 4, fontWeight: FontWeight.bold)),
        actions: [
          IconButton(tooltip: 'Paste from clipboard', icon: const Icon(Icons.paste), onPressed: importClipboard),
          IconButton(tooltip: 'Ping all', icon: const Icon(Icons.speed), onPressed: () => pingList(servers)),
        ],
        bottom: updating ? const PreferredSize(preferredSize: Size.fromHeight(2), child: LinearProgressIndicator(color: accent, minHeight: 2)) : null,
      ),
      body: Stack(children: [
        Positioned.fill(child: Aurora(anim: glow)),
        Column(children: [
        const SizedBox(height: 4),
        PowerButton(anim: glow, status: status, onTap: toggle),
        const SizedBox(height: 2),
        Text(status, style: const TextStyle(color: accent, fontSize: 18)),
        GestureDetector(
          onTap: testConnection,
          child: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(on && testInfo.isNotEmpty ? testInfo : ' ', style: TextStyle(fontSize: 12, color: testInfo.contains('OK') ? accent : Colors.orangeAccent)),
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(children: [
            statBox(Icons.timer_outlined, 'Time', duration),
            statBox(Icons.arrow_downward, 'Download', fmtSpeed(downSpeed)),
            statBox(Icons.arrow_upward, 'Upload', fmtSpeed(upSpeed)),
          ]),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView(padding: const EdgeInsets.only(bottom: 16), children: [
            section(
              id: 'Manual',
              title: 'Local',
              info: const Text('No subscription', style: TextStyle(fontSize: 12, color: Colors.white54)),
              list: local,
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(icon: const Icon(Icons.speed, color: accent), onPressed: () => pingList(local)),
                PopupMenuButton<String>(
                  onSelected: (v) async {
                    if (v == 'clear' && await confirm('Delete all local configs?')) {
                      servers.removeWhere((e) => e.group == 'Manual');
                      if (selLink != null && !servers.any((e) => e.link == selLink)) {
                        selLink = servers.isNotEmpty ? servers.first.link : null;
                      }
                      save();
                      setState(() {});
                    }
                  },
                  itemBuilder: (_) => const [PopupMenuItem(value: 'clear', child: Text('Delete all'))],
                ),
              ]),
            ),
            ...subs.map((s) {
              final list = sorted(servers.where((e) => e.group == s.name).toList());
              return section(id: s.name, title: s.name, info: subInfo(s), list: list, trailing: subTrailing(s, list));
            }),
            if (servers.isEmpty && subs.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('Nothing here yet.\nScan a QR code, or copy a config / subscription link and tap the paste button.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white54)),
              ),
          ]),
        ),
      ]),
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
      backgroundColor: cardColor,
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
            const Text('DNS servers', style: TextStyle(color: accent, fontSize: 18)),
            const SizedBox(height: 4),
            ...dnsPresets.map((e) => tile(e)),
            if (custom.isNotEmpty) const Padding(padding: EdgeInsets.only(top: 12), child: Text('Your servers', style: TextStyle(color: accent, fontSize: 13))),
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
          decoration: InputDecoration(labelText: label, prefixIcon: const Icon(Icons.public, color: accent), border: const UnderlineInputBorder()),
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
              style: OutlinedButton.styleFrom(foregroundColor: accent, side: const BorderSide(color: accent)),
              icon: const Icon(Icons.list_alt),
              label: const Text('Default DNS addresses'),
              onPressed: on ? null : serversSheet,
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            height: 54,
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: accent, foregroundColor: Colors.black),
              onPressed: toggle,
              child: Text(on ? 'STOP' : 'START', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
          ),
          const SizedBox(height: 24),
          Center(child: Text(on ? 'Active' : 'Inactive', style: TextStyle(color: on ? accent : Colors.white54, fontSize: 26))),
          const SizedBox(height: 16),
          const Text('DNS runs on its own, separate from VPN. Only DNS requests go to the addresses above.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white38, fontSize: 12)),
        ]),
      );
}
