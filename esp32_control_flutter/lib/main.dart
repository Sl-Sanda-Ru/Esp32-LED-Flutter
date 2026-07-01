import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

const String serviceUuid = "6e400001-b5a4-f393-e0a9-e50e24dcca9e";
const String rxUuid = "6e400002-b5a4-f393-e0a9-e50e24dcca9e";

void main() => runApp(const LedApp());

enum LogLevel { info, send, recv, warn, error }

class LogEntry {
  final DateTime time;
  final LogLevel level;
  final String message;
  LogEntry(this.level, this.message) : time = DateTime.now();

  String get timeStr {
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    final s = time.second.toString().padLeft(2, '0');
    final ms = time.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }

  String get tag {
    switch (level) {
      case LogLevel.info:
        return 'INFO';
      case LogLevel.send:
        return 'SEND';
      case LogLevel.recv:
        return 'RECV';
      case LogLevel.warn:
        return 'WARN';
      case LogLevel.error:
        return 'ERR ';
    }
  }

  Color get color {
    switch (level) {
      case LogLevel.info:
        return Colors.lightBlueAccent;
      case LogLevel.send:
        return Colors.greenAccent;
      case LogLevel.recv:
        return Colors.amberAccent;
      case LogLevel.warn:
        return Colors.orangeAccent;
      case LogLevel.error:
        return Colors.redAccent;
    }
  }

  @override
  String toString() => '[$timeStr] $tag  $message';
}

class LogService extends ChangeNotifier {
  LogService._();
  static final LogService instance = LogService._();

  static const int _maxEntries = 500;
  final List<LogEntry> _entries = [];
  List<LogEntry> get entries => List.unmodifiable(_entries);

  void log(LogLevel level, String message) {
    final entry = LogEntry(level, message);
    _entries.add(entry);
    if (_entries.length > _maxEntries) {
      _entries.removeRange(0, _entries.length - _maxEntries);
    }
    // ignore: avoid_print
    print(entry);
    notifyListeners();
  }

  void info(String m) => log(LogLevel.info, m);
  void send(String m) => log(LogLevel.send, m);
  void recv(String m) => log(LogLevel.recv, m);
  void warn(String m) => log(LogLevel.warn, m);
  void error(String m) => log(LogLevel.error, m);

  void clear() {
    _entries.clear();
    notifyListeners();
  }

  String dumpText() => _entries.map((e) => e.toString()).join('\n');
}

class LedApp extends StatelessWidget {
  const LedApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ESP32 LED',
      theme: ThemeData.dark(),
      home: const ScanPage(),
    );
  }
}

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});
  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final List<ScanResult> _results = [];
  StreamSubscription<List<ScanResult>>? _scanSub;

  @override
  void initState() {
    super.initState();
    LogService.instance.info('App started. Ready to scan.');
  }

  void _startScan() {
    _results.clear();
    LogService.instance.info('Starting BLE scan (6s)...');
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 6));
    _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen(
      (results) {
        setState(() {
          _results
            ..clear()
            ..addAll(results.where((r) => r.device.platformName.isNotEmpty));
        });
        for (final r in results) {
          if (r.device.platformName.isNotEmpty) {
            LogService.instance.info(
              'Found "${r.device.platformName}" ${r.device.remoteId.str} (${r.rssi} dBm)',
            );
          }
        }
      },
      onError: (e) => LogService.instance.error('Scan error: $e'),
    );
  }

  void _connect(BluetoothDevice device) async {
    try {
      LogService.instance.info('Stopping scan.');
      await FlutterBluePlus.stopScan();
      LogService.instance.info('Connecting to ${device.platformName}...');
      await device.connect();
      LogService.instance.info('Connected to ${device.platformName}.');
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ControlPage(device: device)),
      );
    } catch (e) {
      LogService.instance.error('Connect failed: $e');
    }
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan for ESP32-LED'),
        actions: [
          IconButton(
            icon: const Icon(Icons.terminal),
            tooltip: 'Console',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ConsolePage()),
            ),
          ),
        ],
      ),
      body: ListView.builder(
        itemCount: _results.length,
        itemBuilder: (_, i) {
          final r = _results[i];
          return ListTile(
            title: Text(r.device.platformName),
            subtitle: Text(r.device.remoteId.str),
            trailing: Text('${r.rssi} dBm'),
            onTap: () => _connect(r.device),
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _startScan,
        child: const Icon(Icons.search),
      ),
    );
  }
}

