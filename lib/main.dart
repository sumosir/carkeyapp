import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 目标设备名称（必须与固件 BLE_DEVICE_NAME 一致）
const String _targetDeviceName = 'CarKey';

/// GATT 服务和特征 UUID（必须与固件一致）
final Guid _serviceUuid = Guid('0000fff0-0000-1000-8000-00805f9b34fb');
final Guid _controlCharUuid = Guid('0000fff2-0000-1000-8000-00805f9b34fb');

/// 控制指令
const int _cmdLock = 0x00;
const int _cmdUnlock = 0x01;
const int _cmdClearBond = 0x02;

/// SharedPreferences 中保存已绑定设备 ID 的键
const String _prefBoundDevice = 'bound_device_id';

/// 重连间隔（毫秒）
const int _reconnectIntervalMs = 3000;

/// 连续重连失败次数上限，超过则回到扫描
const int _maxReconnectAttempts = 3;

/// 单次扫描时长（秒）
const int _scanSeconds = 20;

void main() {
  runApp(const CarKeyApp());
}

class CarKeyApp extends StatelessWidget {
  const CarKeyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '车钥匙',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const CarKeyHomePage(),
    );
  }
}

/// 连接状态枚举
enum ConnState { idle, scanning, connecting, connected, disconnected }

class CarKeyHomePage extends StatefulWidget {
  const CarKeyHomePage({super.key});

  @override
  State<CarKeyHomePage> createState() => _CarKeyHomePageState();
}

class _CarKeyHomePageState extends State<CarKeyHomePage> {
  ConnState _state = ConnState.idle;
  BluetoothDevice? _device;
  BluetoothCharacteristic? _controlChar;
  int? _rssi;
  String _statusText = '等待启动...';
  String? _hint;
  bool _isBusy = false;

  /// 已绑定设备的唯一 ID（iOS 为 UUID，Android 为 MAC）
  String? _boundDeviceId;

  /// 扫描到的所有设备
  final Map<String, ScanResult> _found = {};

  /// 连接中标志，防止并发连接
  bool _connecting = false;

  /// 连续重连失败次数
  int _reconnectAttempts = 0;

  /// 本轮扫描是否至少看到过一次目标设备
  bool _sawTarget = false;

