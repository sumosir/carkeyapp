import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

/// 目标设备名称（必须与固件 BLE_DEVICE_NAME 一致）
const String _targetDeviceName = 'CarKey';

/// GATT 服务和特征 UUID（必须与固件一致）
final Guid _serviceUuid = Guid('0000fff0-0000-1000-8000-00805f9b34fb');
final Guid _controlCharUuid = Guid('0000fff2-0000-1000-8000-00805f9b34fb');

/// 自动重连间隔（毫秒）
const int _reconnectIntervalMs = 3000;

/// 扫描超时（毫秒）
const int _scanTimeoutMs = 10000;

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
enum ConnState {
  idle,
  scanning,
  connecting,
  connected,
  disconnected,
}

class CarKeyHomePage extends StatefulWidget {
  const CarKeyHomePage({super.key});

  @override
  State<CarKeyHomePage> createState() => _CarKeyHomePageState();
}

class _CarKeyHomePageState extends State<CarKeyHomePage> {
  // 当前连接状态
  ConnState _state = ConnState.idle;
  // 已连接设备
  BluetoothDevice? _device;
  // 控制特征（用于发送锁/解锁指令）
  BluetoothCharacteristic? _controlChar;
  // 信号强度
  int? _rssi;
  // 状态消息
  String _statusText = '等待启动...';
  // 是否已授权
  bool _permissionGranted = false;
  // 是否正在执行锁/解锁操作
  bool _isBusy = false;

  // 定时器和订阅
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

  /// 初始化：申请权限 → 开始扫描
  Future<void> _initApp() async {
    _permissionGranted = await _requestPermissions();
    if (!_permissionGranted) {
      setState(() => _statusText = '蓝牙权限被拒绝，请在设置中开启');
      return;
    }
    _startScan();
  }

  /// 申请蓝牙权限
  Future<bool> _requestPermissions() async {
    if (Theme.of(context).platform == TargetPlatform.iOS) {
      return true; // iOS 首次扫描时自动弹窗
    }
    final scan = await Permission.bluetoothScan.request();
    final connect = await Permission.bluetoothConnect.request();
    return scan.isGranted && connect.isGranted;
  }

