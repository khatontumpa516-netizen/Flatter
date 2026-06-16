import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

// ============================================================================
// CUSTOM HIVE TYPE ADAPTER - Handwritten Implementation
// ============================================================================

class AIModelStateAdapter extends TypeAdapter<AIModelState> {
  @override
  final typeId = 0;

  @override
  AIModelState read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{};
    for (var i = 0; i < numOfFields; i++) {
      final fieldId = reader.readByte();
      fields[fieldId] = reader.read();
    }

    return AIModelState(
      modelName: fields[0] as String? ?? 'Claude',
      apiEndpoint: fields[1] as String? ?? '',
      apiKey: fields[2] as String? ?? '',
      isActive: fields[3] as bool? ?? false,
      lastUpdated: fields[4] as DateTime? ?? DateTime.now(),
      responseTimeout: fields[5] as int? ?? 30,
      customHeaders: Map<String, String>.from(fields[6] as Map? ?? {}),
    );
  }

  @override
  void write(BinaryWriter writer, AIModelState obj) {
    writer.writeByte(7);
    writer.writeByte(0);
    writer.write(obj.modelName);
    writer.writeByte(1);
    writer.write(obj.apiEndpoint);
    writer.writeByte(2);
    writer.write(obj.apiKey);
    writer.writeByte(3);
    writer.write(obj.isActive);
    writer.writeByte(4);
    writer.write(obj.lastUpdated);
    writer.writeByte(5);
    writer.write(obj.responseTimeout);
    writer.writeByte(6);
    writer.write(obj.customHeaders);
  }
}

// ============================================================================
// MODEL CLASSES
// ============================================================================

class AIModelState extends HiveObject {
  late String modelName;
  late String apiEndpoint;
  late String apiKey;
  late bool isActive;
  late DateTime lastUpdated;
  late int responseTimeout;
  late Map<String, String> customHeaders;

  AIModelState({
    required this.modelName,
    required this.apiEndpoint,
    required this.apiKey,
    required this.isActive,
    required this.lastUpdated,
    required this.responseTimeout,
    required this.customHeaders,
  });
}

class DeveloperPreset {
  final String name;
  final String endpoint;
  final String? apiKeyEnvVar;
  final Map<String, String> defaultHeaders;
  final bool requiresAuth;

  DeveloperPreset({
    required this.name,
    required this.endpoint,
    this.apiKeyEnvVar,
    required this.defaultHeaders,
    required this.requiresAuth,
  });
}

class BrowserState {
  final String? currentUrl;
  final String? selectedModel;
  final bool isPanelOpen;
  final bool isKeyboardVisible;
  final String? omniboxInput;
  final List<String> browserHistory;

  BrowserState({
    this.currentUrl,
    this.selectedModel = 'Claude',
    this.isPanelOpen = false,
    this.isKeyboardVisible = false,
    this.omniboxInput,
    this.browserHistory = const [],
  });

  BrowserState copyWith({
    String? currentUrl,
    String? selectedModel,
    bool? isPanelOpen,
    bool? isKeyboardVisible,
    String? omniboxInput,
    List<String>? browserHistory,
  }) {
    return BrowserState(
      currentUrl: currentUrl ?? this.currentUrl,
      selectedModel: selectedModel ?? this.selectedModel,
      isPanelOpen: isPanelOpen ?? this.isPanelOpen,
      isKeyboardVisible: isKeyboardVisible ?? this.isKeyboardVisible,
      omniboxInput: omniboxInput ?? this.omniboxInput,
      browserHistory: browserHistory ?? this.browserHistory,
    );
  }
}

// ============================================================================
// MAIN APPLICATION
// ============================================================================

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Hive
  await Hive.initFlutter();
  Hive.registerAdapter(AIModelStateAdapter());

  // Request permissions
  await _requestPermissions();

  runApp(const FlatterApp());
}

Future<void> _requestPermissions() async {
  await [
    Permission.internet,
    Permission.accessNetworkState,
  ].request();
}

class FlatterApp extends StatelessWidget {
  const FlatterApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flatter - AI Browser',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6366F1),
          brightness: Brightness.dark,
        ),
      ),
      home: const BrowserPage(),
    );
  }
}