  Timer? _reconnectTimer;
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<BluetoothConnectionState>? _connSubscription;

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _scanSubscription?.cancel();
    _connSubscription?.cancel();
    super.dispose();
  }

  // ==================== 初始化 ====================

  Future<void> _initApp() async {
    // 1. 读取已绑定设备
    await _loadBoundDevice();

    // 2. 申请权限
    final granted = await _requestPermissions();
    if (!granted) {
      if (mounted) {
        setState(() => _hint = '蓝牙权限被拒绝\n请到 设置 → 车钥匙 → 打开蓝牙权限');
      }
      return;
    }

    // 3. 检查蓝牙并开始扫描
    await _ensureAdapterAndScan();
  }

  Future<void> _loadBoundDevice() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _boundDeviceId = prefs.getString(_prefBoundDevice);
      debugPrint('已绑定设备: $_boundDeviceId');
    } catch (_) {}
  }

  Future<void> _saveBoundDevice(String id) async {
    if (_boundDeviceId == id) return;
    _boundDeviceId = id;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefBoundDevice, id);
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<bool> _requestPermissions() async {
    if (defaultTargetPlatform == TargetPlatform.iOS) return true;

    final scan = await Permission.bluetoothScan.request();
    final connect = await Permission.bluetoothConnect.request();
    return scan.isGranted && connect.isGranted;
  }

  /// 检查蓝牙开关状态，正常则开始扫描
  Future<void> _ensureAdapterAndScan() async {
    BluetoothAdapterState adapterState;
    try {
      adapterState = await FlutterBluePlus.adapterState
          .firstWhere((s) => s != BluetoothAdapterState.unknown)
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      if (mounted) setState(() => _hint = '无法读取蓝牙状态: $e');
      return;
    }

    if (!mounted) return;

    if (adapterState == BluetoothAdapterState.unauthorized) {
      setState(() => _hint = '蓝牙权限被拒绝\n请到 设置 → 车钥匙 → 打开蓝牙权限');
      return;
    }
    if (adapterState != BluetoothAdapterState.on) {
      setState(() {
        _hint = '手机蓝牙未开启，请打开蓝牙后点「重新搜索」';
        _statusText = '蓝牙未开启';
      });
      return;
    }

    setState(() => _hint = null);
    await _startScan();
  }

  // ==================== 扫描 ====================

  /// 去掉空白/零宽字符并转小写，避免不可见字符导致匹配失败
  String _normalize(String s) =>
      s.replaceAll(RegExp(r'[\s\u200B-\u200D\uFEFF]'), '').toLowerCase();

  /// 名称匹配（platformName 在 iOS 上常为空，需同时看广播包名称）
  bool _isTarget(ScanResult r) {
    final target = _normalize(_targetDeviceName);
    return <String>[
      r.device.platformName,
      r.advertisementData.advName,
    ].any((raw) {
      final n = _normalize(raw);
      if (n.isEmpty) return false;
      // 双向包含：设备名可能被截断或带后缀
      return n == target ||
          n.contains(target) ||
          (n.length >= 4 && target.contains(n));
    });
  }

  Future<void> _startScan() async {
    if (_state == ConnState.scanning ||
        _state == ConnState.connecting ||
        _state == ConnState.connected) {
      return;
    }

    if (mounted) {
      setState(() {
        _state = ConnState.scanning;
        _statusText = _boundDeviceId == null ? '正在搜索 CarKey...' : '正在寻找已绑定的设备...';
        _hint = null;
        _found.clear();
        _sawTarget = false;
      });
    }

    _scanSubscription?.cancel();
    _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
      if (!mounted) return;

      setState(() {
        for (final r in results) {
          _found[r.device.remoteId.str] = r;
        }
      });

      if (_state != ConnState.scanning) return;

      for (final r in results) {
        final id = r.device.remoteId.str;
        final isBound = _boundDeviceId != null && id == _boundDeviceId;
        final isTarget = _isTarget(r);
        if (isTarget) _sawTarget = true;
        if (isBound || isTarget) {
          _connectToDevice(r.device);
          return;
        }
      }
    });

    try {
      await FlutterBluePlus.stopScan();
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: _scanSeconds),
        androidScanMode: AndroidScanMode.lowLatency,
        androidUsesFineLocation: false,
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _state = ConnState.idle;
          _hint = '扫描失败：$e';
        });
      }
      return;
    }

    if (mounted && _state == ConnState.scanning) {
      setState(() {
        _state = ConnState.idle;
        _statusText = _sawTarget ? '已发现 CarKey，但未连上' : '未发现 CarKey';
        if (_sawTarget) {
          _hint = '已发现 CarKey 但连接失败\n'
              '1. 确认没有其他手机连着它（开发板只支持 1 个连接）\n'
              '2. 若换过固件，请点「清除配对记录」后重试';
        } else if (_found.isEmpty) {
          _hint = '没有扫描到任何蓝牙设备\n'
              '1. 确认手机蓝牙已开启\n'
              '2. 确认开发板已通电\n'
              '3. 如果安卓手机正连着开发板，请先断开它（开发板只支持 1 个连接）';
        } else {
          _hint = '已发现 ${_found.length} 个其他蓝牙设备，但没有 CarKey\n'
              '开发板可能已被其他手机占用连接（此时会停止广播）\n'
              '请把安卓手机的蓝牙关掉后再试';
        }
      });
    }
  }

  // ==================== 连接 ====================

  Future<void> _connectToDevice(
    BluetoothDevice device, {
    bool autoConnect = false,
  }) async {
    if (_connecting || _state == ConnState.connected) return;
    _connecting = true;

    try {
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
      await _scanSubscription?.cancel();
      _scanSubscription = null;

      _device = device;
      if (mounted) {
        setState(() {
          _state = ConnState.connecting;
          _statusText = '正在连接...';
          _hint = null;
        });
      }

      await _connSubscription?.cancel();
      _connSubscription = device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.connected) {
          _onConnected();
        } else if (s == BluetoothConnectionState.disconnected) {
          _onDisconnected();
        }
      });

      // 先用普通方式连接（快）；失败再用 autoConnect（iOS 后台更可靠）
      bool ok = await _tryConnect(device, autoConnect);
      if (!ok) {
        if (mounted) setState(() => _statusText = '连接失败，重试中...');
        await Future.delayed(const Duration(seconds: 1));
        ok = await _tryConnect(device, true);
      }

      if (ok) {
        _reconnectAttempts = 0;
        return;
      }

      _reconnectAttempts++;
      if (mounted) {
        setState(() {
          _state = ConnState.idle;
          _statusText = '连接失败';
          _hint = null;
        });
      }
      await _showConnectFailedDialog();
      _scheduleReconnect();
    } finally {
      _connecting = false;
    }
  }

  /// 尝试连接一次，返回是否成功
  Future<bool> _tryConnect(BluetoothDevice device, bool autoConnect) async {
    try {
      await device.connect(
        autoConnect: autoConnect,
        timeout: const Duration(seconds: 10),
      );
      return true;
    } catch (e) {
      debugPrint('连接失败(autoConnect=$autoConnect): $e');
      return false;
    }
  }

  /// 连接失败提示
  Future<void> _showConnectFailedDialog() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('连接失败'),
        content: const Text(
          '1. 确认没有其他手机连着 CarKey（开发板只支持 1 个连接）\n\n'
          '2. 若换过固件，点「清除配对记录」，然后重新搜索\n\n'
          '3. 关掉手机蓝牙再打开，重新搜索',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _onConnected() async {
    if (_state == ConnState.connected) return;
    _reconnectTimer?.cancel();
    _reconnectAttempts = 0;

    // 记住这台设备，下次自动连接
    if (_device != null) {
      await _saveBoundDevice(_device!.remoteId.str);
    }

    // 发现服务，拿到控制特征
    _controlChar = null;
    try {
      final services = await _device!.discoverServices();
      for (final service in services) {
        if (service.uuid != _serviceUuid) continue;
        for (final char in service.characteristics) {
          if (char.uuid == _controlCharUuid) {
            _controlChar = char;
            debugPrint('已找到控制特征');
          }
        }
      }
    } catch (e) {
      debugPrint('发现服务失败: $e');
    }

    if (!mounted) return;
    setState(() {
      _state = ConnState.connected;
      _statusText = '已连接 — 靠近自动解锁';
      _hint = _controlChar == null ? '未找到控制特征，手动按钮可能不可用' : null;
    });

    _readRssi();
  }

  void _onDisconnected() {
    _controlChar = null;
    if (!mounted) return;
    setState(() {
      _state = ConnState.disconnected;
      _statusText = '已断开 — 远离自动上锁';
      _rssi = null;
    });
    _scheduleReconnect();
  }

  /// 断线重连：连续失败 3 次后回到扫描
  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(
      const Duration(milliseconds: _reconnectIntervalMs),
      () async {
        if (!mounted) return;

        if (_reconnectAttempts >= _maxReconnectAttempts) {
          _reconnectAttempts = 0;
          _device = null;
          await _startScan();
          return;
        }

        if (_device != null) {
          // autoConnect=true：iOS 会在后台持续尝试，回到范围内自动连上
          await _connectToDevice(_device!, autoConnect: true);
        } else {
          await _startScan();
        }
      },
    );
  }

  Future<void> _readRssi() async {
    while (mounted && _state == ConnState.connected && _device != null) {
      try {
        final rssi = await _device!.readRssi();
        if (mounted) setState(() => _rssi = rssi);
      } catch (_) {}
      await Future.delayed(const Duration(seconds: 2));
    }
  }

  // ==================== 控制 ====================

  Future<void> _sendCommand(int cmd) async {
    if (_controlChar == null || _state != ConnState.connected) {
      _toast('设备未连接，无法控制');
      return;
    }

    setState(() => _isBusy = true);
    try {
      await _controlChar!.write([cmd], withoutResponse: true);
      if (mounted) {
        setState(() => _statusText =
            cmd == _cmdUnlock ? '手动解锁' : '手动上锁');
      }
    } catch (e) {
      _toast('操作失败: $e');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  /// 清除开发板上的配对记录，并解除 App 的绑定
  Future<void> _clearBond() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除配对记录'),
        content: const Text(
          '将删除开发板中的所有蓝牙绑定，并解除本 App 的绑定。\n'
          '之后需要重新输入配对码 299450。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认清除'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    // 1. 通知开发板清除绑定
    if (_state == ConnState.connected && _controlChar != null) {
      try {
        await _controlChar!.write([_cmdClearBond], withoutResponse: true);
        await Future.delayed(const Duration(milliseconds: 300));
      } catch (e) {
        debugPrint('发送清除指令失败: $e');
      }
    }

    // 2. 清除本地绑定
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefBoundDevice);
    } catch (_) {}
    _boundDeviceId = null;

    // 3. 断开并重新扫描
    try {
      await _device?.disconnect();
    } catch (_) {}
    _device = null;
    _controlChar = null;
    _reconnectAttempts = 0;
    await _manualRescan();

    _toast('已清除配对记录，请重新配对（配对码 299450）');
  }

  Future<void> _manualRescan() async {
    _reconnectTimer?.cancel();
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    _controlChar = null;
    _device = null;
    if (mounted) setState(() => _state = ConnState.idle);
    await _ensureAdapterAndScan();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    final isConnected = _state == ConnState.connected;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isConnected
                ? [Colors.green.shade900, Colors.black]
                : [Colors.blueGrey.shade900, Colors.black],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isConnected ? Icons.lock_open : Icons.lock,
                    size: 90,
                    color: isConnected ? Colors.green : Colors.white70,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    _statusText,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  if (_rssi != null) ...[
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.signal_cellular_alt,
                            color: Colors.white70, size: 18),
                        const SizedBox(width: 8),
                        Text('信号: $_rssi dBm',
                            style: const TextStyle(color: Colors.white70)),
                      ],
                    ),
                  ],
                  if (_boundDeviceId != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      '已绑定：${_boundDeviceId!.length > 20 ? "${_boundDeviceId!.substring(0, 8)}…" : _boundDeviceId}',
                      style: const TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                  ],
                  if (_hint != null) ...[
                    const SizedBox(height: 16),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: Colors.orange.withValues(alpha: 0.4)),
                      ),
                      child: Text(
                        _hint!,
                        style: const TextStyle(
                            color: Colors.orangeAccent, fontSize: 13),
                      ),
                    ),
                  ],
                  const SizedBox(height: 28),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _buildControlButton(
                        icon: Icons.lock_open,
                        label: '解锁',
                        color: Colors.green,
                        onPressed:
                            _isBusy ? null : () => _sendCommand(_cmdUnlock),
                      ),
                      const SizedBox(width: 40),
                      _buildControlButton(
                        icon: Icons.lock,
                        label: '上锁',
                        color: Colors.red,
                        onPressed:
                            _isBusy ? null : () => _sendCommand(_cmdLock),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  _buildStatusIndicator(),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _manualRescan,
                      icon: const Icon(Icons.refresh),
                      label: const Text('重新搜索'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        foregroundColor: Colors.white70,
                        side: const BorderSide(color: Colors.white24),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: TextButton.icon(
                      onPressed: _clearBond,
                      icon: const Icon(Icons.link_off, size: 18),
                      label: const Text('清除配对记录'),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white38,
                      ),
                    ),
                  ),
                  if (_found.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '附近蓝牙设备 (${_found.length})',
                        style:
                            const TextStyle(color: Colors.white54, fontSize: 13),
                      ),
                    ),
                    const SizedBox(height: 8),
                    ..._buildDeviceList(),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildDeviceList() {
    final list = _found.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));

    return list.take(8).map((r) {
      final name = r.device.platformName.isNotEmpty
          ? r.device.platformName
          : (r.advertisementData.advName.isNotEmpty
              ? r.advertisementData.advName
              : '(无名称)');
      final isBound = _boundDeviceId != null &&
          r.device.remoteId.str == _boundDeviceId;
      final isTarget = _isTarget(r);

      return Card(
        color: (isBound || isTarget)
            ? Colors.green.withValues(alpha: 0.2)
            : Colors.white10,
        margin: const EdgeInsets.only(bottom: 6),
        child: ListTile(
          dense: true,
          title: Text(
            name,
            style: TextStyle(
              color: (isBound || isTarget)
                  ? Colors.greenAccent
                  : Colors.white,
              fontSize: 14,
            ),
          ),
          subtitle: Text(
            '${r.device.remoteId.str}   ${r.rssi} dBm',
            style: const TextStyle(color: Colors.white38, fontSize: 11),
          ),
          trailing: const Icon(Icons.chevron_right,
              color: Colors.white38, size: 18),
          onTap: () => _connectToDevice(r.device),
        ),
      );
    }).toList();
  }

  Widget _buildControlButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback? onPressed,
  }) {
    return Column(
      children: [
        SizedBox(
          width: 78,
          height: 78,
          child: ElevatedButton(
            onPressed: onPressed,
            style: ElevatedButton.styleFrom(
              backgroundColor: color,
              shape: const CircleBorder(),
              padding: EdgeInsets.zero,
            ),
            child: Icon(icon, size: 34, color: Colors.white),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(color: Colors.white)),
      ],
    );
  }

  Widget _buildStatusIndicator() {
    Color color;
    String text;
    switch (_state) {
      case ConnState.connected:
        color = Colors.green;
        text = '已连接';
        break;
      case ConnState.connecting:
        color = Colors.orange;
        text = '连接中';
        break;
      case ConnState.scanning:
        color = Colors.blue;
        text = '搜索中';
        break;
      case ConnState.disconnected:
        color = Colors.red;
        text = '已断开';
        break;
      default:
        color = Colors.grey;
        text = '待机';
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: color, blurRadius: 8)],
          ),
        ),
        const SizedBox(width: 8),
        Text(text, style: const TextStyle(color: Colors.white70)),
      ],
    );
  }
}
