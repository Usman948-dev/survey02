import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sqflite/sqflite.dart';

const sky = Color(0xFF1E9BE8);
const kMinPhotos = 1, kMaxPhotos = 20, kMinChecks = 2;
const _ch = MethodChannel('survey/carrier');

void main() => runApp(MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Transformer Survey',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: sky, primary: sky, onPrimary: Colors.white),
        inputDecorationTheme: InputDecorationTheme(
            filled: true, fillColor: const Color(0xFFF8F8F8), border: OutlineInputBorder(borderRadius: BorderRadius.circular(18))),
      ),
      home: const Home(),
    ));

// ---------------- field labels / options ----------------
const lbl = {
  'subdiv': 'Subdivision', 'appId': 'APP ID', 'fCode': 'Feeder Code', 'fName': 'Feeder Name', 'lat': 'Latitude', 'lng': 'Longitude',
  'cond': 'Transformer Condition', 'tCode': 'Transformer Code', 'tName': 'Transformer Name', 'pole': 'Pole Type',
  'stype': 'Structure Subtype', 'ttype': 'Transformer Type', 'tNo': 'Transformer number', 'conns': 'Number of Connections',
  'addr': 'Transformer address', 'make': 'Transformer make', 'model': 'Transformer model', 'rating': 'Transformer Rating',
  'earth': 'Earthing Available?', 'box': 'Box installation space', 'avail': 'Installation availability',
  'exist': 'Existing cable available (Out-Going)', 'ecType': 'Existing Cable Type (Out-Going)',
  'ecSize': 'Existing Cable Size (Out-Going)', 'ecLen': 'Existing Cable Length (m) (Out-Going)', 'creq': 'Cable required',
  'ctype': 'Required Cable Type', 'csize': 'Required Cable Size (mm)', 'clen': 'Estimated cable length (m)',
  'loadok': 'Load check possible', 'ldA': 'Running load entry A (A)', 'ldB': 'Running load entry B (A)',
  'ldC': 'Running load entry C (A)', 'scan': 'Scanning Meter Installed?', 'comments': 'Comments / Remarks',
};
const yn = ['Yes', 'No'];
const cores = ['1-Core', '2-Core', '3-Core', '4-Core'];
const opts = {
  'cond': ['New', 'Reclaimed', 'Repaired', 'No Transformer'],
  'pole': ['Structure pole', 'Spun pole'],
  'stype': ['HT Type', 'LT Type'],
  'ttype': ['Distribution Load', 'Industrial Load', 'Commercial Load', 'Agriculture Load'],
  'rating': ['10', '15', '25', '50', '75', '100', '200', '315', '400'],
  'ctype': cores,
  'ecType': cores,
};
const opN = {'zong': 'Zong', 'uf': 'Ufone / Telenor', 'jz': 'Jazz / Warid'};
const opB = {'zong': 'ZONG', 'uf': 'UFONE/TELENOR', 'jz': 'JAZZ/WARID'};
const opM = {'zong': ['zong', 'cmpak'], 'uf': ['ufone', 'telenor', 'pak telecom'], 'jz': ['jazz', 'mobilink', 'warid']};
const opC = {'zong': Color(0xFF7AB800), 'uf': Color(0xFFF58220), 'jz': Color(0xFFD71920)};
const sig = {
  'Excellent': Icons.signal_cellular_alt,
  'Good': Icons.signal_cellular_alt_2_bar,
  'Poor': Icons.signal_cellular_alt_1_bar,
  'No Signal': Icons.signal_cellular_nodata,
};
String quality(num kbps) => kbps <= 0 ? 'No Signal' : kbps >= 5000 ? 'Excellent' : kbps >= 1500 ? 'Good' : 'Poor';
String speedText(dynamic s, dynamic g) =>
    s == null ? 'Not checked' : (s as num) <= 0 ? '0 kbps · No Signal' : '${(s / 1000).toStringAsFixed(2)} Mbps · $g';
String idOf(dynamic v) => (v ?? '').toString().split('-').first.trim();

// ---------------- Database (SQLite on the phone; photos stored as WebP blobs) ----------------
const _refSql = 'CREATE TABLE ref(sc TEXT,sn TEXT,app TEXT,fc TEXT,fn TEXT)';

class Db {
  static Database? _d;
  static Future<Database> get() async => _d ??= await openDatabase('${await getDatabasesPath()}/survey.db',
          version: 2,
          onCreate: (db, _) async {
            await db.execute('CREATE TABLE surveys(id INTEGER PRIMARY KEY AUTOINCREMENT,status TEXT,data TEXT,updated INTEGER)');
            await db.execute('CREATE TABLE photos(id INTEGER PRIMARY KEY AUTOINCREMENT,survey_id INTEGER,img BLOB)');
            await db.execute(_refSql);
          },
          onUpgrade: (db, o, n) async {
            if (o < 2) await db.execute(_refSql);
          });

