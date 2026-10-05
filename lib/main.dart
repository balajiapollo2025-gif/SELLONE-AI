import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

void main() => runApp(const SellOneApp());

class SellOneApp extends StatelessWidget {
  const SellOneApp({super.key});
  @override
  Widget build(BuildContext c) => MaterialApp(
        title: 'SELLONE AI',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xFF6C47FF)),
        darkTheme: ThemeData(useMaterial3: true, brightness: Brightness.dark, colorSchemeSeed: const Color(0xFF6C47FF)),
        home: const Shell(),
      );
}

// ---------- Local storage (Phase 1: on-device; replace with API/PostgreSQL later) ----------
class Store {
  static List<Map<String, dynamic>> products = [];
  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    products = (jsonDecode(p.getString('products') ?? '[]') as List).map((e) => Map<String, dynamic>.from(e)).toList();
  }
  static Future<void> save() async =>
      (await SharedPreferences.getInstance()).setString('products', jsonEncode(products));
}

// ---------- AI service (provider-independent: swap this class) ----------
class Ai {
  static const _s = FlutterSecureStorage();
  static Future<String?> key() => _s.read(key: 'ak');
  static Future<void> setKey(String k) => _s.write(key: 'ak', value: k);

  static Future<Map<String, dynamic>> analyze(File? img, String lang, String tone, String hint) async {
    final k = await key();
    if (k == null || k.isEmpty) throw 'Settings లో API key పెట్టండి';
    final content = <Map<String, dynamic>>[];
    if (img != null) {
      content.add({'type': 'image', 'source': {'type': 'base64', 'media_type': 'image/jpeg', 'data': base64Encode(await img.readAsBytes())}});
    }
    content.add({'type': 'text', 'text':
        'You are an e-commerce listing expert for Indian sellers. Analyze the product ${img != null ? "in the image" : "described"}: $hint. '
        'Language: $lang. Tone: $tone. Do NOT invent uncertain info (brand/material only if clearly visible). '
        'Reply ONLY JSON: {"title":"","short":"","desc":"","keywords":[""],"category":"","attrs":{"color":"","material":""},"conf":{"title":0.0,"cat":0.0,"attrs":0.0}}'});
    final r = await http.post(Uri.parse('https://api.anthropic.com/v1/messages'),
        headers: {'x-api-key': k, 'anthropic-version': '2023-06-01', 'content-type': 'application/json'},
        body: jsonEncode({'model': 'claude-sonnet-5-5', 'max_tokens': 1500, 'messages': [{'role': 'user', 'content': content}]}));
    if (r.statusCode != 200) throw 'AI error ${r.statusCode}';
    final t = (jsonDecode(utf8.decode(r.bodyBytes))['content'] as List).firstWhere((b) => b['type'] == 'text')['text'] as String;
    return jsonDecode(t.substring(t.indexOf('{'), t.lastIndexOf('}') + 1));
  }
}

// ---------- Shell ----------
class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int i = 0;
  bool ready = false;
  @override
  void initState() {
    super.initState();
    Store.load().then((_) => setState(() => ready = true));
  }
  void refresh() => setState(() {});
  @override
  Widget build(BuildContext c) {
    if (!ready) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final pages = <Widget>[const HomePage(), AddPage(onSaved: refresh), ProductsPage(onChanged: refresh), StockPage(onChanged: refresh), const SettingsPage()];
    return Scaffold(
      appBar: AppBar(title: const Text('SELLONE AI', style: TextStyle(fontWeight: FontWeight.w800))),
      body: SafeArea(child: pages[i]),
      bottomNavigationBar: NavigationBar(selectedIndex: i, onDestinationSelected: (v) => setState(() => i = v), destinations: const [
        NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
        NavigationDestination(icon: Icon(Icons.add_a_photo), label: 'Add'),
        NavigationDestination(icon: Icon(Icons.inventory_2), label: 'Products'),
        NavigationDestination(icon: Icon(Icons.bar_chart), label: 'Stock'),
        NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
      ]),
    );
  }
}

Widget stat(String l, String v) => Card(
    child: SizedBox(width: 160, child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(v, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)), Text(l)]))));

class HomePage extends StatelessWidget {
  const HomePage({super.key});
  @override
  Widget build(BuildContext c) {
    final p = Store.products;
    final low = p.where((x) => x['stock'] <= 20).length;
    final val = p.fold<num>(0, (a, x) => a + x['price'] * x['stock']);
    final pubs = p.fold<int>(0, (a, x) => a + (x['pub'] as Map).values.where((s) => s == 'Published').length);
    return ListView(padding: const EdgeInsets.all(16), children: [
      const Text('CREATE ONCE. SELL EVERYWHERE.', style: TextStyle(fontWeight: FontWeight.w700)),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        stat('Total Products', '${p.length}'), stat('Low Stock', '$low'),
        stat('Listings Published', '$pubs'), stat('Inventory Value', '₹${val.toStringAsFixed(0)}')]),
    ]);
  }
}

