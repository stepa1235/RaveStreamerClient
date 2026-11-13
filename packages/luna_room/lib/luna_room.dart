import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class RoomInvite {
  const RoomInvite(this.roomId, this.token);

  final String roomId;
  final String token;

  Uri toLink(String server) {
    final base = Uri.parse(server);
    return Uri(
      scheme: base.scheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: '/invite',
      fragment: Uri(queryParameters: {'room': roomId, 'token': token}).query,
    );
  }

  static RoomInvite? parse(String text, String server) {
    var link = Uri.tryParse(text.trim());
    final base = Uri.tryParse(server);
    if (link?.scheme == 'luna' && link?.host == 'invite') {
      try {
        final parameters = Uri.splitQueryString(link!.fragment);
        final origin = Uri.tryParse(parameters.remove('server') ?? '');
        if (origin == null ||
            !origin.hasAuthority ||
            origin.userInfo.isNotEmpty)
          return null;
        link = origin.replace(
          path: '/invite',
          fragment: Uri(queryParameters: parameters).query,
        );
      } on FormatException {
        return null;
      }
    }
    if (link == null ||
        base == null ||
        !link.hasAuthority ||
        !base.hasAuthority ||
        link.scheme != base.scheme ||
        link.host != base.host ||
        link.port != base.port ||
        link.userInfo.isNotEmpty ||
        link.path != '/invite') {
      return null;
    }
    try {
      final parts = Uri.splitQueryString(link.fragment);
      final room = parts['room'] ?? '';
      final token = parts['token'] ?? '';
      if (RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(room) &&
          RegExp(r'^[a-f0-9]{48}$').hasMatch(token)) {
        return RoomInvite(room, token);
      }
    } on FormatException {
      return null;
    }
    return null;
  }
}

List<Map<String, dynamic>> roomEntries(dynamic data) => data is List
    ? data
          .whereType<Map>()
          .map((entry) => Map<String, dynamic>.from(entry))
          .toList()
    : const [];

String bookmarkTime(num seconds) {
  final whole = seconds.floor();
  final minutes = (whole ~/ 60).toString();
  return '$minutes:${(whole % 60).toString().padLeft(2, '0')}';
}

class RoomTools extends StatefulWidget {
  const RoomTools({
    super.key,
    required this.russian,
    required this.roomId,
    required this.server,
    required this.socketId,
    required this.state,
    required this.send,
    required this.request,
    required this.diagnose,
    required this.bookmark,
    required this.canBookmark,
  });

  final bool russian;
  final String roomId;
  final String server;
  final String? Function() socketId;
  final ValueNotifier<Map<String, dynamic>> state;
  final void Function(String, Map<String, dynamic>) send;
  final Future<dynamic> Function(String, Map<String, dynamic>) request;
  final Future<String> Function() diagnose;
  final VoidCallback bookmark;
  final bool Function() canBookmark;

  @override
  State<RoomTools> createState() => _RoomToolsState();
}

class _RoomToolsState extends State<RoomTools> {
  final _url = TextEditingController();
  final _title = TextEditingController();
  int _minutes = 60;
  bool _busy = false;
  String? _feedback;

  String text(String ru, String en) => widget.russian ? ru : en;

  @override
  void dispose() {
    _url.dispose();
    _title.dispose();
    super.dispose();
  }