class ControlPage extends StatefulWidget {
  final BluetoothDevice device;
  const ControlPage({super.key, required this.device});
  @override
  State<ControlPage> createState() => _ControlPageState();
}

class _ControlPageState extends State<ControlPage> {
  BluetoothCharacteristic? _rxChar;
  Color _pickedColor = Colors.green;
  double _brightness = 80;
  String _effect = 'SOLID';

  final List<String> _effects = ['SOLID', 'RAINBOW', 'BREATHE', 'PARTY'];

  Color? _pendingColor;
  bool _writing = false;
  DateTime _lastWrite = DateTime.fromMillisecondsSinceEpoch(0);
  static const _minWriteGap = Duration(milliseconds: 40);

  StreamSubscription<BluetoothConnectionState>? _connSub;

  @override
  void initState() {
    super.initState();
    _connSub = widget.device.connectionState.listen((s) {
      LogService.instance.info('Connection state: $s');
    });
    _discoverServices();
  }

  Future<void> _discoverServices() async {
    try {
      LogService.instance.info('Discovering services...');
      final services = await widget.device.discoverServices();
      LogService.instance.info('Found ${services.length} service(s).');
      for (final s in services) {
        if (s.uuid.toString().toLowerCase() == serviceUuid) {
          LogService.instance.info('Matched NUS service ${s.uuid}');
          for (final c in s.characteristics) {
            if (c.uuid.toString().toLowerCase() == rxUuid) {
              setState(() => _rxChar = c);
              LogService.instance.info('RX characteristic ready.');
            }
          }
        }
      }
      if (_rxChar == null) {
        LogService.instance.warn('RX characteristic not found on device.');
      }
    } catch (e) {
      LogService.instance.error('discoverServices failed: $e');
    }
  }

  Future<void> _send(String command) async {
    if (_rxChar == null) {
      LogService.instance.warn('Drop "$command" (no RX char).');
      return;
    }
    try {
      await _rxChar!.write(utf8.encode(command), withoutResponse: true);
      LogService.instance.send(command);
    } catch (e) {
      LogService.instance.error('Write "$command" failed: $e');
    }
  }

  void _onColorChanged(Color c) {
    setState(() => _pickedColor = c);
    _pendingColor = c;
    _flushColor();
  }

  Future<void> _flushColor() async {
    if (_writing || _pendingColor == null || _rxChar == null) return;
    final now = DateTime.now();
    final wait = _minWriteGap - now.difference(_lastWrite);
    if (wait > Duration.zero) {
      Timer(wait, _flushColor);
      return;
    }
    _writing = true;
    final c = _pendingColor!;
    _pendingColor = null;
    try {
      final cmd = _effect == 'BREATHE'
          ? 'BREATHE,${c.red},${c.green},${c.blue}'
          : 'RGB,${c.red},${c.green},${c.blue}';
      await _send(cmd);
      _lastWrite = DateTime.now();
    } finally {
      _writing = false;
      if (_pendingColor != null) _flushColor();
    }
  }

  void _applyEffect() {
    LogService.instance.info('Apply effect: $_effect');
    _send('BRI,${_brightness.round()}');
    final r = _pickedColor.red;
    final g = _pickedColor.green;
    final b = _pickedColor.blue;
    if (_effect == 'SOLID') _send('RGB,$r,$g,$b');
    if (_effect == 'BREATHE') _send('BREATHE,$r,$g,$b');
    if (_effect == 'RAINBOW') _send('RAINBOW');
    if (_effect == 'PARTY') _send('PARTY');
  }

