import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart' as shelf_router;
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:share_handler/share_handler.dart';

//App version & GitHub config
const String _appVersion      = "1.0.0";
const String _githubUser      = "arkosarker07";
const String _githubRepo      = "FastSync";
const String _announcementUrl =
    "https://raw.githubusercontent.com/$_githubUser/$_githubRepo/main/announcement.json";
const String _releasesUrl     =
    "https://github.com/$_githubUser/$_githubRepo/releases/latest";

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  runApp(
    WithForegroundTask(
      child: const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: FastSyncPro(),
      ),
    ),
  );
}

class FastSyncPro extends StatefulWidget {
  const FastSyncPro({super.key});
  @override
  State<FastSyncPro> createState() => _FastSyncProState();
}

class _FastSyncProState extends State<FastSyncPro>
    with WidgetsBindingObserver {
  //State
  String myIp = "Detecting...";
  String pcIp = "";
  bool pcConnected = false;

  List<dynamic> pcItems = [];
  String currentPcPath = "DRIVES";
  List<String> pcPathStack = [];

  List<String> clipboardHistory = [];
  String _lastClipboard = "";

  Timer? _clipboardTimer;
  Timer? _broadcastTimer;
  Timer? _ipDebounce;
  StreamSubscription<SharedMedia>? _sharedMediaSubscription;

  final TextEditingController _pcIpController = TextEditingController();

  // Lifecycle
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initForegroundTask();
    _getIP().then((_) {
      _loadSavedIp();
      _requestStorageAndStart();
      _startUDPDiscovery();
      _startPhoneBroadcast();
      _startClipboardPolling();
      _initShareHandler();
    });
    // Check for updates & announcements after UI is ready
    Future.delayed(const Duration(seconds: 2), _checkForUpdatesAndAnnouncements);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clipboardTimer?.cancel();
    _broadcastTimer?.cancel();
    _ipDebounce?.cancel();
    _sharedMediaSubscription?.cancel();
    FlutterForegroundTask.stopService();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _pushClipboardNow();
      _startForegroundService(); // re-ensure alive after returning from background
    }
  }

  // Share Intent Handler
  Future<void> _initShareHandler() async {
    final handler = ShareHandlerPlatform.instance;
    final initialMedia = await handler.getInitialSharedMedia();
    if (initialMedia != null) {
      _handleSharedMedia(initialMedia);
    }
    _sharedMediaSubscription = handler.sharedMediaStream.listen((SharedMedia media) {
      if (!mounted) return;
      _handleSharedMedia(media);
    });
  }

  void _handleSharedMedia(SharedMedia media) {
    if (media.content != null && media.content!.isNotEmpty) {
      final text = media.content!;
      _lastClipboard = text; 
      Clipboard.setData(ClipboardData(text: text)); 
      setState(() {
        if (!clipboardHistory.contains(text)) {
          clipboardHistory.insert(0, text);
          if (clipboardHistory.length > 20) clipboardHistory.removeLast();
        }
      });
      // Send directly to PC
      if (pcIp.isNotEmpty) {
        http.post(Uri.parse("http://$pcIp:8000/from_phone"),
            body: jsonEncode({"text": text}),
            headers: {"Content-Type": "application/json"}).catchError((_) {});
        
        // Let user know it succeeded without opening the FastSync window
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("✅ Sent to PC clipboard"), duration: Duration(seconds: 2))
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("⚠️ Text copied locally. Connect to PC to sync."), duration: Duration(seconds: 3))
        );
      }
    }
  }

  // Update Checker & Announcements
  Future<void> _checkForUpdatesAndAnnouncements() async {
    try {
      final res = await http
          .get(Uri.parse(_announcementUrl))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return;
      final data = jsonDecode(res.body) as Map<String, dynamic>;

      final latestVersion  = (data['latest_version'] as String? ?? '').trim();
      final announcement   = (data['announcement']   as String? ?? '').trim();

      if (!mounted) return;

      // Show update dialog if newer version available 
      if (latestVersion.isNotEmpty && latestVersion != _appVersion) {
        await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => AlertDialog(
            backgroundColor: const Color(0xFF1E293B),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16)),
            title: const Row(children: [
              Icon(Icons.system_update, color: Colors.cyanAccent),
              SizedBox(width: 10),
              Text('Update Available',
                  style: TextStyle(color: Colors.white, fontSize: 17)),
            ]),
            content: Text(
              'A new version (v$latestVersion) is available.\nYou are on v$_appVersion.',
              style: const TextStyle(color: Colors.white70),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Later',
                    style: TextStyle(color: Colors.white38)),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.cyanAccent,
                    foregroundColor: const Color(0xFF0F172A)),
                icon: const Icon(Icons.download),
                label: const Text('Update',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                onPressed: () async {
                  Navigator.pop(context);
                  await launchUrl(Uri.parse(_releasesUrl),
                      mode: LaunchMode.externalApplication);
                },
              ),
            ],
          ),
        );
      }

      // Show announcement if present
      if (!mounted) return;
      if (announcement.isNotEmpty) {
        await showDialog(
          context: context,
          builder: (_) => AlertDialog(
            backgroundColor: const Color(0xFF1E293B),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16)),
            title: const Row(children: [
              Icon(Icons.campaign, color: Colors.amberAccent),
              SizedBox(width: 10),
              Text('Announcement',
                  style: TextStyle(color: Colors.white, fontSize: 17)),
            ]),
            content: Text(announcement,
                style: const TextStyle(color: Colors.white70)),
            actions: [
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.cyanAccent,
                    foregroundColor: const Color(0xFF0F172A)),
                onPressed: () => Navigator.pop(context),
                child: const Text('Got it!',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        );
      }
    } catch (_) {
      // Silently fail no internet or repo not set up yet
    }
  }

  //Foreground Service
  void _initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'fastsync_service',
        channelName: 'FastSync Running',
        channelDescription: 'Keeps FastSync active in the background',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(10000),
        autoRunOnBoot: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  Future<void> _startForegroundService() async {
    if (await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.startService(
      notificationTitle: 'FastSync is running',
      notificationText: 'Server active — tap to open',
      callback: _foregroundCallback,
    );
  }

  @pragma('vm:entry-point')
  static void _foregroundCallback() {
    FlutterForegroundTask.setTaskHandler(_FastSyncTaskHandler());
  }

  // Permission dialog then server
  Future<void> _requestStorageAndStart() async {
    // Already granted — skip dialog
    final status = await Permission.manageExternalStorage.status;
    if (status.isGranted) {
      _startPhoneServer();
      _startForegroundService();
      return;
    }

    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(children: [
          Icon(Icons.folder_open, color: Colors.cyanAccent, size: 26),
          SizedBox(width: 10),
          Text('Storage Access',
              style: TextStyle(color: Colors.white, fontSize: 18)),
        ]),
        content: const Text(
          'FastSync needs access to your storage so it can:\n\n'
          '• Browse and serve your files to PC\n'
          '• Save files received from PC to Downloads\n\n'
          'Tap Allow to grant access in settings.',
          style: TextStyle(color: Colors.white70, height: 1.5),
        ),
        actionsAlignment: MainAxisAlignment.spaceBetween,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Decline',
                style: TextStyle(color: Colors.redAccent)),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.cyanAccent,
              foregroundColor: const Color(0xFF0F172A),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            icon: const Icon(Icons.check, size: 16),
            label: const Text('Allow',
                style: TextStyle(fontWeight: FontWeight.bold)),
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('⚠️ Storage access denied — file browsing disabled'),
          duration: Duration(seconds: 4),
        ));
      }
      _startPhoneServer();
      return;
    }

    await Permission.manageExternalStorage.request();
    _startPhoneServer();
    _startForegroundService();
  }

  //IP helpers
  Future<void> _getIP() async {
    final interfaces = await NetworkInterface.list();
    for (var iface in interfaces) {
      for (var addr in iface.addresses) {
        if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
          setState(() => myIp = addr.address);
        }
      }
    }
  }

  Future<void> _loadSavedIp() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('pc_ip') ?? '';
    if (saved.isNotEmpty) {
      setState(() { pcIp = saved; _pcIpController.text = saved; });
      _syncFromPC();
    }
  }

  Future<void> _saveIp(String ip) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('pc_ip', ip);
  }

  // UDP Auto-discovery
  void _startUDPDiscovery() async {
    try {
      final socket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4, 9876, reuseAddress: true);
      socket.broadcastEnabled = true;
      socket.listen((event) {
        if (event == RawSocketEvent.read) {
          final dg = socket.receive();
          if (dg == null) return;
          final msg = utf8.decode(dg.data);
          if (msg.startsWith("FASTSYNC_PC:")) {
            final ip = msg.split(":").last; // Parse actual IP from message payload
            if (ip != pcIp && ip.isNotEmpty && ip != "255.255.255.255") {
              setState(() { pcIp = ip; _pcIpController.text = ip; });
              _saveIp(ip);
              _syncFromPC();
            }
          }
        }
      });
    } catch (e) { debugPrint("UDP: $e"); }
  }

  void _startPhoneBroadcast() {
    // 5s — battery-friendly, still fast enough to be discovered
    _broadcastTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (myIp == "Detecting...") return;
      try {
        final socket = await RawDatagramSocket.bind(
            InternetAddress.anyIPv4, 0, reuseAddress: true);
        socket.broadcastEnabled = true;
        socket.send(utf8.encode("FASTSYNC_PHONE:$myIp"),
            InternetAddress('255.255.255.255'), 9877);
        socket.close();
      } catch (_) {}
    });
  }

  // Clipboard polling 
  void _startClipboardPolling() {
    // 1000ms — battery-friendly 
    _clipboardTimer =
        Timer.periodic(const Duration(milliseconds: 1000), (_) async {
      if (pcIp.isEmpty) return;
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (data?.text != null &&
          data!.text!.isNotEmpty &&
          data.text! != _lastClipboard) {
        _lastClipboard = data.text!;
        http
            .post(Uri.parse("http://$pcIp:8000/from_phone"),
                body: jsonEncode({"text": data.text!}),
                headers: {"Content-Type": "application/json"})
            .catchError((_) {});
      }
    });
  }

  Future<void> _pushClipboardNow() async {
    if (pcIp.isEmpty) return;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null &&
        data!.text!.isNotEmpty &&
        data.text! != _lastClipboard) {
      _lastClipboard = data.text!;
      http
          .post(Uri.parse("http://$pcIp:8000/from_phone"),
              body: jsonEncode({"text": data.text!}),
              headers: {"Content-Type": "application/json"})
          .catchError((_) {});
    }
  }

  // Sync PC data 
  Future<void> _syncFromPC() async {
    if (pcIp.isEmpty) return;
    try {
      final fileRes = await http
          .get(Uri.parse("http://$pcIp:8000/pc_list?path=$currentPcPath"))
          .timeout(const Duration(seconds: 5));
      final clipRes = await http
          .get(Uri.parse("http://$pcIp:8000/get_history"))
          .timeout(const Duration(seconds: 5));
      setState(() {
        pcItems = jsonDecode(fileRes.body);
        clipboardHistory = List<String>.from(jsonDecode(clipRes.body));
        pcConnected = true;
      });
    } catch (_) {
      setState(() => pcConnected = false);
    }
  }

  //  Phone shelf server (port 9000)
  void _startPhoneServer() async {
    final router = shelf_router.Router();

    router.get('/list', (Request req) {
      final path = req.url.queryParameters['path'] ?? "";
      final dir = Directory('/storage/emulated/0/$path');
      try {
        final items = dir.listSync().map((e) => {
              "name": e.path.split('/').last,
              "isDir": e is Directory,
              "fullPath": e.path,
            }).toList();
        return Response.ok(jsonEncode(items),
            headers: {'content-type': 'application/json'});
      } catch (_) {
        return Response.ok(jsonEncode([]),
            headers: {'content-type': 'application/json'});
      }
    });

    router.post('/upload', (Request req) async {
      try {
        final name = req.url.queryParameters['name'] ?? "file";
        final dir = Directory('/storage/emulated/0/Download');
        if (!await dir.exists()) await dir.create(recursive: true);
        final file = File('${dir.path}/$name');
        final sink = file.openWrite();
        try {
          await for (final chunk in req.read()) {
            sink.add(chunk);
          }
        } finally {
          await sink.close();
        }
        return Response.ok("Saved");
      } catch (e) {
        return Response.internalServerError(body: "Upload error: $e");
      }
    });

    router.post('/clipboard', (Request req) async {
      final body = jsonDecode(await req.readAsString());
      final text = body['text'] as String?;
      if (text != null && text.isNotEmpty && text != _lastClipboard) {
        _lastClipboard = text;
        await Clipboard.setData(ClipboardData(text: text));
        if (mounted) {
          setState(() {
            if (!clipboardHistory.contains(text)) {
              clipboardHistory.insert(0, text);
              if (clipboardHistory.length > 20) clipboardHistory.removeLast();
            }
          });
        }
      }
      return Response.ok("ok");
    });

router.get('/download', (Request req) async {
  final filePath = req.url.queryParameters['path'] ?? "";
  final file = File(filePath);
  if (await file.exists()) {
    final name = file.path.split('/').last;
    final ext = name.split('.').last.toLowerCase();
    const mimeMap = {
      'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png',
      'gif': 'image/gif',  'webp': 'image/webp', 'bmp': 'image/bmp',
      'pdf': 'application/pdf',
      'mp4': 'video/mp4',  'mkv': 'video/x-matroska',
      'mov': 'video/quicktime', 'avi': 'video/x-msvideo',
      'mp3': 'audio/mpeg', 'wav': 'audio/wav', 'm4a': 'audio/mp4',
      'txt': 'text/plain',
    };
    final mime = mimeMap[ext] ?? 'application/octet-stream';

    if (['mp4','mkv','mov','avi','mp3','wav','m4a','flac'].contains(ext)) {
      final fileStream = file.openRead();
      final fileSize = await file.length();
      return Response.ok(
        fileStream,
        headers: {
          'content-type': mime,
          'content-length': fileSize.toString(),
          'accept-ranges': 'bytes',
          'content-disposition': 'inline; filename="$name"',
        },
      );
    }

    final bytes = await file.readAsBytes();
    return Response.ok(bytes, headers: {
      'content-type': mime,
      'content-disposition': 'inline; filename="$name"',
    });
  }
  return Response.notFound("Not found");
});
    final handler = const Pipeline().addHandler(router.call);
    await shelf_io.serve(handler, InternetAddress.anyIPv4, 9000);
   }


  // Helpers 
  String _pcFileUrl(String p) =>
      "http://$pcIp:8000/download_file?path=${Uri.encodeComponent(p)}";

  String _fileIcon(String name) {
    final ext = name.split('.').last.toLowerCase();
    if (['jpg','jpeg','png','gif','webp','bmp'].contains(ext)) return '🖼️';
    if (['mp4','mkv','mov','avi'].contains(ext)) return '🎬';
    if (['mp3','wav','m4a','flac'].contains(ext)) return '🎵';
    if (ext == 'pdf') return '📕';
    if (['zip','rar','7z'].contains(ext)) return '🗜️';
    if (['doc','docx'].contains(ext)) return '📝';
    return '📄';
  }

  // Open in browser
  Future<void> _openInBrowser(String filePath) async {
    final url = Uri.parse(_pcFileUrl(filePath));
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("❌ Could not open: $e")));
      }
    }
  }

  // BUILD
  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: const Color(0xFF0F172A),
        appBar: AppBar(
          backgroundColor: const Color(0xFF1E293B),
          title: Row(children: [
            const Text("FastSync",
                style: TextStyle(
                    color: Colors.cyanAccent, fontWeight: FontWeight.bold)),
            const SizedBox(width: 10),
            _connectionBadge(),
          ]),
          bottom: const TabBar(
            indicatorColor: Colors.cyanAccent,
            labelColor: Colors.cyanAccent,
            unselectedLabelColor: Colors.white54,
            tabs: [
              Tab(icon: Icon(Icons.settings),      text: "SETUP"),
              Tab(icon: Icon(Icons.folder_open),   text: "PC FILES"),
              Tab(icon: Icon(Icons.content_paste), text: "CLIPBOARD"),
            ],
          ),
        ),
        body: TabBarView(
          children: [_setupTab(), _pcBrowserTab(), _clipboardTab()],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _syncFromPC,
          backgroundColor: Colors.cyanAccent,
          foregroundColor: const Color(0xFF0F172A),
          icon: const Icon(Icons.sync),
          label: const Text("Sync",
              style: TextStyle(fontWeight: FontWeight.bold)),
        ),
      ),
    );
  }

  Widget _connectionBadge() => AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: pcConnected
              ? Colors.green.withOpacity(0.15)
              : Colors.orange.withOpacity(0.15),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: pcConnected ? Colors.greenAccent : Colors.orange,
              width: 0.8),
        ),
        child: Text(
          pcConnected ? "● PC Connected" : "● Searching...",
          style: TextStyle(
              color: pcConnected ? Colors.greenAccent : Colors.orange,
              fontSize: 11,
              fontWeight: FontWeight.w500),
        ),
      );

  // Tab 1: SETUP
  Widget _setupTab() => SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(children: [
          const SizedBox(height: 20),
          const Icon(Icons.phonelink_setup,
              color: Colors.cyanAccent, size: 64),
          const SizedBox(height: 24),
          _infoCard(children: [
            _infoRow("📱 Phone IP", myIp, Colors.cyanAccent),
            const Divider(color: Colors.white10, height: 20),
            _infoRow(
              "💻 PC IP",
              pcIp.isEmpty ? "Auto-detecting..." : pcIp,
              pcIp.isEmpty ? Colors.orange : Colors.greenAccent,
            ),
          ]),
          const SizedBox(height: 20),
          TextField(
            controller: _pcIpController,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              labelText: "PC IP  (auto-filled or enter manually)",
              labelStyle: const TextStyle(color: Colors.white54),
          
              hintText: "Enter ip manually for first time", 
              hintStyle: const TextStyle(color: Colors.white24), 
              prefixIcon:
                  const Icon(Icons.computer, color: Colors.cyanAccent),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10)),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Colors.white24)),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Colors.cyanAccent)),
            ),
            onChanged: (val) {
              _ipDebounce?.cancel();
              _ipDebounce = Timer(const Duration(milliseconds: 1500), () {
                final ip = val.trim();
                if (ip.isNotEmpty && ip != pcIp) {
                  setState(() { pcIp = ip; pcConnected = false; });
                  _saveIp(ip);
                  _syncFromPC();
                }
              });
            },
            onSubmitted: (val) {
              final ip = val.trim();
              setState(() { pcIp = ip; pcConnected = false; });
              _saveIp(ip);
              _syncFromPC();
            },
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.cyanAccent,
                foregroundColor: const Color(0xFF0F172A),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              icon: const Icon(Icons.upload_file),
              label: const Text("SEND FILE TO PC",
                  style: TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 16)),
              onPressed: _sendFileToPc,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            "💡 Both devices must be on the same WiFi.",
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ]),
      );

  Widget _infoCard({required List<Widget> children}) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white10),
        ),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children),
      );

  Widget _infoRow(String label, String value, Color valueColor) =>
      Row(children: [
        Text(label, style: const TextStyle(color: Colors.white54)),
        const Spacer(),
        Text(value,
            style: TextStyle(
                color: valueColor, fontWeight: FontWeight.w600)),
      ]);

  Future<void> _sendFileToPc() async {
    if (pcIp.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("PC not connected yet!")));
      return;
    }
    final result = await FilePicker.platform.pickFiles();
    if (result == null || result.files.single.path == null) return;

    final file     = File(result.files.single.path!);
    final fileName = file.path.split('/').last;
    final fileSize = await file.length();
    final totalMB  = fileSize / 1048576;

    double sent = 0;
    if (!mounted) return;
