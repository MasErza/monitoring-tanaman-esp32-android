import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart'; // Tambahkan import ini

void main() {
  runApp(const SmartIrrigationApp());
}

class SmartIrrigationApp extends StatelessWidget {
  const SmartIrrigationApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Monitoring Tanaman',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2E7D32),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF5F7F2),
        useMaterial3: true,
        cardTheme: const CardThemeData(
          elevation: 0,
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
          ),
        ),
      ),
      home: const MonitoringPage(),
    );
  }
}

class MonitoringPage extends StatefulWidget {
  const MonitoringPage({super.key});

  @override
  State<MonitoringPage> createState() => _MonitoringPageState();
}

class _MonitoringPageState extends State<MonitoringPage> {
  final TextEditingController _ipController = TextEditingController(
    text: '192.168.1.100',
  );

  Timer? _timer;
  SensorData? _data;
  final List<ActivityLogEntry> _activityLogs = <ActivityLogEntry>[];
  bool _loading = false;
  bool _relayBusy = false;
  bool _requestInFlight = false;

  String _lastDeviceState = '';
  String? _error;
  DateTime? _lastUpdate;
  DateTime? _pausePollingUntil;

  @override
  void initState() {
    super.initState();
    _loadLogsFromStorage(); // Muat log lama saat aplikasi pertama dibuka
    _fetchData();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _fetchData());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ipController.dispose();
    super.dispose();
  }

  // =========================================================
  // LOGIKA PENYIMPANAN LOKAL (SHARED PREFERENCES)
  // =========================================================

  // 1. Fungsi untuk Memuat Log saat Aplikasi Dibuka
  Future<void> _loadLogsFromStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? savedLogsJson = prefs.getString('activity_logs_key');

      if (savedLogsJson != null) {
        final List<dynamic> decodedList =
            jsonDecode(savedLogsJson) as List<dynamic>;
        setState(() {
          _activityLogs.clear();
          for (final dynamic item in decodedList) {
            _activityLogs.add(
              ActivityLogEntry.fromJson(item as Map<String, dynamic>),
            );
          }
          // Set state terakhir dari log paling atas agar tidak double log saat refresh pertama
          if (_activityLogs.isNotEmpty) {
            final msg = _activityLogs.first.message.toLowerCase();
            if (msg.contains('menyiram')) {
              _lastDeviceState = 'Menyiram';
            } else if (msg.contains('monitoring'))
              _lastDeviceState = 'Monitoring';
            else if (msg.contains('hidupkan paksa'))
              _lastDeviceState = 'Manual ON';
            else if (msg.contains('dimatikan'))
              _lastDeviceState = 'Manual OFF';
          }
        });
      }
    } catch (e) {
      debugPrint('Gagal memuat log: $e');
    }
  }

  // 2. Fungsi untuk Menyimpan Perubahan Log ke Storage
  Future<void> _saveLogsToStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final List<Map<String, dynamic>> jsonList = _activityLogs
          .map((log) => log.toJson())
          .toList();
      await prefs.setString('activity_logs_key', jsonEncode(jsonList));
    } catch (e) {
      debugPrint('Gagal menyimpan log: $e');
    }
  }

  // 3. Fungsi untuk Menghapus Semua Log di Storage
  Future<void> _clearLogsFromStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('activity_logs_key');
      setState(() {
        _activityLogs.clear();
        _lastDeviceState = '';
      });
    } catch (e) {
      debugPrint('Gagal menghapus log: $e');
    }
  }

  Uri _uri(String path) {
    var host = _ipController.text.trim();
    if (host.startsWith('http://')) {
      host = host.substring(7);
    } else if (host.startsWith('https://'))
      host = host.substring(8);
    host = host.split('/').first;
    return Uri.parse('http://$host$path');
  }

  Future<void> _fetchData({bool force = false}) async {
    if (_requestInFlight) return;
    if (_relayBusy && !force) return;
    if (_pausePollingUntil != null &&
        !force &&
        DateTime.now().isBefore(_pausePollingUntil!)) {
      return;
    }

    if (_ipController.text.trim().isEmpty) {
      setState(() => _error = 'Masukkan IP ESP32 terlebih dahulu');
      return;
    }

    _requestInFlight = true;
    setState(() => _loading = true);

    final uri = _uri('/data');

    try {
      final response = await _get(uri);
      final body = jsonDecode(response) as Map<String, dynamic>;
      final nextData = SensorData.fromJson(body);

      setState(() {
        _data = nextData;
        _lastUpdate = DateTime.now();
        _error = null;
        _recordActivityIfNeeded(nextData);
      });
    } catch (error) {
      setState(() => _error = _connectionErrorMessage(uri, error));
    } finally {
      _requestInFlight = false;
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<String> _get(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 10));
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}', uri: uri);
      }
      return body;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _setRelay(bool on) async {
    if (_relayBusy || _requestInFlight) return;

    setState(() => _relayBusy = true);
    final uri = _uri(on ? '/relay/on' : '/relay/off');

    try {
      await _get(uri);
      _pausePollingUntil = DateTime.now().add(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 900));
      await _fetchData(force: true);
    } catch (error) {
      setState(() => _error = _connectionErrorMessage(uri, error));
    } finally {
      if (mounted) setState(() => _relayBusy = false);
    }
  }

  void _recordActivityIfNeeded(SensorData data) {
    String currentState = '';

    if (data.mode.toLowerCase() == 'manual') {
      currentState = data.statusPompa;
    } else {
      if (data.statusPompa.toLowerCase().startsWith('nyiram') ||
          data.statusPompa.toLowerCase() == 'menyiram') {
        currentState = 'Menyiram';
      } else {
        currentState = 'Monitoring';
      }
    }

    if (_lastDeviceState.isNotEmpty && currentState != _lastDeviceState) {
      String logMessage = '';
      IconData logIcon = Icons.info_outline;
      Color iconColor = Colors.grey;

      if (currentState == 'Menyiram') {
        String sisaDetik = data.statusPompa.replaceAll(RegExp(r'[^0-9]'), '');
        String durasiText = sisaDetik.isNotEmpty
            ? 'selama ~$sisaDetik detik'
            : 'otomatis';

        logMessage =
            'Menyiram $durasiText (Tanah: ${data.statusTanah}, Suhu: ${data.statusSuhu})';
        logIcon = Icons.water_drop;
        iconColor = Colors.blue;
      } else if (currentState == 'Monitoring') {
        logMessage = 'Kembali ke mode Monitoring / Standby';
        logIcon = Icons.visibility;
        iconColor = const Color(0xFF2E7D32);
      } else if (currentState == 'Manual ON') {
        logMessage = 'Pompa dihidupkan paksa (Mode Manual)';
        logIcon = Icons.power_settings_new;
        iconColor = Colors.orange;
      } else if (currentState == 'Manual OFF') {
        logMessage = 'Pompa dimatikan (Mode Manual)';
        logIcon = Icons.power_off;
        iconColor = Colors.red;
      }

      setState(() {
        _activityLogs.insert(
          0,
          ActivityLogEntry(
            time: DateTime.now(),
            message: logMessage,
            icon: logIcon,
            iconColor: iconColor,
          ),
        );
        if (_activityLogs.length > 50) {
          _activityLogs.removeLast();
        }
      });

      _saveLogsToStorage(); // Pemicu penyimpanan otomatis setiap ada log baru
    } else if (_lastDeviceState.isEmpty && _activityLogs.isEmpty) {
      setState(() {
        _activityLogs.insert(
          0,
          ActivityLogEntry(
            time: DateTime.now(),
            message: 'Terhubung ke ESP32. Status: $currentState',
            icon: Icons.wifi,
            iconColor: const Color(0xFF0277BD),
          ),
        );
      });
      _saveLogsToStorage();
    }

    _lastDeviceState = currentState;
  }

  String _formatTime(DateTime value) {
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    final second = value.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }

  String _formatDateTime(DateTime value) {
    final day = value.day.toString().padLeft(2, '0');
    final month = value.month.toString().padLeft(2, '0');
    final year = value.year.toString();
    return '$day/$month/$year ${_formatTime(value)}';
  }

  String _connectionErrorMessage(Uri uri, Object error) {
    if (error is TimeoutException) return 'Timeout saat membuka $uri';
    if (error is SocketException) return 'Tidak ada koneksi ke $uri';
    if (error is HttpException) return 'ESP32 merespons error';
    if (error is FormatException) return 'Respons bukan JSON yang valid';
    return 'Tidak bisa membuka koneksi';
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Monitoring Tanaman'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : () => _fetchData(),
            icon: _loading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _ConnectionPanel(
              controller: _ipController,
              onConnect: () => _fetchData(),
            ),
            const SizedBox(height: 16),
            if (_error != null) _ErrorBanner(message: _error!),
            if (_error != null) const SizedBox(height: 16),
            _GaugeCard(
              humidity: data?.kelembabanTanah ?? 0,
              soilStatus: data?.statusTanah ?? 'Menunggu data',
              deviceStatus: data?.statusAlat ?? 'Offline',
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _InfoCard(
                    icon: Icons.thermostat,
                    label: 'Suhu (${data?.statusSuhu ?? "-"})',
                    value: data != null ? '${data.suhu} °C' : '-',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _InfoCard(
                    icon: Icons.air,
                    label: 'Kel. Udara',
                    value: data != null ? '${data.kelembabanUdara} %' : '-',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _InfoCard(
                    icon: Icons.water_drop,
                    label: 'Pompa',
                    value: data?.statusPompa ?? 'Belum terhubung',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _InfoCard(
                    icon: Icons.access_time,
                    label: 'Update',
                    value: _lastUpdate == null
                        ? '-'
                        : _formatTime(_lastUpdate!),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _RelayPanel(
              busy: _relayBusy,
              onRelayOn: () => _setRelay(true),
              onRelayOff: () => _setRelay(false),
            ),
            const SizedBox(height: 16),
            _ActivityLogPanel(
              logs: _activityLogs,
              formatDateTime: _formatDateTime,
              onClear: _activityLogs.isEmpty ? null : _clearLogsFromStorage,
            ),
          ],
        ),
      ),
    );
  }
}

