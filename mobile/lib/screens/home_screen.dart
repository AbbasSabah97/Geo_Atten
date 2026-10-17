import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/api_service.dart';
import '../services/device_service.dart';
import '../services/location_service.dart';
import 'login_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _api = ApiService();
  final _device = DeviceService();
  final _location = LocationService();

  Map<String, dynamic>? _me;
  List<dynamic> _history = const [];
  bool _loading = true;
  bool _punching = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final me = await _api.me();
      final history = await _api.history();
      if (!mounted) return;
      setState(() {
        _me = me;
        _history = history;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.statusCode == 401) {
        await _logout();
        return;
      }
      setState(() => _loading = false);
      _show(e.message);
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        _show(e.toString().replaceFirst('Exception: ', ''));
      }
    }
  }

  Future<void> _punch(String eventType) async {
    setState(() => _punching = true);
    try {
      final locationResult = await _location.getVerifiedPosition();
      final deviceId = await _device.getOrCreateDeviceId();
      final p = locationResult.position;
      final result = await _api.punch(
        eventType: eventType,
        latitude: p.latitude,
        longitude: p.longitude,
        accuracyMeters: p.accuracy,
        isMocked: p.isMocked,
        deviceId: deviceId,
      );

      if (!mounted) return;
      final accepted = result['accepted'] == true;
      final distance = result['distance_meters'];
      _show(
        accepted
            ? 'تم تسجيل ${eventType == 'check_in' ? 'الحضور' : 'الانصراف'} بنجاح. المسافة: ${_fmtDistance(distance)}'
            : (result['reason']?.toString() ?? 'تم رفض العملية.'),
      );
      await _load();
    } catch (e) {
      if (mounted) _show(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _punching = false);
    }
  }

  String _fmtDistance(dynamic value) {
    if (value is num) return '${value.toStringAsFixed(1)} م';
    return '-';
  }

  Future<void> _logout() async {
    await _api.logout();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (_) => false,
    );
  }

  void _show(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('الحضور والانصراف'),
        actions: [
          IconButton(onPressed: _logout, icon: const Icon(Icons.logout)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _me?['name']?.toString() ?? 'الموظف',
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                          const SizedBox(height: 6),
                          Text('الرمز: ${_me?['employee_code'] ?? '-'}'),
                          Text('الموقع: ${_me?['worksite_name'] ?? '-'}'),
                          Text('النطاق: ${_me?['worksite_radius_meters'] ?? '-'} متر'),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _punching ? null : () => _punch('check_in'),
                          icon: const Icon(Icons.login_rounded),
                          label: const Padding(
                            padding: EdgeInsets.symmetric(vertical: 14),
                            child: Text('تسجيل الحضور'),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _punching ? null : () => _punch('check_out'),
                          icon: const Icon(Icons.logout_rounded),
                          label: const Padding(
                            padding: EdgeInsets.symmetric(vertical: 14),
                            child: Text('تسجيل الانصراف'),
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (_punching) ...[
                    const SizedBox(height: 16),
                    const LinearProgressIndicator(),
                    const SizedBox(height: 8),
                    const Text(
                      'جارٍ الحصول على موقع دقيق والتحقق من النطاق...',
                      textAlign: TextAlign.center,
                    ),
                  ],
                  const SizedBox(height: 24),
                  Text('آخر العمليات', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  if (_history.isEmpty)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(18),
                        child: Text('لا توجد عمليات مسجلة بعد.'),
                      ),
                    )
                  else
                    ..._history.take(10).map((item) {
                      final map = item as Map<String, dynamic>;
                      final createdAt = DateTime.tryParse(map['created_at']?.toString() ?? '');
                      final label = map['event_type'] == 'check_in' ? 'حضور' : 'انصراف';
                      final accepted = map['accepted'] == true;
                      return Card(
                        child: ListTile(
                          leading: Icon(
                            accepted ? Icons.check_circle_outline : Icons.cancel_outlined,
                          ),
                          title: Text('$label — ${accepted ? 'مقبول' : 'مرفوض'}'),
                          subtitle: Text(
                            '${createdAt == null ? '-' : DateFormat('yyyy-MM-dd HH:mm').format(createdAt.toLocal())}\n'
                            'المسافة: ${_fmtDistance(map['distance_meters'])}',
                          ),
                          isThreeLine: true,
                        ),
                      );
                    }),
                ],
              ),
            ),
    );
  }
}