// ---------- Add product: Photo -> AI -> Edit -> Publish ----------
class AddPage extends StatefulWidget {
  final VoidCallback onSaved;
  const AddPage({super.key, required this.onSaved});
  @override
  State<AddPage> createState() => _AddPageState();
}

class _AddPageState extends State<AddPage> {
  final c = {for (final k in ['title', 'short', 'desc', 'kw', 'cat', 'attrs', 'price', 'stock', 'sku', 'hsn']) k: TextEditingController()};
  File? img;
  Map conf = {};
  String lang = 'English', tone = 'Professional', msg = '';
  bool busy = false;
  final mps = <String>{'Amazon', 'Flipkart'};
  List<String> results = [];

  Future<void> pick(ImageSource s) async {
    final x = await ImagePicker().pickImage(source: s, maxWidth: 1024, imageQuality: 70);
    if (x != null) setState(() => img = File(x.path));
  }

  Future<void> analyze() async {
    if (img == null && c['title']!.text.isEmpty) { setState(() => msg = 'ముందు ఫోటో తీయండి'); return; }
    setState(() { busy = true; msg = 'AI analyze చేస్తోంది…'; });
    try {
      final j = await Ai.analyze(img, lang, tone, c['title']!.text);
      c['title']!.text = '${j['title'] ?? ''}';
      c['short']!.text = '${j['short'] ?? ''}';
      c['desc']!.text = '${j['desc'] ?? ''}';
      c['cat']!.text = '${j['category'] ?? ''}';
      c['kw']!.text = ((j['keywords'] as List?) ?? []).join(', ');
      c['attrs']!.text = ((j['attrs'] as Map?) ?? {}).entries.where((e) => '${e.value}'.isNotEmpty).map((e) => '${e.key}: ${e.value}').join(', ');
      conf = (j['conf'] as Map?) ?? {};
      msg = '✔ Product detected — check చేసి edit చేయండి';
    } catch (e) { msg = '$e'; }
    setState(() => busy = false);
  }

  List<String> issues(String m) {
    final x = <String>[];
    if (c['title']!.text.isEmpty) x.add('Title');
    if (img == null) x.add('Image');
    if ((num.tryParse(c['price']!.text) ?? 0) <= 0) x.add('Price');
    if (num.tryParse(c['stock']!.text) == null) x.add('Stock');
    if (c['sku']!.text.isEmpty) x.add('SKU');
    if (m != 'Meesho' && c['hsn']!.text.isEmpty) x.add('HSN');
    return x;
  }

  Future<void> publish() async {
    if (mps.isEmpty) return;
    setState(() => results = ['Publishing…']);
    final pub = <String, String>{};
    // Each marketplace publishes independently (demo adapters - replace with real connectors)
    final out = await Future.wait(mps.map((m) async {
      await Future.delayed(Duration(milliseconds: 800 + m.length * 120));
      final i = issues(m);
      pub[m] = i.isEmpty ? 'Published' : 'Failed';
      return i.isEmpty ? '$m — ✅ Published (demo)' : '$m — ❌ Failed: missing ${i.join(", ")}';
    }));
    if (pub.containsValue('Published')) {
      Store.products.insert(0, {'title': c['title']!.text, 'sku': c['sku']!.text, 'price': num.parse(c['price']!.text), 'stock': int.parse(c['stock']!.text), 'img': img?.path, 'pub': pub});
      await Store.save();
      widget.onSaved();
    }
    setState(() => results = out);
  }

  Widget fld(String k, String l, {int lines = 1, bool num = false}) {
    final cf = conf[k];
    return Padding(padding: const EdgeInsets.only(top: 10), child: TextField(
        controller: c[k], maxLines: lines, keyboardType: num ? TextInputType.number : null,
        decoration: InputDecoration(labelText: l, border: const OutlineInputBorder(),
               helperText: ((cf is int || cf is double) && cf < 0.6) ? 'Please verify this information.' : null,
            helperStyle: const TextStyle(color: Colors.orange))));
  }

