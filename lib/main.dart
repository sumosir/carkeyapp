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
          seedColor: const Color(0xFF3DDC97),
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

class _CarKeyHomePageState extends State<CarKeyHomePage>
    with SingleTickerProviderStateMixin {
  ConnState _state = ConnState.idle;
  BluetoothDevice? _device;
  BluetoothCharacteristic? _controlChar;
  int? _rssi;
  String _statusText = '等待启动...';
  String? _hint;
  bool _isBusy = false;
  String? _boundDeviceId;
  final Map<String, ScanResult> _found = {};
  bool _connecting = false;
  int _reconnectAttempts = 0;
  bool _sawTarget = false;

  Timer? _reconnectTimer;
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<BluetoothConnectionState>? _connSubscription;

  /// 扫描/连接时的呼吸动画
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
    _initApp();
  }

  @override
  void dispose() {
    _pulse.dispose();
    _reconnectTimer?.cancel();
    _scanSubscription?.cancel();
    _connSubscription?.cancel();
    super.dispose();
  }

  // ==================== 初始化 ====================

  Future<void> _initApp() async {
    await _loadBoundDevice();

    final granted = await _requestPermissions();
    if (!granted) {
      if (mounted) {
        setState(() => _hint = '蓝牙权限被拒绝\n请到 设置 → 车钥匙 → 打开蓝牙权限');
      }
      return;
    }
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
        _hint = '手机蓝牙未开启，请打开蓝牙';
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

  bool _isTarget(ScanResult r) {
    final target = _normalize(_targetDeviceName);
    return <String>[
      r.device.platformName,
      r.advertisementData.advName,
    ].any((raw) {
      final n = _normalize(raw);
      if (n.isEmpty) return false;
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
              '2. 若换过固件，请到设置里「清除配对记录」后重试';
        } else if (_found.isEmpty) {
          _hint = '没有扫描到任何蓝牙设备\n'
              '1. 确认手机蓝牙已开启\n'
              '2. 确认开发板已通电';
        } else {
          _hint = '已发现 ${_found.length} 个其他蓝牙设备，但没有 CarKey\n'
              '开发板可能已被其他手机占用连接（此时会停止广播）';
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

  Future<void> _showConnectFailedDialog() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('连接失败'),
        content: const Text(
          '1. 确认没有其他手机连着 CarKey（开发板只支持 1 个连接）\n\n'
          '2. 若换过固件，到设置里点「清除配对记录」，然后重新搜索\n\n'
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

    if (_device != null) {
      await _saveBoundDevice(_device!.remoteId.str);
    }

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
      _statusText = '车辆已解锁';
      _hint = _controlChar == null ? '未找到控制特征，手动按钮可能不可用' : null;
    });

    _readRssi();
  }

  void _onDisconnected() {
    _controlChar = null;
    if (!mounted) return;
    setState(() {
      _state = ConnState.disconnected;
      _statusText = '已断开，车辆上锁';
      _rssi = null;
    });
    _scheduleReconnect();
  }

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
        setState(() {
          _statusText = cmd == _cmdUnlock ? '已手动解锁' : '已手动上锁';
        });
      }
    } catch (e) {
      _toast('操作失败: $e');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

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
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('确认清除'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    if (_state == ConnState.connected && _controlChar != null) {
      try {
        await _controlChar!.write([_cmdClearBond], withoutResponse: true);
        await Future.delayed(const Duration(milliseconds: 300));
      } catch (e) {
        debugPrint('发送清除指令失败: $e');
      }
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefBoundDevice);
    } catch (_) {}
    _boundDeviceId = null;

    try {
      await _device?.disconnect();
    } catch (_) {}
    _device = null;
    _controlChar = null;
    _reconnectAttempts = 0;

    await _restartScan();
    _toast('已清除配对记录，请重新配对（配对码 299450）');
  }

  /// 重新搜索（已连接时会二次确认，避免误触断开）
  Future<void> _manualRescan() async {
    if (_state == ConnState.connected) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('重新搜索'),
          content: const Text('当前已连接，重新搜索会先断开连接（车辆会上锁）。确定继续？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('继续'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    await _restartScan();
  }

  Future<void> _restartScan() async {
    _reconnectTimer?.cancel();
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    try {
      await _device?.disconnect();
    } catch (_) {}
    _controlChar = null;
    _device = null;
    _reconnectAttempts = 0;
    if (mounted) setState(() => _state = ConnState.idle);
    await _ensureAdapterAndScan();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ==================== 设置页 ====================

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 260),
        pageBuilder: (_, animation, _) => FadeTransition(
          opacity: animation,
          child: SettingsPage(
            devices: _found.values.toList()
              ..sort((a, b) => b.rssi.compareTo(a.rssi)),
            boundDeviceId: _boundDeviceId,
            isConnected: _state == ConnState.connected,
            isTarget: _isTarget,
            onRescan: _manualRescan,
            onClearBond: _clearBond,
            onConnect: (device) => _connectToDevice(device),
          ),
        ),
      ),
    );
  }

  // ==================== UI ====================

  /// 根据状态返回背景渐变色
  List<Color> get _bgColors {
    switch (_state) {
      case ConnState.connected:
        return const [Color(0xFF0E7C5A), Color(0xFF052B22), Color(0xFF000000)];
      case ConnState.connecting:
      case ConnState.scanning:
        return const [Color(0xFF14406E), Color(0xFF071B2E), Color(0xFF000000)];
      case ConnState.disconnected:
        return const [Color(0xFF7A1F1F), Color(0xFF2A0A0A), Color(0xFF000000)];
      default:
        return const [Color(0xFF2A2F36), Color(0xFF101316), Color(0xFF000000)];
    }
  }

  /// 主色：解锁绿 / 上锁红 / 过程蓝
  Color get _accent {
    switch (_state) {
      case ConnState.connected:
        return const Color(0xFF3DDC97);
      case ConnState.scanning:
      case ConnState.connecting:
        return const Color(0xFF4EA8FF);
      case ConnState.disconnected:
        return const Color(0xFFFF6B6B);
      default:
        return Colors.white70;
    }
  }

  bool get _isConnected => _state == ConnState.connected;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AnimatedContainer(
        duration: const Duration(milliseconds: 700),
        curve: Curves.easeInOut,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: _bgColors,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // 顶部栏
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 12, 0),
                child: Row(
                  children: [
                    const Text(
                      '车钥匙',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                        letterSpacing: 1,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: '设置',
                      onPressed: _openSettings,
                      icon: const Icon(Icons.settings_outlined,
                          color: Colors.white70, size: 24),
                    ),
                  ],
                ),
              ),

              // 中间状态区
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildLockVisual(),
                        const SizedBox(height: 24),
                        AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 400),
                          style: TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                            letterSpacing: 1,
                            shadows: [
                              Shadow(color: _accent.withValues(alpha: 0.6),
                                  blurRadius: 18),
                            ],
                          ),
                          child: Text(_statusText, textAlign: TextAlign.center),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          _subText,
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.white.withValues(alpha: 0.55),
                          ),
                        ),
                        if (_rssi != null) ...[
                          const SizedBox(height: 14),
                          _buildRssiBadge(),
                        ],
                        if (_hint != null) ...[
                          const SizedBox(height: 18),
                          _buildHintBox(),
                        ],
                      ],
                    ),
                  ),
                ),
              ),

              // 底部大按钮
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 0, 28, 32),
                child: Row(
                  children: [
                    Expanded(
                      child: _BigActionButton(
                        label: '解锁',
                        icon: Icons.lock_open_rounded,
                        color: const Color(0xFF2FBF71),
                        enabled: _isConnected && !_isBusy,
                        onTap: () => _sendCommand(_cmdUnlock),
                      ),
                    ),
                    const SizedBox(width: 18),
                    Expanded(
                      child: _BigActionButton(
                        label: '上锁',
                        icon: Icons.lock_rounded,
                        color: const Color(0xFFE04A4A),
                        enabled: _isConnected && !_isBusy,
                        onTap: () => _sendCommand(_cmdLock),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String get _subText {
    switch (_state) {
      case ConnState.connected:
        return '靠近自动解锁 · 离开自动上锁';
      case ConnState.connecting:
        return '正在建立连接...';
      case ConnState.scanning:
        return '保持手机蓝牙开启，靠近开发板';
      case ConnState.disconnected:
        return '等待自动重连...';
      default:
        return '下拉刷新或到设置里重新搜索';
    }
  }

  /// 车锁图标 + 呼吸光晕
  Widget _buildLockVisual() {
    final busy = _state == ConnState.scanning || _state == ConnState.connecting;

    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) {
        final t = busy ? _pulse.value : 0.0;
        final scale = 1.0 + t * 0.06;
        final glow = busy ? 0.25 + t * 0.35 : 0.35;

        return Container(
          width: 170,
          height: 170,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: _accent.withValues(alpha: glow * 0.45),
                blurRadius: 60 + t * 40,
                spreadRadius: 6,
              ),
            ],
          ),
          child: Center(
            child: Transform.scale(
              scale: scale,
              child: child,
            ),
          ),
        );
      },
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 450),
        transitionBuilder: (child, animation) => ScaleTransition(
          scale: CurvedAnimation(parent: animation, curve: Curves.easeOutBack),
          child: FadeTransition(opacity: animation, child: child),
        ),
        child: Icon(
          _isConnected ? Icons.lock_open_rounded : Icons.lock_rounded,
          key: ValueKey(_isConnected),
          size: 110,
          color: _accent,
        ),
      ),
    );
  }

  Widget _buildRssiBadge() {
    final strong = (_rssi ?? -100) > -70;
    final color = strong ? const Color(0xFF3DDC97) : Colors.orangeAccent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.signal_cellular_alt_rounded, color: color, size: 16),
          const SizedBox(width: 6),
          Text(
            '$_rssi dBm',
            style: TextStyle(color: color, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildHintBox() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.35)),
      ),
      child: Text(
        _hint!,
        style: const TextStyle(color: Colors.orangeAccent, fontSize: 12.5, height: 1.5),
      ),
    );
  }
}