class SensorData {
  const SensorData({
    required this.kelembabanTanah,
    required this.suhu,
    required this.kelembabanUdara,
    required this.statusTanah,
    required this.statusSuhu,
    required this.statusPompa,
    required this.mode,
    required this.statusAlat,
  });

  final int kelembabanTanah;
  final double suhu;
  final double kelembabanUdara;
  final String statusTanah;
  final String statusSuhu;
  final String statusPompa;
  final String mode;
  final String statusAlat;

  factory SensorData.fromJson(Map<String, dynamic> json) {
    return SensorData(
      kelembabanTanah: (json['kelembaban_tanah'] as num?)?.round() ?? 0,
      suhu: (json['suhu'] as num?)?.toDouble() ?? 0.0,
      kelembabanUdara: (json['kelembaban_udara'] as num?)?.toDouble() ?? 0.0,
      statusTanah: json['status_tanah']?.toString() ?? '-',
      statusSuhu: json['status_suhu']?.toString() ?? '-',
      statusPompa: json['status_pompa']?.toString() ?? '-',
      mode: json['mode']?.toString() ?? '-',
      statusAlat: json['status_alat']?.toString() ?? '-',
    );
  }
}

// === DIUBAH: MODEL LOG SEKARANG MEMILIKI FUNGSI PARSING JSON TO/FROM ===
class ActivityLogEntry {
  const ActivityLogEntry({
    required this.time,
    required this.message,
    required this.icon,
    required this.iconColor,
  });