  @override
  Widget build(BuildContext ctx) => ListView(padding: const EdgeInsets.all(16), children: [
        if (img != null) ClipRRect(borderRadius: BorderRadius.circular(16), child: Image.file(img!, height: 200, fit: BoxFit.cover)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: FilledButton.icon(onPressed: () => pick(ImageSource.camera), icon: const Icon(Icons.camera_alt), label: const Text('Take Photo'))),
          const SizedBox(width: 8),
          Expanded(child: OutlinedButton.icon(onPressed: () => pick(ImageSource.gallery), icon: const Icon(Icons.photo), label: const Text('Upload'))),
        ]),
        Row(children: [
          DropdownButton<String>(value: lang, items: ['English', 'Telugu', 'Hindi'].map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(), onChanged: (v) => setState(() => lang = v!)),
          const SizedBox(width: 16),
          DropdownButton<String>(value: tone, items: ['Professional', 'Simple', 'Marketing', 'Premium'].map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(), onChanged: (v) => setState(() => tone = v!)),
        ]),
        FilledButton.icon(onPressed: busy ? null : analyze, icon: const Icon(Icons.auto_awesome), label: const Text('AI Analyze / Regenerate')),
        if (msg.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(msg)),
        fld('title', 'Title'), fld('short', 'Short description'), fld('desc', 'Detailed description', lines: 4),
        fld('kw', 'SEO keywords'), fld('cat', 'Category'), fld('attrs', 'Attributes'),
        Row(children: [Expanded(child: fld('price', 'Price ₹', num: true)), const SizedBox(width: 8), Expanded(child: fld('stock', 'Stock', num: true))]),
        Row(children: [Expanded(child: fld('sku', 'SKU')), const SizedBox(width: 8), Expanded(child: fld('hsn', 'HSN'))]),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: ['Amazon', 'Flipkart', 'Meesho'].map((m) => FilterChip(label: Text(m), selected: mps.contains(m), onSelected: (v) => setState(() => v ? mps.add(m) : mps.remove(m)))).toList()),
        ...mps.map((m) { final i = issues(m); return Text('$m — ${i.isEmpty ? "Ready" : "Missing ${i.join(", ")}"}', style: TextStyle(color: i.isEmpty ? Colors.green : Colors.orange)); }),
        const SizedBox(height: 8),
        FilledButton(onPressed: publish, style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)), child: const Text('🚀 PUBLISH TO ALL', style: TextStyle(fontSize: 18))),
        ...results.map((r) => Padding(padding: const EdgeInsets.only(top: 6), child: Text(r))),
      ]);
}

class ProductsPage extends StatelessWidget {
  final VoidCallback onChanged;
  const ProductsPage({super.key, required this.onChanged});
  @override
  Widget build(BuildContext c) => Store.products.isEmpty
      ? const Center(child: Text('Inka products levu'))
      : ListView(children: [
          for (var i = 0; i < Store.products.length; i++)
            ListTile(
              leading: Store.products[i]['img'] != null && File(Store.products[i]['img']).existsSync() ? Image.file(File(Store.products[i]['img']), width: 48, height: 48, fit: BoxFit.cover) : const Icon(Icons.image),
              title: Text(Store.products[i]['title']),
              subtitle: Text('₹${Store.products[i]['price']} · Stock ${Store.products[i]['stock']} · ${(Store.products[i]['pub'] as Map).entries.map((e) => "${e.key}:${e.value}").join(", ")}'),
              trailing: IconButton(icon: const Icon(Icons.delete), onPressed: () async { Store.products.removeAt(i); await Store.save(); onChanged(); }),
            )
        ]);
}

class StockPage extends StatelessWidget {
  final VoidCallback onChanged;
  const StockPage({super.key, required this.onChanged});
  (String, Color) lvl(int s) => s <= 0 ? ('Out of Stock', Colors.red) : s <= 5 ? ('Critical', Colors.red) : s <= 20 ? ('Warning', Colors.orange) : ('Normal', Colors.green);
  @override
  Widget build(BuildContext c) => ListView(children: [
        for (final p in Store.products)
          ListTile(
            title: Text(p['title']),
            subtitle: Text('${p['stock']} · ${lvl(p['stock']).$1}', style: TextStyle(color: lvl(p['stock']).$2)),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(icon: const Icon(Icons.remove_circle_outline), onPressed: () async { if (p['stock'] > 0) p['stock']--; await Store.save(); onChanged(); }),
              IconButton(icon: const Icon(Icons.add_circle_outline), onPressed: () async { p['stock']++; await Store.save(); onChanged(); }),
            ]),
          )
      ]);
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsState();
}

class _SettingsState extends State<SettingsPage> {
  final k = TextEditingController();
  String m = '';
  @override
  Widget build(BuildContext c) => ListView(padding: const EdgeInsets.all(16), children: [
        const Text('AI API key (Anthropic)', style: TextStyle(fontWeight: FontWeight.bold)),
        TextField(controller: k, obscureText: true, decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'sk-ant-...')),
        const SizedBox(height: 8),
        FilledButton(onPressed: () async { await Ai.setKey(k.text.trim()); setState(() => m = 'Saved ✔'); }, child: const Text('Save')),
        Text(m),
        const SizedBox(height: 16),
        const Text('Note: production lo API key app lo ledu — mee own backend server dwara AI call cheyyali.'),
      ]);
}