// ============================================================================
//                            底部大按钮（带按压缩放）
// ============================================================================

class _BigActionButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final Color color;
  final bool enabled;
  final VoidCallback onTap;

  const _BigActionButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.enabled,
    required this.onTap,
  });

  @override
  State<_BigActionButton> createState() => _BigActionButtonState();
}

class _BigActionButtonState extends State<_BigActionButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.enabled
        ? widget.color
        : widget.color.withValues(alpha: 0.28);

    return AnimatedScale(
      scale: _pressed ? 0.94 : 1.0,
      duration: const Duration(milliseconds: 110),
      child: GestureDetector(
        onTapDown: widget.enabled ? (_) => setState(() => _pressed = true) : null,
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: widget.enabled
            ? (_) {
                setState(() => _pressed = false);
                widget.onTap();
              }
            : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 350),
          height: 96,
          decoration: BoxDecoration(
            color: c.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: c.withValues(alpha: 0.55), width: 1.6),
            boxShadow: widget.enabled
                ? [
                    BoxShadow(
                      color: c.withValues(alpha: 0.35),
                      blurRadius: 26,
                      spreadRadius: 1,
                    ),
                  ]
                : [],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(widget.icon, color: c, size: 34),
              const SizedBox(height: 8),
              Text(
                widget.label,
                style: TextStyle(
                  color: c,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
//                              设置页
// ============================================================================

class SettingsPage extends StatelessWidget {
  final List<ScanResult> devices;
  final String? boundDeviceId;
  final bool isConnected;
  final bool Function(ScanResult) isTarget;
  final Future<void> Function() onRescan;
  final Future<void> Function() onClearBond;
  final void Function(BluetoothDevice) onConnect;

  const SettingsPage({
    super.key,
    required this.devices,
    required this.boundDeviceId,
    required this.isConnected,
    required this.isTarget,
    required this.onRescan,
    required this.onClearBond,
    required this.onConnect,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0E11),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('设置'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          _sectionLabel('设备'),
          _card([
            _tile(
              icon: Icons.refresh_rounded,
              title: '重新搜索设备',
              subtitle: isConnected ? '当前已连接，重新搜索会先断开' : '扫描附近的 CarKey',
              onTap: () async {
                Navigator.pop(context);
                await onRescan();
              },
            ),
            _divider(),
            _tile(
              icon: Icons.link_off_rounded,
              title: '清除配对记录',
              subtitle: '删除开发板绑定，需重新输入配对码',
              color: Colors.redAccent,
              onTap: () async {
                Navigator.pop(context);
                await onClearBond();
              },
            ),
          ]),

          const SizedBox(height: 20),
          _sectionLabel('连接信息'),
          _card([
            _tile(
              icon: Icons.tag_rounded,
              title: '设备名称',
              subtitle: _targetDeviceName,
              dense: true,
            ),
            _divider(),
            _tile(
              icon: Icons.password_rounded,
              title: '配对码',
              subtitle: '299450',
              dense: true,
            ),
            _divider(),
            _tile(
              icon: Icons.bluetooth_connected_rounded,
              title: '已绑定设备',
              subtitle: boundDeviceId ??
                  '未绑定（连接成功后自动绑定这台手机）',
              dense: true,
            ),
          ]),

          const SizedBox(height: 20),
          _sectionLabel('附近的蓝牙设备 (${devices.length})'),
          if (devices.isEmpty)
            _card([
              const Padding(
                padding: EdgeInsets.all(18),
                child: Text(
                  '暂无扫描结果\n回到主页等待自动搜索',
                  style: TextStyle(color: Colors.white38, fontSize: 13),
                ),
              ),
            ])
          else
            _card(
              devices.take(12).map((r) {
                final name = r.device.platformName.isNotEmpty
                    ? r.device.platformName
                    : (r.advertisementData.advName.isNotEmpty
                        ? r.advertisementData.advName
                        : '(无名称)');
                final target = isTarget(r);
                final bound = boundDeviceId != null &&
                    r.device.remoteId.str == boundDeviceId;

                return Column(
                  children: [
                    ListTile(
                      title: Text(
                        name,
                        style: TextStyle(
                          color: (target || bound)
                              ? const Color(0xFF3DDC97)
                              : Colors.white,
                          fontSize: 14.5,
                        ),
                      ),
                      subtitle: Text(
                        '${r.device.remoteId.str}   ${r.rssi} dBm',
                        style: const TextStyle(
                            color: Colors.white30, fontSize: 11),
                      ),
                      trailing: (target || bound)
                          ? const Icon(Icons.bluetooth_searching_rounded,
                              size: 18, color: Color(0xFF3DDC97))
                          : null,
                      onTap: () {
                        Navigator.pop(context);
                        onConnect(r.device);
                      },
                    ),
                  ],
                );
              }).toList(),
            ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.white38,
            fontSize: 12,
            letterSpacing: 1,
          ),
        ),
      );

  Widget _card(List<Widget> children) => Container(
        decoration: BoxDecoration(
          color: const Color(0xFF15191D),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(children: children),
      );

  Widget _divider() => Divider(
        height: 1,
        thickness: 1,
        color: Colors.white.withValues(alpha: 0.05),
      );

  Widget _tile({
    required IconData icon,
    required String title,
    required String subtitle,
    Color? color,
    VoidCallback? onTap,
    bool dense = false,
  }) {
    return ListTile(
      dense: dense,
      onTap: onTap,
      leading: Icon(icon, color: color ?? Colors.white60, size: 20),
      title: Text(
        title,
        style: TextStyle(color: color ?? Colors.white, fontSize: 14.5),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.35),
          fontSize: 11.5,
        ),
      ),
      trailing: onTap == null
          ? null
          : const Icon(Icons.chevron_right_rounded,
              color: Colors.white24, size: 20),
    );
  }
}
