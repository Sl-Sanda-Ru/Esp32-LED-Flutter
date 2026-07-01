import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

const String serviceUuid = "6e400001-b5a4-f393-e0a9-e50e24dcca9e";
const String rxUuid = "6e400002-b5a4-f393-e0a9-e50e24dcca9e";

void main() => runApp(const LedApp());

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

  void _startScan() {
    _results.clear();
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 6));
    FlutterBluePlus.scanResults.listen((results) {
      setState(() {
        _results
          ..clear()
          ..addAll(results.where((r) => r.device.platformName.isNotEmpty));
      });
    });
  }

  void _connect(BluetoothDevice device) async {
    await FlutterBluePlus.stopScan();
    await device.connect();
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ControlPage(device: device)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan for ESP32-LED')),
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

  @override
  void initState() {
    super.initState();
    _discoverServices();
  }

  Future<void> _discoverServices() async {
    final services = await widget.device.discoverServices();
    for (final s in services) {
      if (s.uuid.toString().toLowerCase() == serviceUuid) {
        for (final c in s.characteristics) {
          if (c.uuid.toString().toLowerCase() == rxUuid) {
            setState(() => _rxChar = c);
          }
        }
      }
    }
  }

  Future<void> _send(String command) async {
    if (_rxChar == null) return;
    await _rxChar!.write(utf8.encode(command), withoutResponse: true);
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
            icon: const Icon(Icons.power_off),
            onPressed: () => widget.device.disconnect(),
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