// ============================================================================
// BROWSER PAGE - MAIN UI
// ============================================================================

class BrowserPage extends StatefulWidget {
  const BrowserPage({Key? key}) : super(key: key);

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  late InAppWebViewController _webViewController;
  late Box<AIModelState> _modelBox;
  late TextEditingController _omniboxController;
  late TextEditingController _urlController;
  late AnimationController _panelAnimationController;
  late AnimationController _omniboxAnimationController;

  BrowserState _browserState = BrowserState();
  bool _isKeyboardVisible = false;
  List<DeveloperPreset> _presets = [];
  StreamSubscription<dynamic>? _keyboardSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _omniboxController = TextEditingController();
    _urlController = TextEditingController();
    _panelAnimationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _omniboxAnimationController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );

    _initializeApp();
  }

  Future<void> _initializeApp() async {
    // Open Hive box
    _modelBox = await Hive.openBox<AIModelState>('ai_models');

    // Initialize developer presets
    _initializeDeveloperPresets();

    // Load or create default model states
    await _loadModelStates();

    // Set initial URL
    _urlController.text = 'https://www.google.com';

    setState(() {
      _browserState = _browserState.copyWith(
        currentUrl: 'https://www.google.com',
      );
    });
  }

  void _initializeDeveloperPresets() {
    _presets = [
      DeveloperPreset(
        name: 'IDX',
        endpoint: 'https://idx.google.com/api',
        apiKeyEnvVar: 'IDX_API_KEY',
        defaultHeaders: {'X-IDX-Client': 'Flatter/1.0'},
        requiresAuth: false,
      ),
      DeveloperPreset(
        name: 'Claude',
        endpoint: 'https://api.anthropic.com/v1/messages',
        apiKeyEnvVar: 'CLAUDE_API_KEY',
        defaultHeaders: {'anthropic-version': '2023-06-01'},
        requiresAuth: true,
      ),
      DeveloperPreset(
        name: 'ChatGPT',
        endpoint: 'https://api.openai.com/v1/chat/completions',
        apiKeyEnvVar: 'OPENAI_API_KEY',
        defaultHeaders: {'Organization': ''},
        requiresAuth: true,
      ),
      DeveloperPreset(
        name: 'DeepSeek',
        endpoint: 'https://api.deepseek.com/v1/chat/completions',
        apiKeyEnvVar: 'DEEPSEEK_API_KEY',
        defaultHeaders: {'X-API-Version': '1.0'},
        requiresAuth: true,
      ),
    ];
  }

  Future<void> _loadModelStates() async {
    try {
      if (_modelBox.isEmpty) {
        // Create default entries for each preset
        for (final preset in _presets) {
          final state = AIModelState(
            modelName: preset.name,
            apiEndpoint: preset.endpoint,
            apiKey: '',
            isActive: preset.name == 'Claude',
            lastUpdated: DateTime.now(),
            responseTimeout: 30,
            customHeaders: preset.defaultHeaders,
          );
          await _modelBox.add(state);
        }
      }
    } catch (e) {
      debugPrint('Error loading model states: $e');
    }
  }

  @override
  void didChangeMetrics() {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final isKeyboardVisible = bottomInset > 0;

    if (isKeyboardVisible != _isKeyboardVisible) {
      setState(() {
        _isKeyboardVisible = isKeyboardVisible;
        _browserState = _browserState.copyWith(
          isKeyboardVisible: isKeyboardVisible,
        );
      });

      // Trigger omnibox animation based on keyboard visibility
      if (isKeyboardVisible) {
        _omniboxAnimationController.forward();
      } else {
        _omniboxAnimationController.reverse();
      }
    }
  }

  Future<void> _navigateToUrl(String url) async {
    String finalUrl = url;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      finalUrl = 'https://$url';
    }

    try {
      _urlController.text = finalUrl;
      await _webViewController.loadUrl(
        urlRequest: URLRequest(url: WebUri(finalUrl)),
      );

      setState(() {
        _browserState = _browserState.copyWith(
          currentUrl: finalUrl,
          browserHistory: [..._browserState.browserHistory, finalUrl],
        );
      });
    } catch (e) {
      debugPrint('Navigation error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Navigation error: ${e.toString()}')),
        );
      }
    }
  }

  Future<void> _syncModelState(AIModelState state) async {
    try {
      final index = _modelBox.values.toList().indexWhere(
        (element) => element.modelName == state.modelName,
      );

      if (index >= 0) {
        await _modelBox.putAt(index, state);
      }

      setState(() {
        _browserState = _browserState.copyWith(
          selectedModel: state.modelName,
        );
      });

      debugPrint('Model state synchronized: ${state.modelName}');
    } catch (e) {
      debugPrint('Error syncing model state: $e');
    }
  }

  Future<void> _queryAIModel(String query) async {
    final activePreset = _presets.firstWhere(
      (p) => p.name == _browserState.selectedModel,
      orElse: () => _presets.first,
    );

    try {
      final response = await http.post(
        Uri.parse(activePreset.endpoint),
        headers: {
          'Content-Type': 'application/json',
          ...activePreset.defaultHeaders,
        },
        body: jsonEncode({'query': query, 'model': activePreset.name}),
      ).timeout(
        Duration(seconds: 30),
        onTimeout: () => throw TimeoutException('Request timeout'),
      );

      if (response.statusCode == 200) {
        debugPrint('AI Response: ${response.body}');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Query processed successfully')),
        );
      } else {
        throw Exception('API Error: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('AI Query error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: ${e.toString()}')),
        );
      }
    }
  }

  void _togglePanel() {
    setState(() {
      _browserState = _browserState.copyWith(
        isPanelOpen: !_browserState.isPanelOpen,
      );
    });

    if (_browserState.isPanelOpen) {
      _panelAnimationController.forward();
    } else {
      _panelAnimationController.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;
    final screenSize = MediaQuery.of(context).size;

    return Scaffold(
      body: Stack(
        children: [
          // Web View
          InAppWebView(
            initialUrlRequest: URLRequest(
              url: WebUri(_browserState.currentUrl ?? 'https://www.google.com'),
            ),
            onWebViewCreated: (controller) {
              _webViewController = controller;
            },
            onLoadStart: (controller, url) {
              setState(() {
                _urlController.text = url?.toString() ?? '';
              });
            },
          ),

          // Glassmorphic AI Omnibox - Dynamically Positioned
          Positioned(
            bottom: keyboardHeight > 0 ? keyboardHeight + 16 : 80,
            left: 16,
            right: 16,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.8, end: 1.0).animate(
                CurvedAnimation(
                  parent: _omniboxAnimationController,
                  curve: Curves.easeOut,
                ),
              ),
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.white.withOpacity(0.1),
                      Colors.white.withOpacity(0.05),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.2),
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 30,
                      spreadRadius: 0,
                    ),
                  ],
                ),
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _omniboxController,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                            ),
                            decoration: InputDecoration(
                              hintText: 'Ask AI or enter URL...',
                              hintStyle: TextStyle(
                                color: Colors.white.withOpacity(0.5),
                              ),
                              border: InputBorder.none,
                              isDense: true,
                              contentPadding: EdgeInsets.zero,
                            ),
                            onSubmitted: (value) {
                              if (value.contains('http://') ||
                                  value.contains('https://')) {
                                _navigateToUrl(value);
                              } else {
                                _queryAIModel(value);
                              }
                              _omniboxController.clear();
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.indigo.withOpacity(0.3),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: () {
                                final value = _omniboxController.text;
                                if (value.contains('http://') ||
                                    value.contains('https://')) {
                                  _navigateToUrl(value);
                                } else {
                                  _queryAIModel(value);
                                }
                                _omniboxController.clear();
                              },
                              borderRadius: BorderRadius.circular(8),
                              child: Padding(
                                padding: const EdgeInsets.all(8.0),
                                child: Icon(
                                  Icons.send_rounded,
                                  color: Colors.white.withOpacity(0.8),
                                  size: 18,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Glassmorphic Right-Sliding Panel
          SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(1, 0),
              end: Offset.zero,
            ).animate(
              CurvedAnimation(
                parent: _panelAnimationController,
                curve: Curves.easeInOutCubic,
              ),
            ),
            child: Container(
              width: screenSize.width * 0.75,
              margin: const EdgeInsets.only(left: 20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withOpacity(0.15),
                    Colors.white.withOpacity(0.05),
                  ],
                ),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(20),
                  bottomLeft: Radius.circular(20),
                ),
                border: Border(
                  left: BorderSide(
                    color: Colors.white.withOpacity(0.3),
                    width: 1.5,
                  ),
                  top: BorderSide(
                    color: Colors.white.withOpacity(0.2),
                    width: 1.5,
                  ),
                  bottom: BorderSide(
                    color: Colors.white.withOpacity(0.2),
                    width: 1.5,
                  ),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.3),
                    blurRadius: 40,
                    spreadRadius: -10,
                  ),
                ],
              ),
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                child: Column(
                  children: [
                    // Panel Header
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'AI Models',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: _togglePanel,
                              child: Padding(
                                padding: const EdgeInsets.all(8.0),
                                child: Icon(
                                  Icons.close_rounded,
                                  color: Colors.white.withOpacity(0.7),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Model Presets List
                    Expanded(
                      child: ListView.builder(
                        itemCount: _presets.length,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemBuilder: (context, index) {
                          final preset = _presets[index];
                          final isSelected =
                              preset.name == _browserState.selectedModel;

                          return Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Container(
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? Colors.indigo.withOpacity(0.4)
                                    : Colors.white.withOpacity(0.08),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: isSelected
                                      ? Colors.indigo.withOpacity(0.6)
                                      : Colors.white.withOpacity(0.15),
                                  width: 1.5,
                                ),
                              ),
                              child: Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  onTap: () {
                                    setState(() {
                                      _browserState = _browserState
                                          .copyWith(selectedModel: preset.name);
                                    });
                                  },
                                  borderRadius: BorderRadius.circular(12),
                                  child: Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: [
                                            Text(
                                              preset.name,
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontSize: 14,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            if (isSelected)
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                  horizontal: 8,
                                                  vertical: 4,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: Colors.indigo
                                                      .withOpacity(0.5),
                                                  borderRadius:
                                                      BorderRadius.circular(6),
                                                ),
                                                child: const Text(
                                                  'Active',
                                                  style: TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 10,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          preset.endpoint,
                                          style: TextStyle(
                                            color: Colors.white.withOpacity(
                                              0.6,
                                            ),
                                            fontSize: 11,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),

                    // Real-time Sync Status
                    Container(
                      margin: const EdgeInsets.all(16),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.green.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: Colors.green.withOpacity(0.3),
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: Colors.green,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Real-time sync: Active',
                            style: TextStyle(
                              color: Colors.green.withOpacity(0.9),
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Panel Toggle FAB
          Positioned(
            bottom: 80,
            right: 20,
            child: FloatingActionButton(
              onPressed: _togglePanel,
              backgroundColor: Colors.indigo.withOpacity(0.8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                _browserState.isPanelOpen ? Icons.close : Icons.settings,
                color: Colors.white,
              ),
            ),
          ),

          // URL Bar
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              color: Colors.black.withOpacity(0.3),
              padding: EdgeInsets.only(
                top: MediaQuery.of(context).padding.top,
                left: 16,
                right: 16,
                bottom: 12,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.2),
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: TextField(
                          controller: _urlController,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                          decoration: InputDecoration(
                            hintText: 'Enter URL...',
                            hintStyle: TextStyle(
                              color: Colors.white.withOpacity(0.5),
                            ),
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding:
                                const EdgeInsets.symmetric(vertical: 10),
                          ),
                          onSubmitted: _navigateToUrl,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => _navigateToUrl(_urlController.text),
                      child: Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Icon(
                          Icons.done_rounded,
                          color: Colors.indigo.withOpacity(0.8),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _omniboxController.dispose();
    _urlController.dispose();
    _panelAnimationController.dispose();
    _omniboxAnimationController.dispose();
    _keyboardSubscription?.cancel();
    super.dispose();
  }
}