  static Future<List<Map<String, Object?>>> list() async => (await get()).rawQuery(
      'SELECT s.*,(SELECT COUNT(*) FROM photos WHERE survey_id=s.id) c FROM surveys s ORDER BY updated DESC');

  static Future<Map<String, Object?>?> one(int id) async {
    final r = await (await get()).query('surveys', where: 'id=?', whereArgs: [id]);
    return r.isEmpty ? null : r.first;
  }

  static Future<List<Uint8List>> photos(int id) async => [
        for (final r in await (await get()).query('photos', where: 'survey_id=?', whereArgs: [id], orderBy: 'id')) r['img'] as Uint8List
      ];

  static Future<int> save(int? id, String status, Map d, List<Uint8List>? ph) async {
    final db = await get();
    final row = {'status': status, 'data': jsonEncode(d), 'updated': DateTime.now().millisecondsSinceEpoch};
    if (id == null) {
      id = await db.insert('surveys', row);
    } else {
      await db.update('surveys', row, where: 'id=?', whereArgs: [id]);
    }
    if (ph != null) {
      await db.delete('photos', where: 'survey_id=?', whereArgs: [id]);
      for (final b in ph) {
        await db.insert('photos', {'survey_id': id, 'img': b});
      }
    }
    return id;
  }

  static Future<void> delete(int id) async {
    final db = await get();
    await db.delete('photos', where: 'survey_id=?', whereArgs: [id]);
    await db.delete('surveys', where: 'id=?', whereArgs: [id]);
  }

  static Future<void> deleteAll() async {
    final db = await get();
    await db.delete('photos');
    await db.delete('surveys');
  }

  // other saved surveys (for duplicate checks)
  static Future<List<Map<String, dynamic>>> saved(int? except) async => [
        for (final r in await (await get()).query('surveys', where: "status='saved' AND id!=?", whereArgs: [except ?? -1]))
          Map<String, dynamic>.from(jsonDecode(r['data'] as String))
      ];

  // reference data (subdivisions / APP IDs / feeders) imported from a file
  static Future<int> refCount() async => Sqflite.firstIntValue(await (await get()).rawQuery('SELECT COUNT(*) FROM ref')) ?? 0;
  static Future<List<Map<String, Object?>>> refSubs() async =>
      (await get()).rawQuery('SELECT DISTINCT sc,sn FROM ref ORDER BY sc');
  static Future<List<Map<String, Object?>>> refApps(String sc) async =>
      (await get()).query('ref', where: 'sc=?', whereArgs: [sc], orderBy: 'app');
  static Future<void> setRef(List<Map<String, String>> rows) async {
    final db = await get();
    await db.delete('ref');
    final b = db.batch();
    for (final r in rows) {
      b.insert('ref', r);
    }
    await b.commit(noResult: true);
  }
}

List<Map<String, String>> parseRef(String text) {
  var t = text.replaceAll('\uFEFF', '').trim();
  final List<Map<String, String>> rows = [];
  if (t.startsWith('[') || t.startsWith('{')) {
    final j = jsonDecode(t);
    final list = j is List ? j : ((j['data'] ?? j['references'] ?? j['items'] ?? []) as List);
    for (final e in list) {
      rows.add((e as Map).map((k, v) => MapEntry(k.toString().toLowerCase(), v.toString())));
    }
  } else {
    final ls = t.split(RegExp(r'\r?\n')).where((l) => l.trim().isNotEmpty).toList();
    final h = ls.first.split(',').map((e) => e.trim().toLowerCase()).toList();
    for (final l in ls.skip(1)) {
      final c = l.split(',');
      final m = <String, String>{};
      for (int i = 0; i < h.length && i < c.length; i++) {
        m[h[i]] = c[i].trim();
      }
      rows.add(m);
    }
  }
  final out = <Map<String, String>>[];
  for (final r in rows) {
    final app = r['app_id'] ?? r['appid'] ?? r['app'] ?? '';
    final sc = r['subdivision_code'] ?? r['sc'] ?? '';
    if (app.isEmpty || sc.isEmpty) continue;
    out.add({'sc': sc, 'sn': r['subdivision_name'] ?? r['sn'] ?? '', 'app': app, 'fc': r['feeder_code'] ?? r['fc'] ?? '', 'fn': r['feeder_name'] ?? r['fn'] ?? ''});
  }
  return out;
}

Future<bool> ask(BuildContext c, String t, String yes) async =>
    await showDialog<bool>(
        context: c,
        builder: (x) => AlertDialog(title: Text(t), actions: [
              TextButton(onPressed: () => Navigator.pop(x, false), child: const Text('CANCEL')),
              FilledButton(onPressed: () => Navigator.pop(x, true), child: Text(yes)),
            ])) ??
    false;

