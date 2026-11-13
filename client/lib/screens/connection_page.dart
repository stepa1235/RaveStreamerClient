import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:luna_updates/luna_updates.dart';
import '../core/constants/localization.dart';
import '../core/theme/app_theme.dart';
import '../core/services/update_service.dart';
import 'room_page.dart';
// First Screen: Connect to Server & Join Room
class ConnectionPage extends StatefulWidget {
  final String locale;
  final ValueChanged<String> onLocaleChange;
  final String themeName;
  final ValueChanged<String> onThemeChange;
  final String initialUsername;
  final String initialServerUrl;
  final Function(String, String) onSavedConnection;
  final double chatFontSize;
  final ValueChanged<double> onChatFontSizeChange;
  final String clientId;
  final void Function(String, String, double) onPreferencesSaved;

  const ConnectionPage({
    super.key,
    required this.locale,
    required this.onLocaleChange,
    required this.themeName,
    required this.onThemeChange,
    required this.initialUsername,
    required this.initialServerUrl,
    required this.onSavedConnection,
    required this.chatFontSize,
    required this.onChatFontSizeChange,
    required this.clientId,
    required this.onPreferencesSaved,
  });

  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

class _ConnectionPageState extends State<ConnectionPage> {
  late final TextEditingController _serverController;
  late final TextEditingController _usernameController;
  final _roomController = TextEditingController(text: 'lobby');
  final _passwordController = TextEditingController();
  bool _isConnecting = false;
  bool _isPrivateRoom = false;
  String? _errorMessage;


  @override
  void initState() {
    super.initState();
    final initialUrl = widget.initialServerUrl.isNotEmpty &&
        !widget.initialServerUrl.contains('loca.lt') &&
        !widget.initialServerUrl.contains('onrender.com') &&
        !widget.initialServerUrl.contains('localhost') &&
        !widget.initialServerUrl.contains('127.0.0.1')
        ? widget.initialServerUrl
        : 'http://luna.lumigrid.ru:3000';
    _serverController = TextEditingController(
      text: initialUrl,
    );
    _usernameController = TextEditingController(
      text: widget.initialUsername.isNotEmpty ? widget.initialUsername : 'User_${(1000 + (DateTime.now().millisecond % 9000))}',
    );
  }

  @override
  void dispose() {
    _serverController.dispose();
    _usernameController.dispose();
    _roomController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  String _loc(String key) {
    return localizedValues[widget.locale]?[key] ?? key;
  }

  Future<void> _connectAndJoin() async {
    final username = _usernameController.text.trim();
    final roomId = _roomController.text.trim();

    if (username.isEmpty || roomId.isEmpty) {
      setState(() {
        _errorMessage = _loc('allFieldsRequired');
      });
      return;
    }

    setState(() {
      _isConnecting = true;
      _errorMessage = null;
    });

    String serverUrl = _serverController.text.trim();
    if (serverUrl.isEmpty ||
        serverUrl.contains('loca.lt') ||
        serverUrl.contains('onrender.com') ||
        serverUrl.contains('localhost') ||
        serverUrl.contains('127.0.0.1')) {
      serverUrl = 'http://luna.lumigrid.ru:3000';
      _serverController.text = serverUrl;
    }

    final parsedUri = Uri.tryParse(serverUrl);
    if (parsedUri == null ||
        (!parsedUri.isScheme('http') && !parsedUri.isScheme('https')) ||
        parsedUri.host.isEmpty) {
      setState(() {
        _isConnecting = false;
        _errorMessage = widget.locale == 'ru'
            ? 'Некорректный адрес сервера (http:// или https://)'
            : 'Invalid server URL (must be http:// or https://)';
      });
      return;
    }

    // Save connection settings immediately so nickname persists
    widget.onSavedConnection(username, serverUrl);

    if (!mounted) return;
    setState(() {
      _isConnecting = false;
    });

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => RoomPage(
          serverUrl: serverUrl,
          username: username,
          roomId: roomId,
          password: _isPrivateRoom ? _passwordController.text.trim() : null,
          locale: widget.locale,
          onLocaleChange: widget.onLocaleChange,
          themeName: widget.themeName,
          onThemeChange: widget.onThemeChange,
          chatFontSize: widget.chatFontSize,
          onChatFontSizeChange: widget.onChatFontSizeChange,
          clientId: widget.clientId,
        ),
      ),
    );
  }