StateSetter? progressSetter;

showDialog(
  context: context,
  barrierDismissible: false,
  builder: (ctx) => StatefulBuilder(
    builder: (ctx, setDialogState) {
      return AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16)),
        title: Row(children: [
          const Icon(Icons.upload_file, color: Colors.cyanAccent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(fileName,
                style: const TextStyle(
                    color: Colors.white, fontSize: 14),
                overflow: TextOverflow.ellipsis),
          ),
        ]),
        content: StatefulBuilder(
          builder: (ctx2, setSt) {
            progressSetter = setSt; // ← capture it
            final sentMB = sent / 1048576;
            final pct =
                fileSize > 0 ? (sent / fileSize).clamp(0.0, 1.0) : 0.0;
            return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: pct,
                backgroundColor: Colors.white12,
                color: Colors.cyanAccent,
                minHeight: 8,
                borderRadius: BorderRadius.circular(4),
              ),
              const SizedBox(height: 10),
              Text(
                "${sentMB.toStringAsFixed(1)} MB"
                " / ${totalMB.toStringAsFixed(1)} MB"
                "  (${(pct * 100).toStringAsFixed(0)}%)",
                style: const TextStyle(
                    color: Colors.white54, fontSize: 13),
              ),
            ]);
          },
        ),
      );
    },
  ),
);
    try {
      final uri = Uri.parse(
          'http://$pcIp:8000/upload_to_pc?filename=${Uri.encodeComponent(fileName)}');
      final request = http.StreamedRequest('POST', uri)
        ..headers['Content-Length'] = fileSize.toString()
        ..headers['Content-Type'] = 'application/octet-stream';

      file.openRead().listen(
  (chunk) {
    request.sink.add(chunk);
    sent += chunk.length;
    progressSetter?.call(() {}); 
  },
  onDone: () => request.sink.close(),
  onError: (_) => request.sink.close(),
);
      await request.send();

      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("✅ File sent to PC!")));
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text("❌ Send failed: $e")));
      }
    }
  }

  //Tab 2: PC FILE BROWSER
  Widget _pcBrowserTab() => Column(children: [
        Container(
          color: const Color(0xFF1E293B),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(children: [
            _navBtn(Icons.home, "Home", () {
              setState(() {
                currentPcPath = "DRIVES";
                pcPathStack.clear();
              });
              _syncFromPC();
            }),
            _navBtn(
              Icons.arrow_back,
              "Back",
              pcPathStack.isEmpty
                  ? null
                  : () {
                      setState(
                          () => currentPcPath = pcPathStack.removeLast());
                      _syncFromPC();
                    },
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                currentPcPath == "DRIVES" ? "💻 Drives" : currentPcPath,
                style: const TextStyle(color: Colors.white54, fontSize: 11),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ]),
        ),
        Expanded(
          child: pcItems.isEmpty
              ? Center(
                  child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.folder_off,
                            color: Colors.white24, size: 48),
                        const SizedBox(height: 12),
                        Text(
                          pcConnected ? "Empty folder" : "Waiting for PC...",
                          style:
                              const TextStyle(color: Colors.white38),
                        ),
                      ]))
              : ListView.builder(
                  itemCount: pcItems.length,
                  itemBuilder: (context, i) {
                    final item     = pcItems[i];
                    final fullPath = item['name'] as String;
                    final name     = fullPath
                        .split(Platform.pathSeparator)
                        .last;
                    final isDir    = item['isDir'] as bool;

                    return ListTile(
                      dense: true,
                      leading: Text(isDir ? '📁' : _fileIcon(name),
                          style: const TextStyle(fontSize: 20)),
                      title: Text(name,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 14)),
                      trailing: const Icon(Icons.chevron_right,
                          color: Colors.white24),
                      onTap: () {
                        if (isDir) {
                          setState(() {
                            pcPathStack.add(currentPcPath);
                            currentPcPath = fullPath;
                          });
                          _syncFromPC();
                        } else {
                          _openInBrowser(fullPath);
                        }
                      },
                    );
                  },
                ),
        ),
      ]);

  Widget _navBtn(IconData icon, String tip, VoidCallback? fn) => Tooltip(
        message: tip,
        child: IconButton(
          icon: Icon(icon,
              color: fn == null ? Colors.white24 : Colors.cyanAccent),
          onPressed: fn,
          splashRadius: 20,
        ),
      );

  // Tab 3: CLIPBOARD
  Widget _clipboardTab() => Column(children: [
        const Padding(
          padding: EdgeInsets.only(top: 16),
          child: Text("To send clipboard to pc, Tap & Hold text ->Click on share -> Tap on \"FastSync\" app", style: TextStyle(color: Colors.white54, fontSize: 13)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
          child: Row(children: [
            const Icon(Icons.content_paste,
                color: Colors.cyanAccent, size: 18),
            const SizedBox(width: 8),
            const Text("Tap to copy",
                style: TextStyle(color: Colors.white54, fontSize: 13)),
            const Spacer(),
            TextButton(
              onPressed: () => setState(() => clipboardHistory.clear()),
              child: const Text("Clear all",
                  style: TextStyle(color: Colors.redAccent, fontSize: 12)),
            ),
          ]),
        ),
        Expanded(
          child: clipboardHistory.isEmpty
              ? const Center(
                  child: Text("No clipboard history yet",
                      style: TextStyle(color: Colors.white24)))
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: clipboardHistory.length,
                  itemBuilder: (context, i) {
                    final text = clipboardHistory[i];
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      color: const Color(0xFF1E293B),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                      child: ListTile(
                        leading: const Icon(Icons.content_copy,
                            color: Colors.cyanAccent, size: 18),
                        title: Text(text,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 13),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis),
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: text));
                          ScaffoldMessenger.of(context)
                              .showSnackBar(const SnackBar(
                            content: Text("✅ Copied to clipboard!"),
                            duration: Duration(seconds: 1),
                          ));
                        },
                      ),
                    );
                  },
                ),
        ),
      ]);
}

// Foreground Task Handler
class _FastSyncTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter taskStarter) async {}

  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {
    // Heartbeat every 10s — keeps process alive, does nothing else
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}