  /// 开始扫描 CarKey
  void _startScan() {
    if (_state == ConnState.scanning || _state == ConnState.connected) return;

    setState(() {
      _state = ConnState.scanning;
      _statusText = '正在搜索 CarKey...';
    });

    FlutterBluePlus.stopScan();

    _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
      for (final result in results) {
        if (result.device.platformName == _targetDeviceName) {
          _scanSubscription?.cancel();
          FlutterBluePlus.stopScan();
          _connectToDevice(result.device);
          return;
        }
      }
    });

    FlutterBluePlus.startScan(
      timeout: const Duration(milliseconds: _scanTimeoutMs),
      androidUsesFineLocation: false,
    );

    // 扫描超时后重试
    Future.delayed(const Duration(milliseconds: _scanTimeoutMs), () {
      if (_state == ConnState.scanning) _startScan();
    });
  }

  /// 连接到设备
  Future<void> _connectToDevice(BluetoothDevice device) async {
    _device = device;
    setState(() {
      _state = ConnState.connecting;
      _statusText = '正在连接 CarKey...';
    });

    _connSubscription?.cancel();
    _connSubscription = device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.connected) {
        _onConnected();
      } else if (state == BluetoothConnectionState.disconnected) {
        _onDisconnected();
      }
    });

    try {
      await device.connect(
        autoConnect: true,
        timeout: const Duration(seconds: 10),
      );
    } catch (e) {
      setState(() => _statusText = '连接失败: $e');
      _scheduleReconnect();
    }
  }

  /// 连接成功：发现服务并获取控制特征
  Future<void> _onConnected() async {
    _reconnectTimer?.cancel();

    // 发现 GATT 服务
    try {
      final services = await _device!.discoverServices();
      for (final service in services) {
        if (service.uuid == _serviceUuid) {
          for (final char in service.characteristics) {
            if (char.uuid == _controlCharUuid) {
              _controlChar = char;
              debugPrint('Found control characteristic');
            }
          }
        }
      }
    } catch (e) {
      debugPrint('发现服务失败: $e');
    }

    setState(() {
      _state = ConnState.connected;
      _statusText = '已连接 — 靠近自动解锁 🔓';
    });

    _readRssi();
  }

  /// 断开连接
  void _onDisconnected() {
    _controlChar = null;
    setState(() {
      _state = ConnState.disconnected;
      _statusText = '已断开 — 远离自动上锁 🔒';
      _rssi = null;
    });
    _scheduleReconnect();
  }

  /// 定时重连
  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(milliseconds: _reconnectIntervalMs), () {
      if (_device != null && _state != ConnState.connected) {
        _connectToDevice(_device!);
      } else {
        _startScan();
      }
    });
  }

  /// 读取信号强度
  Future<void> _readRssi() async {
    while (_state == ConnState.connected && _device != null) {
      try {
        final rssi = await _device!.readRssi();
        if (mounted) setState(() => _rssi = rssi);
      } catch (_) {}
      await Future.delayed(const Duration(seconds: 2));
    }
  }

  /// 发送控制指令：0=上锁, 1=解锁
  Future<void> _sendCommand(int cmd) async {
    if (_controlChar == null || _state != ConnState.connected) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('设备未连接，无法控制')),
        );
      }
      return;
    }

    setState(() => _isBusy = true);
    try {
      await _controlChar!.write([cmd], withoutResponse: true);
      if (mounted) {
        setState(() => _statusText = cmd == 1 ? '手动解锁 🔓' : '手动上锁 🔒');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('操作失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  /// 手动重新扫描
  void _manualRescan() {
    _device?.disconnect();
    _device = null;
    _controlChar = null;
    _startScan();
  }

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
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // 车锁图标
                Icon(
                  isConnected ? Icons.lock_open : Icons.lock,
                  size: 100,
                  color: isConnected ? Colors.green : Colors.white70,
                ),
                const SizedBox(height: 24),
                // 状态文字
                Text(
                  _statusText,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                // RSSI 信号
                if (_rssi != null)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.signal_cellular_alt,
                          color: Colors.white70, size: 18),
                      const SizedBox(width: 8),
                      Text(
                        '信号: $_rssi dBm',
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ],
                  ),
                const SizedBox(height: 40),
                // ===== 手动控制按钮 =====
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // 解锁按钮
                    _buildControlButton(
                      icon: Icons.lock_open,
                      label: '解锁',
                      color: Colors.green,
                      onPressed: _isBusy ? null : () => _sendCommand(1),
                    ),
                    // 上锁按钮
                    _buildControlButton(
                      icon: Icons.lock,
                      label: '上锁',
                      color: Colors.red,
                      onPressed: _isBusy ? null : () => _sendCommand(0),
                    ),
                  ],
                ),
                const SizedBox(height: 32),
                // 状态指示器
                _buildStatusIndicator(),
                const SizedBox(height: 32),
                // 自动模式提示
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.white10,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.info_outline, color: Colors.white70, size: 18),
                      SizedBox(width: 8),
                      Text(
                        '靠近自动解锁 · 远离自动上锁',
                        style: TextStyle(color: Colors.white70, fontSize: 13),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 32),
                // 重新搜索按钮
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
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 控制按钮
  Widget _buildControlButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback? onPressed,
  }) {
    return Column(
      children: [
        SizedBox(
          width: 80,
          height: 80,
          child: ElevatedButton(
            onPressed: onPressed,
            style: ElevatedButton.styleFrom(
              backgroundColor: color,
              shape: const CircleBorder(),
              padding: EdgeInsets.zero,
            ),
            child: Icon(icon, size: 36, color: Colors.white),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(color: Colors.white)),
      ],
    );
  }

  /// 状态指示器
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