  @override
  void dispose() {
    _connSub?.cancel();
    LogService.instance.info('Disconnecting ${widget.device.platformName}.');
    widget.device.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.device.platformName),
        actions: [
          IconButton(
            icon: const Icon(Icons.terminal),
            tooltip: 'Console',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ConsolePage()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.power_off),
            onPressed: () {
              LogService.instance.info('Manual disconnect requested.');
              widget.device.disconnect();
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 60,
              decoration: BoxDecoration(
                color: _pickedColor,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white24),
              ),
              alignment: Alignment.center,
              child: Text(
                '#${_pickedColor.value.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Center(
              child: HueRingPicker(
                pickerColor: _pickedColor,
                onColorChanged: _onColorChanged,
                enableAlpha: false,
                displayThumbColor: true,
                portraitOnly: true,
              ),
            ),
            const SizedBox(height: 8),
            Text('Brightness: ${_brightness.round()}'),
            Slider(
              value: _brightness,
              min: 0,
              max: 255,
              onChanged: (v) => setState(() => _brightness = v),
              onChangeEnd: (_) => _send('BRI,${_brightness.round()}'),
            ),
            const SizedBox(height: 8),
            const Text('Effect'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: _effects.map((e) {
                return ChoiceChip(
                  label: Text(e),
                  selected: _effect == e,
                  onSelected: (_) {
                    setState(() => _effect = e);
                    _applyEffect();
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _send('OFF'),
                    child: const Text('OFF'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _send('ON'),
                    child: const Text('ON'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            const Text('Presets'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                Colors.red,
                Colors.green,
                Colors.blue,
                Colors.yellow,
                Colors.cyan,
                Colors.purple,
                Colors.orange,
                Colors.pink,
                Colors.white,
              ].map((c) {
                return GestureDetector(
                  onTap: () => _onColorChanged(c),
                  child: CircleAvatar(backgroundColor: c, radius: 20),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

}

class ConsolePage extends StatefulWidget {
  const ConsolePage({super.key});
  @override
  State<ConsolePage> createState() => _ConsolePageState();
}

class _ConsolePageState extends State<ConsolePage> {
  final ScrollController _scroll = ScrollController();
  bool _autoScroll = true;
  LogLevel? _filter;

  @override
  void initState() {
    super.initState();
    LogService.instance.addListener(_onLogs);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  @override
  void dispose() {
    LogService.instance.removeListener(_onLogs);
    _scroll.dispose();
    super.dispose();
  }

  void _onLogs() {
    if (!mounted) return;
    setState(() {});
    if (_autoScroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
  }

  void _scrollToBottom() {
    if (!_scroll.hasClients) return;
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }

  @override
  Widget build(BuildContext context) {
    final all = LogService.instance.entries;
    final visible = _filter == null
        ? all
        : all.where((e) => e.level == _filter).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Console'),
        actions: [
          IconButton(
            tooltip: _autoScroll ? 'Auto-scroll on' : 'Auto-scroll off',
            icon: Icon(
              _autoScroll ? Icons.vertical_align_bottom : Icons.pause,
            ),
            onPressed: () => setState(() => _autoScroll = !_autoScroll),
          ),
          IconButton(
            tooltip: 'Copy all',
            icon: const Icon(Icons.copy),
            onPressed: () async {
              await Clipboard.setData(
                ClipboardData(text: LogService.instance.dumpText()),
              );
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Log copied to clipboard')),
              );
            },
          ),
          IconButton(
            tooltip: 'Clear',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => LogService.instance.clear(),
          ),
        ],
      ),
      body: Column(
        children: [
          SizedBox(
            height: 52,
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              scrollDirection: Axis.horizontal,
              children: [
                _filterChip('ALL', null),
                _filterChip('INFO', LogLevel.info),
                _filterChip('SEND', LogLevel.send),
                _filterChip('RECV', LogLevel.recv),
                _filterChip('WARN', LogLevel.warn),
                _filterChip('ERR', LogLevel.error),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: Container(
              color: Colors.black,
              child: visible.isEmpty
                  ? const Center(
                      child: Text(
                        'No logs yet.',
                        style: TextStyle(color: Colors.white54),
                      ),
                    )
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.all(8),
                      itemCount: visible.length,
                      itemBuilder: (_, i) {
                        final e = visible[i];
                        return SelectableText(
                          '[${e.timeStr}] ${e.tag}  ${e.message}',
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            color: e.color,
                            height: 1.35,
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterChip(String label, LogLevel? level) {
    final selected = _filter == level;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => setState(() => _filter = level),
      ),
    );
  }
}