Future<int?> pickIdx(BuildContext c, String title, List<String> items) => showDialog<int>(
    context: c,
    builder: (x) {
      String q = '';
      return StatefulBuilder(builder: (x, set) {
        final idx = [for (int i = 0; i < items.length; i++) if (items[i].toLowerCase().contains(q)) i];
        return AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: double.maxFinite,
            height: 380,
            child: Column(children: [
              TextField(decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search'), onChanged: (v) => set(() => q = v.toLowerCase())),
              const SizedBox(height: 8),
              Expanded(child: ListView(children: [for (final i in idx) ListTile(dense: true, title: Text(items[i]), onTap: () => Navigator.pop(x, i))])),
            ]),
          ),
        );
      });
    });

// ---------------- Home: overview, search, list, delete ----------------
class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  List<Map<String, Object?>> rows = [];
  String q = '';
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final r = await Db.list();
    if (mounted) setState(() => rows = r);
  }

  void snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> open([int? id]) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => SurveyPage(id: id)));
    load();
  }

  Future<void> detail(int id) async {
    final r = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => DetailPage(id: id)));
    if (r == 'edit') await open(id);
    load();
  }

  Future<void> importRef() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['json', 'csv'], withData: true);
    final b = r?.files.single.bytes;
    if (b == null) return;
    try {
      final rows = parseRef(utf8.decode(b));
      if (rows.isEmpty) throw 'no valid rows (need subdivision_code, app_id, feeder_code, feeder_name)';
      await Db.setRef(rows);
      snack('Feeder data imported: ${rows.length} records');
    } catch (e) {
      snack('Feeder data import failed: $e');
    }
  }

  Future<void> menu(int v) async {
    if (v == 0) return importRef();
    if (v == 1 && await ask(context, 'Clear imported feeder data?', 'CLEAR')) {
      await Db.setRef([]);
      snack('Feeder data cleared');
    }
    if (v == 2 && await ask(context, 'Delete ALL surveys and photographs?', 'DELETE ALL')) {
      await Db.deleteAll();
      load();
    }
    if (v == 3) {
      showAboutDialog(context: context, applicationName: 'Transformer Survey', applicationVersion: '1.0.0',
          children: [Text('Fully offline. ${await Db.refCount()} feeder records loaded.')]);
    }
  }

  Widget stat(String l, int n) => Expanded(
      child: Card(
          elevation: 0,
          color: const Color(0xFFE8F4FD),
          child: Padding(padding: const EdgeInsets.all(10), child: Column(children: [Text('$n', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)), Text(l)]))));

  @override
  Widget build(BuildContext context) {
    final shown = rows.where((r) {
      final d = jsonDecode(r['data'] as String) as Map;
      return '${d['appId']} ${d['fName']} ${d['tName']} ${r['status']}'.toLowerCase().contains(q);
    }).toList();
    final drafts = rows.where((r) => r['status'] == 'draft').length;
    return Scaffold(
      appBar: AppBar(backgroundColor: sky, foregroundColor: Colors.white, title: const Text('Survey Overview'), actions: [
        PopupMenuButton<int>(
          onSelected: menu,
          itemBuilder: (_) => const [
            PopupMenuItem(value: 0, child: Text('Import feeder data (CSV/JSON)')),
            PopupMenuItem(value: 1, child: Text('Clear feeder data')),
            PopupMenuItem(value: 2, child: Text('Delete all surveys')),
            PopupMenuItem(value: 3, child: Text('About')),
          ],
        )
      ]),
      body: Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 0), child: Row(children: [stat('Total', rows.length), stat('Drafts', drafts), stat('Saved', rows.length - drafts)])),
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search APP ID, feeder name, or status'), onChanged: (v) => setState(() => q = v.toLowerCase())),
        ),
        Expanded(
          child: shown.isEmpty
              ? Center(child: Text(rows.isEmpty ? 'No surveys yet' : 'No matching surveys.'))
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 90),
                  itemCount: shown.length,
                  itemBuilder: (_, i) {
                    final r = shown[i];
                    final d = jsonDecode(r['data'] as String) as Map<String, dynamic>;
                    final id = r['id'] as int;
                    final draft = r['status'] == 'draft';
                    final t = DateTime.fromMillisecondsSinceEpoch(r['updated'] as int).toString().substring(0, 16);
                    return Card(
                      child: ListTile(
                        onTap: () => draft ? open(id) : detail(id),
                        leading: Icon(draft ? Icons.edit_note : Icons.check_circle, color: draft ? Colors.orange : Colors.green),
                        title: Text('${idOf(d['appId'])} • ${d['fName'] ?? ''}'),
                        subtitle: Text('${draft ? 'Draft' : 'Saved'} • ${d['addr'] ?? ''}\n${r['c']} photographs • $t'),
                        isThreeLine: true,
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            if (await ask(context, 'Delete this survey and its photographs?', 'DELETE')) {
                              await Db.delete(id);
                              load();
                            }
                          },
                        ),
                      ),
                    );
                  }),
        ),
      ]),
      floatingActionButton: FloatingActionButton.extended(backgroundColor: sky, foregroundColor: Colors.white, onPressed: () => open(), icon: const Icon(Icons.add), label: const Text('NEW SURVEY')),
    );
  }
}