  Future<void> _showGlobalSettingsDialog(BuildContext context) async {
    var locale = widget.locale;
    var theme = widget.themeName;
    var fontSize = widget.chatFontSize.clamp(10.0, 24.0).toDouble();
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) {
          final ru = locale == 'ru';
          final preview = appThemes[theme] ?? appThemes['Dark']!;
          return AlertDialog(
            title: Text(ru ? 'Настройки Luna' : 'Luna settings'),
            scrollable: true,
            content: SizedBox(
              width: 440,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(ru ? 'Язык' : 'Language'),
                  Wrap(
                    spacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('Русский'),
                        selected: ru,
                        onSelected: (_) => update(() => locale = 'ru'),
                      ),
                      ChoiceChip(
                        label: const Text('English'),
                        selected: !ru,
                        onSelected: (_) => update(() => locale = 'en'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(ru ? 'Оформление' : 'Appearance'),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: appThemes.entries.map((entry) {
                      return ChoiceChip(
                        label: Text(entry.key),
                        avatar: CircleAvatar(backgroundColor: entry.value.primary),
                        selected: theme == entry.key,
                        onSelected: (_) => update(() => theme = entry.key),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 16),
                  Text(ru ? 'Размер текста чата' : 'Chat text size'),
                  Slider(
                    min: 10,
                    max: 24,
                    divisions: 14,
                    value: fontSize,
                    label: '${fontSize.round()} px',
                    semanticFormatterCallback: (value) => '${value.round()} px',
                    onChanged: (value) => update(() => fontSize = value),
                  ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: preview.cardColor,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: preview.primary),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Text(
                        ru ? 'Так будет выглядеть сообщение в чате.' : 'This is how a chat message will look.',
                        style: TextStyle(color: Colors.white, fontSize: fontSize),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: () => update(() {
                        locale = 'ru';
                        theme = 'Dark';
                        fontSize = 12;
                      }),
                      child: Text(ru ? 'По умолчанию' : 'Restore defaults'),
                    ),
                  ),
                  const Divider(),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.system_update),
                    title: Text(ru ? 'Проверить обновления' : 'Check for updates'),
                    subtitle: Text('Luna $globalAppVersion'),
                    onTap: () => Navigator.of(dialogContext).pop(false),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(ru ? 'Отмена' : 'Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(ru ? 'Сохранить' : 'Save'),
              ),
            ],
          );
        },
      ),
    );
    if (!mounted) return;
    if (saved == true) {
      widget.onPreferencesSaved(locale, theme, fontSize);
    } else if (saved == false) {
      await checkLunaUpdate(
        this.context,
        currentVersion: globalAppVersion,
        locale: widget.locale,
        platform: UpdatePlatform.windows,
        install: installWindowsUpdate,
        manual: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeData = appThemes[widget.themeName] ?? appThemes['Dark']!;
    return Scaffold(
      body: Stack(
        children: [
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: themeData.bgGradient,
              ),
            ),
            child: Center(
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 450),
                    child: Container(
                      padding: const EdgeInsets.all(32.0),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.03),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.08),
                          width: 1.5,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.3),
                            blurRadius: 20,
                            spreadRadius: 2,
                          )
                        ],
                      ),
                      child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Top Action Bar: Settings & Language
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF6C63FF).withOpacity(0.2),
                              foregroundColor: const Color(0xFF00F2FE),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                                side: const BorderSide(color: Color(0xFF00F2FE), width: 0.8),
                              ),
                            ),
                            icon: const Icon(Icons.settings, size: 16),
                            label: Text(
                              widget.locale == 'ru' ? 'Настройки' : 'Settings',
                              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                            ),
                            onPressed: () => _showGlobalSettingsDialog(context),
                          ),
                          DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: widget.locale,
                              dropdownColor: const Color(0xFF161426),
                              style: const TextStyle(fontSize: 12, color: Colors.white),
                              icon: const Icon(Icons.language, size: 16, color: Color(0xFF00F2FE)),
                              items: const [
                                DropdownMenuItem(value: 'ru', child: Text('RU')),
                                DropdownMenuItem(value: 'en', child: Text('EN')),
                              ],
                              onChanged: (lang) {
                                if (lang != null) widget.onLocaleChange(lang);
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),

                      // Header Logo
                      Center(
                        child: Column(
                          children: [
                            Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(24),
                                boxShadow: [
                                  BoxShadow(
                                    color: const Color(0xFF00F2FE).withOpacity(0.3),
                                    blurRadius: 20,
                                    spreadRadius: 2,
                                  )
                                ],
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(24),
                                child: Image.asset(
                                  'assets/logo.png',
                                  width: 84,
                                  height: 84,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => Container(
                                    padding: const EdgeInsets.all(16),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF6C63FF).withOpacity(0.15),
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      Icons.play_circle_filled,
                                      size: 56,
                                      color: Color(0xFF00F2FE),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              _loc('title'),
                              style: const TextStyle(
                                fontSize: 32,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1.5,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 32),



                      // Username Input (Max 15 characters to fit in the audience window)
                      _buildTextField(
                        controller: _usernameController,
                        label: _loc('nameLabel'),
                        icon: Icons.person_outline,
                        hint: _loc('nameHint'),
                        inputFormatters: [
                          LengthLimitingTextInputFormatter(15),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // Room ID Input (Regex filters out non-english and special symbols)
                      _buildTextField(
                        controller: _roomController,
                        label: _loc('roomLabel'),
                        icon: Icons.vpn_key_outlined,
                        hint: _loc('roomHint'),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9]')),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // Private Room Switch
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Icon(
                                _isPrivateRoom ? Icons.lock_outline : Icons.lock_open,
                                size: 18,
                                color: _isPrivateRoom ? const Color(0xFF00F2FE) : Colors.white54,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                widget.locale == 'ru' ? 'Приватная комната' : 'Private Room',
                                style: TextStyle(
                                  color: _isPrivateRoom ? Colors.white : Colors.white54,
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ),
                          Switch(
                            value: _isPrivateRoom,
                            activeColor: const Color(0xFF00F2FE),
                            onChanged: (val) {
                              setState(() {
                                _isPrivateRoom = val;
                              });
                            },
                          ),
                        ],
                      ),
                      if (_isPrivateRoom) ...[
                        const SizedBox(height: 12),
                        _buildTextField(
                          controller: _passwordController,
                          label: widget.locale == 'ru' ? 'ПАРОЛЬ КОМНАТЫ' : 'ROOM PASSWORD',
                          icon: Icons.password,
                          hint: widget.locale == 'ru' ? 'Введите пароль' : 'Enter password',
                        ),
                      ],
                      const SizedBox(height: 24),

                      // Error message container
                      if (_errorMessage != null) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                          decoration: BoxDecoration(
                            color: Colors.red.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.red.withOpacity(0.3)),
                          ),
                          child: Text(
                            _errorMessage!,
                            style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                          ),
                        ),
                        const SizedBox(height: 20),
                      ],

                      // Join Button
                      ElevatedButton(
                        onPressed: _isConnecting ? null : _connectAndJoin,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF6C63FF),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          elevation: 8,
                          shadowColor: const Color(0xFF6C63FF).withOpacity(0.4),
                        ),
                        child: _isConnecting
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: Colors.white,
                                ),
                              )
                            : Text(
                                _loc('btnConnect'),
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1.2,
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
      ),
          Positioned(
            left: 16,
            bottom: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.4),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withOpacity(0.1)),
              ),
              child: Text(
                globalAppVersion,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.6),
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    required String hint,
    List<TextInputFormatter>? inputFormatters,
  }) {
    return TextField(
      controller: controller,
      inputFormatters: inputFormatters,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon, color: const Color(0xFF6C63FF).withOpacity(0.7)),
        filled: true,
        fillColor: Colors.white.withOpacity(0.02),
        labelStyle: TextStyle(color: Colors.white.withOpacity(0.6)),
        hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.white.withOpacity(0.08)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFF6C63FF), width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: 16),
      ),
    );
  }
}