  final DateTime time;
  final String message;
  final IconData icon;
  final Color iconColor;

  // Konversi Objek Log ke format JSON agar bisa disimpan di Shared Preferences
  Map<String, dynamic> toJson() {
    return {
      'time': time.toIso8601String(),
      'message': message,
      'iconCodePoint': icon.codePoint,
      'colorValue': iconColor.value,
    };
  }

  // Mengubah JSON kembali ke Objek Log saat aplikasi dibuka
  factory ActivityLogEntry.fromJson(Map<String, dynamic> json) {
    return ActivityLogEntry(
      time: DateTime.parse(json['time'] as String),
      message: json['message'] as String,
      // Jangan membuat IconData dari nilai dinamis. Pada build release Flutter
      // melakukan tree-shaking font ikon dan hanya mendukung ikon konstan.
      icon: _iconFromCodePoint(json['iconCodePoint'] as int?),
      iconColor: Color(json['colorValue'] as int), // Sudah diperbaiki
    );
  }

  static IconData _iconFromCodePoint(int? codePoint) {
    if (codePoint == Icons.water_drop.codePoint) return Icons.water_drop;
    if (codePoint == Icons.visibility.codePoint) return Icons.visibility;
    if (codePoint == Icons.power_settings_new.codePoint) {
      return Icons.power_settings_new;
    }
    if (codePoint == Icons.power_off.codePoint) return Icons.power_off;
    if (codePoint == Icons.wifi.codePoint) return Icons.wifi;
    return Icons.info_outline;
  }
}

// === KELAS WIDGET UI BERIKUTNYA TETAP SAMA SEPERTI KODE SEBELUMNYA ===
class _ConnectionPanel extends StatelessWidget {
  const _ConnectionPanel({required this.controller, required this.onConnect});
  final TextEditingController controller;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'IP ESP32',
                  hintText: 'Contoh: 192.168.1.25',
                  prefixIcon: Icon(Icons.router),
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => onConnect(),
              ),
            ),
            const SizedBox(width: 12),
            IconButton.filled(
              tooltip: 'Hubungkan',
              onPressed: onConnect,
              icon: const Icon(Icons.wifi_find),
            ),
          ],
        ),
      ),
    );
  }
}