// ---------------- Survey details ----------------
class DetailPage extends StatefulWidget {
  final int id;
  const DetailPage({super.key, required this.id});
  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  Map<String, dynamic> d = {};
  List<Uint8List> ph = [];
  @override
  void initState() {
    super.initState();
    () async {
      final r = await Db.one(widget.id);
      final p = await Db.photos(widget.id);
      if (mounted && r != null) setState(() {
            d = Map<String, dynamic>.from(jsonDecode(r['data'] as String));
            ph = p;
          });
    }();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(backgroundColor: sky, foregroundColor: Colors.white, title: const Text('Survey details')),
        body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
          for (final e in lbl.entries)
            if ('${d[e.key] ?? ''}'.isNotEmpty) ListTile(dense: true, title: Text(e.value, style: const TextStyle(fontSize: 12, color: Colors.black54)), subtitle: Text('${d[e.key]}', style: const TextStyle(fontSize: 16, color: Colors.black87))),
          for (final k in opN.keys)
            ListTile(dense: true, title: Text(opN[k]!, style: const TextStyle(fontSize: 12, color: Colors.black54)), subtitle: Text('${speedText(d['${k}_s'], d['${k}_n'])}   ${d['${k}_q'] ?? ''}', style: const TextStyle(fontSize: 16, color: Colors.black87))),
          Padding(
            padding: const EdgeInsets.all(12),
            child: GridView.count(
              crossAxisCount: 2, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), mainAxisSpacing: 8, crossAxisSpacing: 8,
              children: [for (final b in ph) Image.memory(b, fit: BoxFit.cover, cacheWidth: 400)],
            ),
          ),
        ]),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Expanded(
                  child: OutlinedButton.icon(
                      onPressed: () async {
                        if (await ask(context, 'Delete this survey and its photographs?', 'DELETE')) {
                          await Db.delete(widget.id);
                          if (mounted) Navigator.pop(context);
                        }
                      },
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('DELETE'))),
              const SizedBox(width: 8),
              Expanded(child: FilledButton.icon(onPressed: () => Navigator.pop(context, 'edit'), icon: const Icon(Icons.edit), label: const Text('EDIT SURVEY'))),
            ]),
          ),
        ),
      );
}

// ---------------- Survey form (4 steps) ----------------
class SurveyPage extends StatefulWidget {
  final int? id;
  const SurveyPage({super.key, this.id});
  @override
  State<SurveyPage> createState() => _SurveyPageState();
}

class _SurveyPageState extends State<SurveyPage> {
  int? id;
  String status = 'draft';
  Map<String, dynamic> d = {};
  List<Uint8List> photos = [];
  int step = 0, rev = 0, refN = 0;
  bool dirty = false, busy = false, loading = false;
  String? testing;
  DateTime? retained;
  Timer? deb;
  final sc = ScrollController();

