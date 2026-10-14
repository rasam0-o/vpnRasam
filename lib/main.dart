import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const gold = Color(0xFFD4AF37);
void main() => runApp(const RasamApp());

class RasamApp extends StatelessWidget {
  const RasamApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        builder: (c, w) => Directionality(textDirection: TextDirection.rtl, child: w!),
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
      if (mounted) Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const Home()));
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

class Server {
  final String name, link, host;
  final int port;
  int? ping; // میلی‌ثانیه؛ -1 یعنی ناموفق
  Server(this.name, this.link, this.host, this.port);
}

Server? parseLink(String raw) {
  final link = raw.trim();
  try {
    if (link.startsWith('vmess://')) {
      var b = link.substring(8);
      b = b.padRight(b.length + (4 - b.length % 4) % 4, '=');
      final j = jsonDecode(utf8.decode(base64.decode(b)));
      return Server(j['ps']?.toString() ?? j['add'], link, j['add'].toString(), int.parse(j['port'].toString()));
    }
    if (RegExp(r'^(vless|trojan|hysteria2|hy2|ss)://').hasMatch(link)) {
      final u = Uri.parse(link);
      final name = u.fragment.isNotEmpty ? Uri.decodeComponent(u.fragment) : u.host;
      return Server(name, link, u.host, u.hasPort ? u.port : 443);
    }
  } catch (_) {}
  return null;
}

const dnsPresets = {
  'Cloudflare': 'https://cloudflare-dns.com/dns-query',
  'Google': 'https://dns.google/dns-query',
  'Quad9': 'https://dns.quad9.net/dns-query',
  'Shecan (ایران)': '178.22.122.100',
};

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  List<Server> servers = [];
  int sel = -1;
  String status = 'قطع'; // قطع / در حال اتصال / وصل
  String dnsName = 'Cloudflare';
  String dnsCustom = '';
  SharedPreferences? p;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((x) {
      p = x;
      setState(() {
        servers = (x.getStringList('servers') ?? []).map(parseLink).whereType<Server>().toList();
        dnsName = x.getString('dnsName') ?? 'Cloudflare';
        dnsCustom = x.getString('dnsCustom') ?? '';
        if (servers.isNotEmpty) sel = 0;
      });
    });
  }

  void save() {
    p?.setStringList('servers', servers.map((s) => s.link).toList());
    p?.setString('dnsName', dnsName);
    p?.setString('dnsCustom', dnsCustom);
  }

  void msg(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  Future<void> addFromClipboard() async {
    final d = await Clipboard.getData('text/plain');
    final lines = (d?.text ?? '').split(RegExp(r'\s+'));
    var n = 0;
    for (final l in lines) {
      final s = parseLink(l);
      if (s != null && !servers.any((e) => e.link == s.link)) {
        servers.add(s);
        n++;
      }
    }
    setState(() {
      if (sel < 0 && servers.isNotEmpty) sel = 0;
    });
    save();
    msg(n > 0 ? '$n سرور اضافه شد' : 'لینک معتبری در کلیپ‌بورد پیدا نشد');
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

  Future<void> toggle() async {
    if (status != 'قطع') {
      setState(() => status = 'قطع');
      return;
    }
    if (sel < 0) return msg('اول یه سرور اضافه کن');
    setState(() => status = 'در حال اتصال');
    await Future.delayed(const Duration(seconds: 1));
    // TODO مرحله ۲: اینجا هسته‌ی sing-box با VpnService اندروید وصل می‌شه.
    setState(() => status = 'قطع');
    msg('هسته‌ی اتصال هنوز اضافه نشده (مرحله ۲)');
  }

  void dnsSheet() {
    final ctl = TextEditingController(text: dnsCustom);
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF111111),
      isScrollControlled: true,
      builder: (c) => Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(c).viewInsets.bottom + 16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('تنظیمات DNS', style: TextStyle(color: gold, fontSize: 18)),
          ...dnsPresets.keys.map((k) => ListTile(
                title: Text(k),
                subtitle: Text(dnsPresets[k]!, style: const TextStyle(fontSize: 11), textDirection: TextDirection.ltr),
                trailing: dnsName == k ? const Icon(Icons.check, color: gold) : null,
                onTap: () {
                  setState(() => dnsName = k);
                  save();
                  Navigator.pop(c);
                },
              )),
          TextField(controller: ctl, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'DNS دلخواه (آدرس یا DoH)')),
          const SizedBox(height: 8),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: gold, foregroundColor: Colors.black),
            onPressed: () {
              if (ctl.text.trim().isNotEmpty) {
                setState(() {
                  dnsName = 'دلخواه';
                  dnsCustom = ctl.text.trim();
                });
                save();
              }
              Navigator.pop(c);
            },
            child: const Text('ذخیره'),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final on = status == 'وصل';
    return Scaffold(
      appBar: AppBar(
        title: const Text('RASAM', style: TextStyle(letterSpacing: 4, fontWeight: FontWeight.bold)),
        actions: [
          IconButton(icon: const Icon(Icons.dns), onPressed: dnsSheet),
          IconButton(icon: const Icon(Icons.speed), onPressed: pingAll),
          IconButton(icon: const Icon(Icons.paste), onPressed: addFromClipboard),
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
        Text('DNS: ${dnsName == 'دلخواه' ? dnsCustom : dnsName}', style: const TextStyle(color: Colors.white54, fontSize: 12)),
        const Divider(color: Colors.white12, height: 32),
        Expanded(
          child: servers.isEmpty
              ? const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('هنوز سروری نداری.\nیه لینک (vless:// و...) کپی کن و دکمه‌ی چسباندن بالا رو بزن.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white54))))
              : ListView.builder(
                  itemCount: servers.length,
                  itemBuilder: (c, i) {
                    final s = servers[i];
                    return Dismissible(
                      key: ValueKey(s.link),
                      onDismissed: (_) {
                        servers.removeAt(i);
                        sel = servers.isEmpty ? -1 : 0;
                        save();
                        setState(() {});
                      },
                      background: Container(color: Colors.red.shade900),
                      child: ListTile(
                        leading: Icon(sel == i ? Icons.radio_button_checked : Icons.radio_button_off, color: gold),
                        title: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text('${s.host}:${s.port}', textDirection: TextDirection.ltr, style: const TextStyle(fontSize: 11)),
                        trailing: Text(s.ping == null ? '' : s.ping == -1 ? '✕' : '${s.ping}ms', style: TextStyle(color: s.ping == -1 ? Colors.red : gold)),
                        onTap: () => setState(() => sel = i),
                      ),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}