class _GaugeCard extends StatelessWidget {
  const _GaugeCard({
    required this.humidity,
    required this.soilStatus,
    required this.deviceStatus,
  });
  final int humidity;
  final String soilStatus;
  final String deviceStatus;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Kelembaban Tanah',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                _StatusPill(
                  text: deviceStatus,
                  color: deviceStatus.toLowerCase() == 'online'
                      ? const Color(0xFF2E7D32)
                      : const Color(0xFFC62828),
                ),
              ],
            ),
            const SizedBox(height: 20),
            SizedBox(
              height: 210,
              child: CustomPaint(
                painter: _HumidityGaugePainter(humidity),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 42),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '$humidity%',
                          style: Theme.of(context).textTheme.displayMedium
                              ?.copyWith(
                                fontWeight: FontWeight.w800,
                                color: const Color(0xFF1B5E20),
                              ),
                        ),
                        Text(
                          soilStatus,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(color: const Color(0xFF4E5B4C)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [Text('Kering'), Text('Ideal'), Text('Basah')],
            ),
          ],
        ),
      ),
    );
  }
}

class _HumidityGaugePainter extends CustomPainter {
  const _HumidityGaugePainter(this.value);
  final int value;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height * 0.86);
    final radius = math.min(size.width * 0.42, size.height * 0.72);
    final rect = Rect.fromCircle(center: center, radius: radius);
    const startAngle = math.pi;
    const sweepAngle = math.pi;

    final basePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 18
      ..color = const Color(0xFFE2E7DD);

    final gradientPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 18
      ..shader = const SweepGradient(
        startAngle: math.pi,
        endAngle: math.pi * 2,
        colors: [
          Color(0xFFD84315),
          Color(0xFFF9A825),
          Color(0xFF2E7D32),
          Color(0xFF0277BD),
        ],
      ).createShader(rect);

    canvas.drawArc(rect, startAngle, sweepAngle, false, basePaint);
    canvas.drawArc(
      rect,
      startAngle,
      sweepAngle * (value.clamp(0, 100) / 100),
      false,
      gradientPaint,
    );

    final needleAngle = startAngle + sweepAngle * (value.clamp(0, 100) / 100);
    final needleLength = radius - 18;
    final needleEnd = Offset(
      center.dx + math.cos(needleAngle) * needleLength,
      center.dy + math.sin(needleAngle) * needleLength,
    );

    final needlePaint = Paint()
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFF263226);
    canvas.drawLine(center, needleEnd, needlePaint);
    canvas.drawCircle(center, 8, Paint()..color = const Color(0xFF263226));
  }

  @override
  bool shouldRepaint(covariant _HumidityGaugePainter oldDelegate) =>
      oldDelegate.value != value;
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.icon,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: const Color(0xFF2E7D32)),
            const SizedBox(height: 12),
            Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(color: const Color(0xFF657064)),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

class _RelayPanel extends StatelessWidget {
  const _RelayPanel({
    required this.busy,
    required this.onRelayOn,
    required this.onRelayOff,
  });
  final bool busy;
  final VoidCallback onRelayOn;
  final VoidCallback onRelayOff;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Kontrol Pompa',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: busy ? null : onRelayOn,
                    icon: const Icon(Icons.power_settings_new),
                    label: const Text('ON'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: busy ? null : onRelayOff,
                    icon: const Icon(Icons.power_off),
                    label: const Text('OFF'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ActivityLogPanel extends StatelessWidget {
  const _ActivityLogPanel({
    required this.logs,
    required this.formatDateTime,
    required this.onClear,
  });
  final List<ActivityLogEntry> logs;
  final String Function(DateTime value) formatDateTime;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Log Aktivitas Sistem',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Hapus log',
                  onPressed: onClear,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (logs.isEmpty)
              const _EmptyLogState()
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: logs.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final log = logs[index];
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      backgroundColor: log.iconColor.withOpacity(0.15),
                      foregroundColor: log.iconColor,
                      child: Icon(log.icon),
                    ),
                    title: Text(
                      log.message,
                      style: const TextStyle(fontSize: 14),
                    ),
                    subtitle: Text(
                      formatDateTime(log.time),
                      style: const TextStyle(fontSize: 12),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptyLogState extends StatelessWidget {
  const _EmptyLogState();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 18),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F4EF),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        'Belum ada aktivitas baru',
        textAlign: TextAlign.center,
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(color: const Color(0xFF657064)),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          text,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: color,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFFFEBEE),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFFFCDD2)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Icon(Icons.error_outline, color: Color(0xFFC62828)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(color: Color(0xFF8E2424)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
