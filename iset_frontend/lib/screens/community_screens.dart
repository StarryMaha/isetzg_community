import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/user.dart';
import '../state/auth_provider.dart';
import '../state/chat_provider.dart';
import '../state/p2p_provider.dart';
import '../theme.dart';
import 'chat_screen.dart';

/// Shown to guests on screens that need an account.
class LockedView extends StatelessWidget {
  final String title;
  const LockedView({super.key, required this.title});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline, size: 48, color: AppColors.muted),
            const SizedBox(height: 16),
            Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            const Text('Sign in with your student account to use this feature.',
                textAlign: TextAlign.center, style: TextStyle(color: AppColors.muted)),
            const SizedBox(height: 20),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(200, 48)),
              onPressed: () => context.read<AuthProvider>().showLogin(),
              child: const Text('Sign in'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
        child: Text(text, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
      );
}

// ---------- Chats ----------
class ChatsScreen extends StatelessWidget {
  const ChatsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatProvider>();
    return Scaffold(
      floatingActionButton: FloatingActionButton(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.black,
        onPressed: () => context.read<ChatProvider>().refreshContacts(),
        child: const Icon(Icons.refresh),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _Header('Chats'),
          if (chat.connection != ChatConnection.online)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                chat.connection == ChatConnection.connecting
                    ? 'Connecting…'
                    : 'Not connected to chat server — nearby chat available from Files',
                style: const TextStyle(color: AppColors.accent, fontSize: 12),
              ),
            ),
          Expanded(
            child: chat.contacts.isEmpty
                ? const Center(
                    child: Text('No other students registered yet.',
                        style: TextStyle(color: AppColors.muted)),
                  )
                : ListView.builder(
                    itemCount: chat.contacts.length,
                    itemBuilder: (_, i) {
                      final contact = chat.contacts[i];
                      final last = chat.lastMessage(contact.id);
                      final online = chat.onlineUsers.contains(contact.id);
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 4),
                        leading: CircleAvatar(
                          radius: 24,
                          backgroundColor: AppColors.surface2,
                          child: Text(
                            contact.name.isNotEmpty
                                ? contact.name[0].toUpperCase()
                                : '?',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        title: Text(contact.name,
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(
                          last?.content ?? 'Tap to start chatting',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: AppColors.muted),
                        ),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            if (last != null)
                              Text(last.timeLabel,
                                  style: const TextStyle(
                                      fontSize: 12, color: AppColors.muted)),
                            const SizedBox(height: 4),
                            Icon(Icons.circle,
                                size: 9,
                                color: online ? AppColors.primary : AppColors.muted),
                          ],
                        ),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => ChatScreen(peer: contact),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ---------- Groups ----------
class GroupsScreen extends StatelessWidget {
  const GroupsScreen({super.key});

  static const _groups = [
    ('Algorithms', '24 members', Icons.code),
    ('Networks', '18 members', Icons.router_outlined),
    ('Databases', '31 members', Icons.storage_outlined),
    ('English club', '12 members', Icons.translate),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Header('Study groups'),
        Expanded(
          child: GridView.count(
            crossAxisCount: 2,
            padding: const EdgeInsets.all(20),
            mainAxisSpacing: 14,
            crossAxisSpacing: 14,
            children: [
              for (final g in _groups)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                      color: AppColors.surface, borderRadius: BorderRadius.circular(20)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Icon(g.$3, color: AppColors.primary, size: 30),
                      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(g.$1, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                        Text(g.$2, style: const TextStyle(color: AppColors.muted, fontSize: 13)),
                      ]),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------- Files ----------
class FilesScreen extends StatefulWidget {
  const FilesScreen({super.key});

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  Widget _peerTile(Peer peer, String action, VoidCallback onPressed) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          const Icon(Icons.devices_other, color: AppColors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(peer.name,
                style: const TextStyle(fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis),
          ),
          TextButton(onPressed: onPressed, child: Text(action)),
        ],
      ),
    );
  }

  Widget _transferTile(TransferItem transfer) {
    final label = transfer.status == TransferStatus.done
        ? 'Completed'
        : transfer.status == TransferStatus.failed
            ? 'Failed'
            : '${(transfer.progress * 100).round()}%';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(transfer.fileName,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis),
              ),
              Text(
                '${transfer.kind == TransferKind.incoming ? 'In' : 'Out'} • $label',
                style: const TextStyle(color: AppColors.muted, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: transfer.status == TransferStatus.done ? 1 : transfer.progress),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p2p = context.watch<P2PProvider>();
    final chat = context.watch<ChatProvider>();
    final myName = context.read<AuthProvider>().user?.name ?? 'ISET student';
    final received = p2p.transfers
        .where((t) => t.kind == TransferKind.incoming && t.status == TransferStatus.done)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Header('Files'),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            children: [
              if (!p2p.supported)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Text(
                    'Direct device-to-device transfer is available on Android only. '
                    'The Wi-Fi fallback is coming in the next phase.',
                    style: TextStyle(color: AppColors.muted),
                  ),
                )
              else ...[
                FilledButton.icon(
                  onPressed: () => p2p.running ? p2p.stop() : p2p.start(myName),
                  icon: Icon(p2p.running ? Icons.stop : Icons.wifi_tethering),
                  label: Text(p2p.running ? 'Stop nearby sharing' : 'Start nearby sharing'),
                ),
                if (p2p.status.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(p2p.status,
                      style: const TextStyle(color: AppColors.accent, fontSize: 12)),
                ],
                const SizedBox(height: 20),
                const Text('Nearby devices',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                if (p2p.endpoints.isEmpty &&
                    p2p.pending.isEmpty &&
                    p2p.connected.isEmpty)
                  const Text('No devices found yet. Keep both devices unlocked.',
                      style: TextStyle(color: AppColors.muted)),
                for (final peer in p2p.endpoints)
                  _peerTile(peer, 'Connect', () => p2p.connect(peer)),
                for (final peer in p2p.pending)
                  _peerTile(peer, 'Accept', () => p2p.accept(peer)),
                for (final peer in p2p.pending)
                  _peerTile(peer, 'Reject', () => p2p.reject(peer)),
                for (final peer in p2p.connected)
                  _peerTile(peer, 'Send file', () => p2p.sendFile(peer)),
                for (final peer in p2p.connected)
                  _peerTile(peer, 'Chat', () {
                    final contact = chat.contacts.firstWhere(
                      (c) => c.name == peer.name,
                      orElse: () => const AppUser(id: -1, studentId: '', name: ''),
                    );
                    if (contact.id == -1) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                              'No cached contact named ${peer.name}. Connect to the server once to load contacts.'),
                        ),
                      );
                      return;
                    }
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ChatScreen(peer: contact),
                      ),
                    );
                  }),
                const SizedBox(height: 16),
                const Text('Transfers',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                if (p2p.transfers.isEmpty)
                  const Text('No transfers yet.',
                      style: TextStyle(color: AppColors.muted)),
                for (final transfer in p2p.transfers) _transferTile(transfer),
                const SizedBox(height: 16),
                const Text('Received files',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const Text('Downloads / ISET Community Hub files',
                    style: TextStyle(fontSize: 11, color: AppColors.muted)),
                const SizedBox(height: 8),
                if (received.isEmpty)
                  const Text('No files received yet.',
                      style: TextStyle(color: AppColors.muted)),
                for (final transfer in received)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.insert_drive_file_outlined,
                        color: AppColors.primary),
                    title: Text(transfer.fileName),
                    subtitle: Text(transfer.savedPath ?? 'Saved',
                        style: const TextStyle(fontSize: 11)),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// ---------- Profile ----------
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    Widget tile(IconData icon, String label) => ListTile(
          leading: Icon(icon, color: AppColors.muted),
          title: Text(label),
          trailing: const Icon(Icons.chevron_right, color: AppColors.muted),
          onTap: () {},
        );

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const SizedBox(height: 12),
        const Center(
          child: CircleAvatar(
            radius: 46,
            backgroundColor: AppColors.surface2,
            child: Icon(Icons.person, size: 46, color: AppColors.primary),
          ),
        ),
        const SizedBox(height: 14),
        const Center(
            child: Text('Student Name',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800))),
        const Center(
            child: Text('student@iset.tn', style: TextStyle(color: AppColors.muted))),
        const SizedBox(height: 24),
        tile(Icons.edit_outlined, 'Edit profile'),
        tile(Icons.sync_alt, 'Connection preferences'),
        tile(Icons.notifications_none, 'Notifications'),
        tile(Icons.shield_outlined, 'Privacy and security'),
        const Divider(height: 32),
        ListTile(
          leading: const Icon(Icons.logout, color: Colors.redAccent),
          title: const Text('Sign out', style: TextStyle(color: Colors.redAccent)),
          onTap: () => context.read<AuthProvider>().signOut(),
        ),
      ],
    );
  }
}