  @override
  void initState() {
    super.initState();
    id = widget.id;
    Db.refCount().then((n) {
      if (mounted) setState(() => refN = n);
    });
    if (id != null) {
      _load();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => gps(auto: true));
    }
  }

  @override
  void dispose() {
    deb?.cancel();
    sc.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => loading = true);
    final r = await Db.one(id!);
    final p = await Db.photos(id!);
    if (!mounted) return;
    setState(() {
      if (r != null) {
        d = Map<String, dynamic>.from(jsonDecode(r['data'] as String));
        status = r['status'] as String;
      }
      photos = p;
      loading = false;
      rev++;
    });
  }

  String _s(String k) => (d[k] ?? '').toString().trim();
  String hms(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
  void snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  Future<void> info(String t, String m) => showDialog(context: context, builder: (c) => AlertDialog(title: Text(t), content: Text(m), actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))]));
  void touch() {
    deb?.cancel();
    deb = Timer(const Duration(seconds: 2), () => saveDraft(silent: true));
  }

  int get checks => opN.keys.where((k) => d['${k}_s'] != null).length;
  bool get draftable => ['subdiv', 'appId', 'fCode', 'fName', 'lat', 'lng'].every((k) => _s(k).isNotEmpty);

  Future<void> saveDraft({bool silent = false}) async {
    if (!draftable) {
      if (!silent) snack('Draft cannot be saved. Select the subdivision and APP ID, and make sure feeder and GPS location details are available.');
      return;
    }
    id = await Db.save(id, status, d, dirty ? photos : null);
    dirty = false;
    if (!mounted) return;
    setState(() => retained = DateTime.now());
    if (!silent) snack('Draft saved offline.');
  }

  Future<void> exit() async {
    deb?.cancel();
    await saveDraft(silent: true);
    if (mounted) Navigator.pop(context);
  }

  // ---- validation ----
  List<String> need(int s) {
    switch (s) {
      case 0:
        return ['subdiv', 'appId', 'fCode', 'fName', 'lat', 'lng', 'cond', 'tCode', 'tName', 'pole', 'stype', 'ttype', 'tNo', 'conns', 'addr', 'make', 'model', 'rating'];
      case 1:
        return ['box', 'avail', 'exist', ...(d['exist'] == 'Yes' ? ['ecType', 'ecSize', 'ecLen'] : ['ctype', 'csize', 'clen'])];
      case 2:
        return ['loadok', 'scan', if (d['loadok'] == 'Yes') ...['ldA', 'ldB', 'ldC']];
      default:
        return ['comments'];
    }
  }

  Future<String?> check(int s) async {
    for (final k in need(s)) {
      if (_s(k).isEmpty) return '${lbl[k]} is required';
    }
    if (s == 0) {
      if (!RegExp(r'^\d{14}$').hasMatch(_s('tName'))) return 'Transformer Name must be exactly 14 digits';
      for (final o in await Db.saved(id)) {
        if (idOf(o['appId']) == idOf(d['appId'])) return 'APP ID ${idOf(d['appId'])} already exists in a saved survey. Select another feeder.';
        if ('${o['tCode']}' == _s('tCode')) return 'Transformer code ${_s('tCode')} already exists in a saved survey. Enter a unique code.';
        if ('${o['tNo']}' == _s('tNo')) return 'Transformer number ${_s('tNo')} already exists in a saved survey. Enter a unique number.';
      }
    }
    if (s == 2) {
      for (final k in opN.keys) {
        if (d['${k}_s'] != null && _s('${k}_q').isEmpty) return 'Signal strength is required (${opN[k]})';
      }
    }
    if (s == 3) {
      if (photos.length < kMinPhotos) return 'At least one photograph is required.';
      if (checks < kMinChecks) return 'Operator data-rate checks incomplete ($checks/$kMinChecks). Go back to step 3 and run them.';
    }
    return null;
  }

  Future<void> next() async {
    final e = await check(step);
    if (e != null) return snack(e);
    if (step == 3) return review();
    setState(() => step++);
    if (sc.hasClients) sc.jumpTo(0);
    saveDraft(silent: true);
  }

  Future<void> review() async {
    final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
              title: const Text('Review survey'),
              content: Text('APP ID: ${idOf(d['appId'])}\nSubdivision: ${idOf(d['subdiv'])}\nFeeder: ${_s('fCode')} — ${_s('fName')}\nGPS: ${_s('lat')}, ${_s('lng')}\nPhotographs: ${photos.length}\nOperator checks completed: $checks'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('BACK')),
                FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('SAVE')),
              ],
            ));
    if (ok != true) return;
    deb?.cancel();
    status = 'saved';
    id = await Db.save(id, 'saved', d, photos);
    if (!mounted) return;
    final m = ScaffoldMessenger.of(context);
    Navigator.pop(context);
    m.showSnackBar(const SnackBar(content: Text('Survey saved')));
  }

  Future<void> reset() async {
    if (!await ask(context, 'Reset form? All entered fields, operator results and photographs will be cleared.', 'RESET')) return;
    setState(() {
      d.clear();
      photos.clear();
      dirty = true;
      step = 0;
      rev++;
    });
    gps(auto: true);
  }

  // ---- GPS ----
  Future<void> gps({bool auto = false}) async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        if (!mounted) return;
        if (await ask(context, 'GPS/location services are turned off. Turn them on to capture the survey coordinates automatically.', 'TURN ON GPS')) {
          await Geolocator.openLocationSettings();
          if (mounted) snack('GPS is still off. Turn it on, then tap the GPS marker.');
        }
        return;
      }
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
      if (p == LocationPermission.denied || p == LocationPermission.deniedForever) return snack('Access to the location of the device is denied by the user.');
      final pos = await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, timeLimit: Duration(seconds: 30)));
      if (!mounted) return;
      setState(() {
        d['lat'] = pos.latitude.toString();
        d['lng'] = pos.longitude.toString();
        rev++;
      });
      snack('GPS captured (±${pos.accuracy.round()} m)');
      touch();
    } catch (e) {
      if (!auto && mounted) snack('GPS failed: $e');
    }
  }

  // ---- feeder reference pickers ----
  Future<void> pickSub() async {
    final subs = await Db.refSubs();
    if (!mounted) return;
    final i = await pickIdx(context, 'Select Subdivision', [for (final s in subs) '${s['sc']}-${s['sn']}']);
    if (i == null) return;
    setState(() {
      d['subdiv'] = '${subs[i]['sc']}-${subs[i]['sn']}';
      for (final k in ['appId', 'fCode', 'fName']) {
        d.remove(k);
      }
      rev++;
    });
    touch();
  }

  Future<void> pickApp() async {
    if (_s('subdiv').isEmpty) return snack('Select a subdivision first.');
    final apps = await Db.refApps(idOf(d['subdiv']));
    if (!mounted) return;
    final i = await pickIdx(context, 'Select APP ID', [for (final a in apps) '${a['app']}-${a['fn']}']);
    if (i == null) return;
    setState(() {
      d['appId'] = '${apps[i]['app']}-${apps[i]['fn']}';
      d['fCode'] = '${apps[i]['fc']}';
      d['fName'] = '${apps[i]['fn']}';
      rev++;
    });
    touch();
  }

  // ---- operator data-rate check (SIM aware) ----
  void setOp(String k, num kbps, String gen) {
    d['${k}_s'] = kbps;
    d['${k}_n'] = gen;
    d['${k}_q'] = quality(kbps);
  }

  Future<double> download() async {
    final sw = Stopwatch()..start();
    final r = await http.get(Uri.parse('https://speed.cloudflare.com/__down?bytes=3000000')).timeout(const Duration(seconds: 25));
    sw.stop();
    if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
    return r.bodyBytes.length * 8 / 1000 / (sw.elapsedMilliseconds / 1000);
  }

  Future<void> speed(String k) async {
    final name = opN[k]!;
    if (!(await Permission.phone.request()).isGranted) return snack('Phone permission is required to detect the SIM.');
    setState(() => testing = k);
    try {
      final conn = await Connectivity().checkConnectivity();
      if (conn.contains(ConnectivityResult.wifi)) return info('Turn Wi-Fi off', 'Turn Wi-Fi off, enable $name SIM mobile data, then tap Check data rate again.');
      if (!conn.contains(ConnectivityResult.mobile)) return info('Mobile data required', 'Mobile data is turned off. Enable the selected $name SIM mobile data, then tap Check data rate again.');
      final inf = Map<String, dynamic>.from(await _ch.invokeMethod('info'));
      final carrier = '${inf['carrier']}'.toLowerCase();
      if (!opM[k]!.any(carrier.contains)) {
        return info('Different SIM detected', 'Insert and activate the recommended $name SIM, then run this check again. Final Review & Save is blocked until it is completed. You may save a draft.');
      }
      final gen = '${inf['gen']}';
      if (gen == 'NONE') {
        setState(() => setOp(k, 0, 'No Signal'));
        touch();
        return info('No service', 'SIM has no registered cellular service: saved as 0 kbps / No Signal.');
      }
      if (gen == '5G') {
        setState(() => setOp(k, 0, 'No Signal'));
        touch();
        return info('5G not allowed', 'Only 2G, 3G, and 4G checks are allowed. The result has been set to 0 kbps / No Signal.');
      }
      double? kb;
      bool sock = false;
      for (int i = 0; i < 2 && kb == null; i++) {
        try {
          kb = await download();
        } on SocketException {
          sock = true;
        } catch (_) {
          sock = false;
        }
      }
      if (kb == null) {
        if (sock) {
          setState(() => setOp(k, 0, 'No Signal'));
          touch();
          return info('Network unusable', 'Cellular network is unusable after retry: saved as 0 kbps / No Signal.');
        }
        return info('Speed check failed', 'Cellular service is available, but the speed check failed after retry. No result was recorded. Please try again.');
      }
      setState(() => setOp(k, kb!, gen));
      touch();
    } on PlatformException catch (e) {
      snack('Could not read SIM info: ${e.message}');
    } finally {
      if (mounted) setState(() => testing = null);
    }
  }

  // ---- photos (camera only, converted to WebP before storing) ----
  Future<void> takePhoto() async {
    if (photos.length >= kMaxPhotos) return snack('Maximum $kMaxPhotos photographs allowed.');
    final f = await ImagePicker().pickImage(source: ImageSource.camera);
    if (f == null) return;
    setState(() => busy = true);
    final b = await FlutterImageCompress.compressWithFile(f.path, format: CompressFormat.webp, quality: 80, minWidth: 1280, minHeight: 1280);
    if (!mounted) return;
    setState(() {
      if (b != null) photos.add(b);
      busy = false;
      dirty = true;
    });
    touch();
  }

  // ---- widgets ----
  String lab(String k) => k == 'earth' ? lbl[k]! : '${lbl[k]} *';

  Widget tx(String k, {TextInputType? kt, int? max, bool ro = false, int lines = 1, String? helper, VoidCallback? pick}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextFormField(
          key: ValueKey('$k$rev'),
          initialValue: d[k]?.toString(),
          readOnly: ro || (pick != null && refN > 0),
          onTap: pick != null && refN > 0 ? pick : null,
          keyboardType: kt,
          maxLength: max,
          maxLines: lines,
          decoration: InputDecoration(
            labelText: lab(k),
            helperText: helper,
            counterText: max == null ? '' : null,
            suffixIcon: pick == null ? null : IconButton(icon: const Icon(Icons.search), onPressed: refN > 0 ? pick : () => snack('No feeder data imported. Import it from the home menu, or type manually.')),
          ),
          onChanged: (v) {
            d[k] = v;
            touch();
          },
        ),
      );

  Widget dd(String k, List<String> items, {void Function(String)? on}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: DropdownButtonFormField<String>(
          key: ValueKey('$k$rev'),
          value: items.contains(d[k]) ? d[k] as String : null,
          isExpanded: true,
          hint: const Text('Select'),
          decoration: InputDecoration(labelText: lab(k)),
          items: [for (final e in items) DropdownMenuItem(value: e, child: Text(e))],
          onChanged: (v) {
            setState(() {
              d[k] = v;
              on?.call(v!);
            });
            touch();
          },
        ),
      );

  Widget card(String t, List<Widget> c) => Card(
        elevation: 0,
        color: Colors.white,
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: Colors.black12)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(t, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)), const SizedBox(height: 12), ...c]),
        ),
      );

  Widget op(String k) {
    final q = d['${k}_q'];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Center(child: Padding(padding: const EdgeInsets.all(8), child: Text(opN[k]!, style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: opC[k])))),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(opN[k]!, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        Text(speedText(d['${k}_s'], d['${k}_n'])),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        for (final e in sig.entries)
          Expanded(
            child: InkWell(
              onTap: () {
                setState(() => d['${k}_q'] = e.key);
                touch();
              },
              child: Column(children: [
                Icon(e.value, size: 44, color: q == e.key ? sky : Colors.grey),
                Icon(q == e.key ? Icons.radio_button_checked : Icons.radio_button_unchecked, color: q == e.key ? sky : Colors.grey),
                Text(e.key, style: const TextStyle(fontSize: 13)),
              ]),
            ),
          )
      ]),
      const SizedBox(height: 8),
      SizedBox(
        width: double.infinity,
        child: FilledButton.tonalIcon(
          onPressed: testing == null ? () => speed(k) : null,
          icon: testing == k ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.speed),
          label: Text('CHECK ${opB[k]} DATA RATE'),
        ),
      ),
      const Divider(height: 32),
    ]);
  }

  List<Widget> body() {
    switch (step) {
      case 0:
        return [
          card('Feeder and Location', [
            tx('subdiv', pick: pickSub),
            tx('appId', pick: pickApp),
            Row(children: [
              Expanded(child: tx('fCode', ro: refN > 0)),
              const SizedBox(width: 8),
              Expanded(child: tx('fName', ro: refN > 0)),
            ]),
            Row(children: [
              Expanded(child: tx('lat', ro: true)),
              const SizedBox(width: 8),
              Expanded(child: tx('lng', ro: true)),
              IconButton.filledTonal(onPressed: gps, icon: const Icon(Icons.location_on)),
            ]),
          ]),
          card('Transformer', [
            dd('cond', opts['cond']!),
            tx('tCode'),
            tx('tName', kt: TextInputType.number, max: 14, helper: 'Enter exactly 14 digits'),
            dd('pole', opts['pole']!),
            dd('stype', opts['stype']!),
            dd('ttype', opts['ttype']!),
            tx('tNo', kt: TextInputType.number),
            tx('conns', kt: TextInputType.number),
            tx('addr'),
            tx('make'),
            tx('model'),
            dd('rating', opts['rating']!),
            dd('earth', yn),
          ]),
        ];
      case 1:
        return [
          card('Installation and cable', [
            dd('box', yn),
            dd('avail', yn),
            dd('exist', yn, on: (v) {
              d['creq'] = v == 'No' ? 'Yes' : 'No';
              rev++;
            }),
            if (d['exist'] == 'Yes') ...[
              dd('ecType', opts['ecType']!),
              tx('ecSize'),
              tx('ecLen', kt: TextInputType.number),
            ],
            if (d['exist'] != null) tx('creq', ro: true),
            if (d['exist'] == 'No') ...[
              dd('ctype', opts['ctype']!),
              tx('csize'),
              tx('clen', kt: TextInputType.number),
            ],
          ]),
        ];
      case 2:
        const dec = TextInputType.numberWithOptions(decimal: true);
        return [
          card('Load', [
            dd('loadok', yn),
            if (d['loadok'] == 'Yes') ...[tx('ldA', kt: dec), tx('ldB', kt: dec), tx('ldC', kt: dec)],
            dd('scan', yn),
          ]),
          card('2G / 3G / 4G operator data rate', [
            const Text('Turn Wi-Fi off and enable the selected SIM mobile data before each check.'),
            const SizedBox(height: 8),
            for (final k in opN.keys) op(k),
          ]),
        ];
      default:
        return [
          card('Photographs ($kMinPhotos–$kMaxPhotos)', [
            Row(children: [
              Icon(Icons.verified, color: photos.length >= kMinPhotos ? Colors.green : Colors.grey),
              const SizedBox(width: 8),
              Text('${photos.length}/$kMaxPhotos photograph files available', style: const TextStyle(fontSize: 16)),
            ]),
            const SizedBox(height: 12),
            GridView.count(
              crossAxisCount: 2, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), mainAxisSpacing: 8, crossAxisSpacing: 8,
              children: [
                for (int i = 0; i < photos.length; i++)
                  Stack(fit: StackFit.expand, children: [
                    Image.memory(photos[i], fit: BoxFit.cover, cacheWidth: 400, gaplessPlayback: true),
                    Positioned(left: 6, bottom: 6, child: Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), color: Colors.black54, child: Text('Photograph ${i + 1}', style: const TextStyle(color: Colors.white, fontSize: 12)))),
                    Positioned(
                      top: 4, right: 4,
                      child: IconButton.filledTonal(
                        icon: const Icon(Icons.delete),
                        onPressed: () {
                          setState(() {
                            photos.removeAt(i);
                            dirty = true;
                          });
                          touch();
                        },
                      ),
                    ),
                  ]),
              ],
            ),
            const SizedBox(height: 12),
            if (busy) const LinearProgressIndicator(),
            SizedBox(width: double.infinity, child: OutlinedButton.icon(onPressed: busy ? null : takePhoto, icon: const Icon(Icons.photo_camera), label: const Text('TAKE PHOTOGRAPH'))),
          ]),
          card('Comments and Review', [
            tx('comments', lines: 4),
            SizedBox(width: double.infinity, child: OutlinedButton.icon(onPressed: reset, icon: const Icon(Icons.restart_alt), label: const Text('RESET FORM'))),
          ]),
        ];
    }
  }

  @override
  Widget build(BuildContext context) {
    const white = Colors.white;
    final header = Container(
      color: sky,
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(8, MediaQuery.of(context).padding.top + 8, 8, 12),
      child: Column(children: [
        Row(children: [IconButton(icon: const Icon(Icons.arrow_back, color: white), onPressed: exit), Text(widget.id == null ? 'New Survey' : 'Edit Survey', style: const TextStyle(color: white, fontSize: 24))]),
        Text('Step ${step + 1} of 4', style: const TextStyle(color: Colors.white70, fontSize: 17)),
        Text(retained == null ? 'Not saved yet' : 'Retained locally at ${hms(retained!)}', style: const TextStyle(color: Colors.white70, fontSize: 13)),
      ]),
    );
    final stepper = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Row(children: [
        for (int i = 0; i < 4; i++) ...[
          if (i > 0) Expanded(child: Container(height: 3, color: i <= step ? sky : Colors.black12)),
          CircleAvatar(
            radius: 18,
            backgroundColor: i <= step ? sky : Colors.grey.shade300,
            child: i < step ? const Icon(Icons.check, color: white, size: 20) : Text('${i + 1}', style: TextStyle(color: i == step ? white : Colors.black54, fontWeight: FontWeight.bold)),
          ),
        ]
      ]),
    );
    final bar = Material(
      elevation: 8,
      color: white,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            if (step > 0) ...[
              IconButton.outlined(
                  onPressed: () {
                    setState(() => step--);
                    if (sc.hasClients) sc.jumpTo(0);
                  },
                  icon: const Icon(Icons.arrow_back)),
              const SizedBox(width: 8),
            ],
            Expanded(child: OutlinedButton.icon(style: OutlinedButton.styleFrom(minimumSize: const Size(0, 52)), onPressed: () => saveDraft(), icon: const Icon(Icons.save), label: const Text('SAVE DRAFT'))),
            const SizedBox(width: 8),
            Expanded(child: FilledButton.icon(style: FilledButton.styleFrom(minimumSize: const Size(0, 52)), onPressed: next, icon: Icon(step == 3 ? Icons.fact_check : Icons.arrow_forward), label: Text(step == 3 ? 'REVIEW & SAVE' : 'CONTINUE'))),
          ]),
        ),
      ),
    );
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (p, _) {
        if (!p && testing == null) exit();
      },
      child: Scaffold(
        backgroundColor: white,
        bottomNavigationBar: AbsorbPointer(absorbing: testing != null, child: bar),
        body: Column(children: [
          header,
          stepper,
          if (testing != null) Container(width: double.infinity, color: const Color(0xFFE8F4FD), padding: const EdgeInsets.all(10), child: const Text('Please wait. All form actions are disabled until the check finishes.')),
          Expanded(
            child: AbsorbPointer(
              absorbing: testing != null,
              child: loading ? const Center(child: CircularProgressIndicator()) : ListView(controller: sc, padding: const EdgeInsets.only(bottom: 24), children: body()),
            ),
          ),
        ]),
      ),
    );
  }
}