  Future<void> _run(Future<String?> Function() operation) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _feedback = null;
    });
    String? result;
    try {
      result = await operation();
    } catch (_) {
      result = text(
        'Не удалось выполнить действие. Проверьте подключение.',
        'Action failed. Check your connection.',
      );
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _feedback = result;
      });
    }
  }

  String _readiness(Object? status) => switch (status) {
    'ready' => text('Готов', 'Ready'),
    'buffering' => text('Буферизация', 'Buffering'),
    'loading' => text('Загрузка', 'Loading'),
    _ => text('Нет данных', 'Unknown'),
  };

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, dynamic>>(
      valueListenable: widget.state,
      builder: (_, state, _) {
        final viewers = roomEntries(state['viewers']);
        final proposals = [...roomEntries(state['proposals'])]
          ..sort((a, b) => (b['votes'] as num).compareTo(a['votes'] as num));
        final me = viewers
            .where((user) => user['id'] == widget.socketId())
            .firstOrNull;
        final host = me?['isHost'] == true;
        final controls = host || me?['cohost'] == true;
        return AlertDialog(
          title: Text(text('Совместный просмотр', 'Watch together')),
          scrollable: true,
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (state.isEmpty)
                  Text(
                    text(
                      'Инструменты комнаты недоступны. Проверьте соединение и версию сервера.',
                      'Room tools are unavailable. Check the connection and server version.',
                    ),
                  ),
                if (state['autoPaused'] == true)
                  Text(
                    text(
                      'Пауза: ждём загрузку видео у зрителей.',
                      'Paused while viewers buffer.',
                    ),
                  ),
                if (host) ...[
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      text(
                        'Пауза при буферизации',
                        'Pause when a viewer buffers',
                      ),
                    ),
                    value: state['autoPause'] == true,
                    onChanged: (enabled) =>
                        widget.send('room-auto-pause', {'enabled': enabled}),
                  ),
                  Row(
                    children: [
                      DropdownButton<int>(
                        value: _minutes,
                        items: [
                          DropdownMenuItem(
                            value: 15,
                            child: Text(text('15 мин', '15 min')),
                          ),
                          DropdownMenuItem(
                            value: 60,
                            child: Text(text('1 час', '1 hour')),
                          ),
                          DropdownMenuItem(
                            value: 1440,
                            child: Text(text('1 день', '1 day')),
                          ),
                        ],
                        onChanged: (value) =>
                            setState(() => _minutes = value ?? _minutes),
                      ),
                      const SizedBox(width: 12),
                      Flexible(
                        child: TextButton.icon(
                          icon: const Icon(Icons.link),
                          label: Text(
                            text('Скопировать приглашение', 'Copy invite'),
                          ),
                          onPressed: _busy
                              ? null
                              : () => _run(() async {
                                  final result = await widget.request(
                                    'room-invite',
                                    {'minutes': _minutes},
                                  );
                                  if (result is! Map ||
                                      result['token'] is! String)
                                    throw StateError('Invite unavailable');
                                  final invite = RoomInvite(
                                    widget.roomId,
                                    result['token'] as String,
                                  );
                                  await Clipboard.setData(
                                    ClipboardData(
                                      text: invite
                                          .toLink(widget.server)
                                          .toString(),
                                    ),
                                  );
                                  return text(
                                    'Ссылка скопирована. Гость может вставить её в поле комнаты Luna.',
                                    'Link copied. Guests can paste it into the Luna room field.',
                                  );
                                }),
                        ),
                      ),
                    ],
                  ),
                ],
                for (final user in viewers)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(user['username'].toString()),
                    subtitle: Text(_readiness(user['readiness'])),
                    trailing: user['isHost'] == true
                        ? Text(text('Хост', 'Host'))
                        : host
                        ? IconButton(
                            tooltip: user['cohost'] == true
                                ? text(
                                    'Убрать права соведущего',
                                    'Remove co-host',
                                  )
                                : text('Назначить соведущим', 'Make co-host'),
                            icon: Icon(
                              user['cohost'] == true
                                  ? Icons.manage_accounts
                                  : Icons.person_add_alt,
                            ),
                            onPressed: () => widget.send('room-cohost', {
                              'targetId': user['id'],
                              'enabled': user['cohost'] != true,
                            }),
                          )
                        : user['cohost'] == true
                        ? Text(text('Соведущий', 'Co-host'))
                        : null,
                  ),
                if (me != null) ...[
                  const Divider(),
                  Text(
                    text('Предложения в очередь', 'Queue suggestions'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  TextField(
                    controller: _url,
                    keyboardType: TextInputType.url,
                    maxLength: 2048,
                    decoration: InputDecoration(
                      labelText: text('Ссылка на видео', 'Video URL'),
                      counterText: '',
                    ),
                  ),
                  TextField(
                    controller: _title,
                    maxLength: 120,
                    decoration: InputDecoration(
                      labelText: text(
                        'Название (необязательно)',
                        'Title (optional)',
                      ),
                      counterText: '',
                    ),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _run(() async {
                            final result = await widget.request(
                              'room-propose',
                              {
                                'url': _url.text.trim(),
                                'title': _title.text.trim(),
                              },
                            );
                            if (result is! Map || result['ok'] != true) {
                              return text(
                                'Проверьте ссылку. Возможно, она уже предложена или список заполнен.',
                                'Check the URL. It may already be suggested or the list may be full.',
                              );
                            }
                            if (mounted) {
                              _url.clear();
                              _title.clear();
                            }
                            return text(
                              'Видео предложено.',
                              'Video suggested.',
                            );
                          }),
                    child: Text(text('Предложить видео', 'Suggest video')),
                  ),
                  for (final proposal in proposals)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        proposal['videoName'].toString(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        "${proposal['author']}\n${proposal['videoUrl']}",
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          IconButton(
                            tooltip: text(
                              'Голосовать / отменить голос',
                              'Vote / undo vote',
                            ),
                            icon: const Icon(Icons.thumb_up_outlined),
                            onPressed: () => widget.send('room-vote', {
                              'id': proposal['id'],
                            }),
                          ),
                          Text('${proposal['votes']}'),
                          if (controls) ...[
                            IconButton(
                              tooltip: text(
                                'Добавить в очередь',
                                'Add to queue',
                              ),
                              icon: const Icon(Icons.playlist_add),
                              onPressed: () => widget.send('room-review', {
                                'id': proposal['id'],
                                'accept': true,
                              }),
                            ),
                            IconButton(
                              tooltip: text('Отклонить', 'Reject'),
                              icon: const Icon(Icons.close),
                              onPressed: () => widget.send('room-review', {
                                'id': proposal['id'],
                                'accept': false,
                              }),
                            ),
                          ],
                        ],
                      ),
                    ),
                  const Divider(),
                  TextButton.icon(
                    onPressed: widget.canBookmark()
                        ? () {
                            widget.bookmark();
                            Navigator.of(context).pop();
                          }
                        : null,
                    icon: const Icon(Icons.bookmark_add_outlined),
                    label: Text(
                      text(
                        'Отметить текущий момент в чате',
                        'Bookmark this moment in chat',
                      ),
                    ),
                  ),
                ],
                TextButton.icon(
                  onPressed: _busy ? null : () => _run(widget.diagnose),
                  icon: const Icon(Icons.network_check),
                  label: Text(text('Проверить связь', 'Check connection')),
                ),
                if (_busy) const LinearProgressIndicator(),
                if (_feedback != null) SelectableText(_feedback!),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(text('Закрыть', 'Close')),
            ),
          ],
        );
      },
    );
  }
}
