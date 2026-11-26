import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/user.dart';
import '../state/auth_provider.dart';
import '../state/chat_provider.dart';
import '../theme.dart';

class ChatScreen extends StatefulWidget {
  final AppUser peer;
  const ChatScreen({super.key, required this.peer});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    final chat = context.read<ChatProvider>();
    Future.microtask(() => chat.loadHistory(widget.peer.id));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    final chat = context.read<ChatProvider>();
    final sent = await chat.send(widget.peer.id, text);
    if (!mounted) return;
    if (sent) {
      _controller.clear();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(chat.error ?? 'Message not sent')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatProvider>();
    final myId = context.read<AuthProvider>().user?.id;
    final messages = chat.messages(widget.peer.id);
    final online = chat.onlineUsers.contains(widget.peer.id);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.peer.name),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Row(
              children: [
                Icon(
                  Icons.circle,
                  size: 10,
                  color: online ? AppColors.primary : AppColors.muted,
                ),
                const SizedBox(width: 6),
                Text(
                  online ? 'Online' : 'Offline',
                  style: const TextStyle(color: AppColors.muted, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (chat.connection != ChatConnection.online)
            Container(
              width: double.infinity,
              color: AppColors.surface2,
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
              child: Text(
                chat.connection == ChatConnection.connecting
                    ? 'Connecting to chat server…'
                    : 'Offline — messages cannot be sent right now',
                style: const TextStyle(color: AppColors.accent, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ),
          Expanded(
            child: chat.isLoading(widget.peer.id)
                ? const Center(child: CircularProgressIndicator())
                : messages.isEmpty
                    ? const Center(
                        child: Text('No messages yet. Say hello!',
                            style: TextStyle(color: AppColors.muted)),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: messages.length,
                        itemBuilder: (context, i) {
                          final message = messages[i];
                          final mine = message.senderId == myId;
                          return Align(
                            alignment: mine
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 10),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 10),
                              constraints: BoxConstraints(
                                maxWidth: MediaQuery.of(context).size.width * 0.75,
                              ),
                              decoration: BoxDecoration(
                                color: mine ? AppColors.primary : AppColors.surface2,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    message.content,
                                    style: TextStyle(
                                      color: mine ? Colors.black : Colors.white,
                                      fontSize: 15,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    message.timeLabel,
                                    style: TextStyle(
                                      color: mine
                                          ? Colors.black54
                                          : AppColors.muted,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      decoration: const InputDecoration(
                        hintText: 'Type a message…',
                        prefixIcon: Icon(Icons.message_outlined),
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: chat.sending ? null : _send,
                    icon: chat.sending
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send, color: AppColors.primary),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
