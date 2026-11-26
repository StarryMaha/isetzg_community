class ChatMessage {
  final int id;
  final int senderId;
  final int receiverId;
  final String content;
  final String timestamp;

  const ChatMessage({
    required this.id,
    required this.senderId,
    required this.receiverId,
    required this.content,
    required this.timestamp,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: _asInt(json['id']),
      senderId: _asInt(json['sender_id']),
      receiverId: _asInt(json['receiver_id']),
      content: json['content']?.toString() ?? '',
      timestamp: json['timestamp']?.toString() ?? '',
    );
  }

  static int _asInt(dynamic value) {
    if (value is int) return value;
    return int.parse(value.toString());
  }

  DateTime? get sentAt {
    if (timestamp.isEmpty) return null;
    try {
      final text = timestamp.contains('T') ? timestamp : timestamp.replaceFirst(' ', 'T');
      final utc = text.endsWith('Z') ? text : '${text}Z';
      return DateTime.parse(utc).toLocal();
    } catch (_) {
      return null;
    }
  }

  String get timeLabel {
    final time = sentAt;
    if (time == null) return '';
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}
