import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:faby/models/vfs_node.dart';
import 'package:faby/services/vfs_manager.dart';
import '../translations.dart';

class SideFileManager extends StatefulWidget {
  final Function(VfsNode)? onFileTap;
  final VoidCallback? onClose;

  const SideFileManager({super.key, this.onFileTap, this.onClose});

  @override
  State<SideFileManager> createState() => _SideFileManagerState();
}

class _SideFileManagerState extends State<SideFileManager> {
  // MARK: - STATE
  final _vfsManager = VfsManager();
  bool _isLoading = true;

  // MARK: - LIFECYCLE
  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    await _vfsManager.initDB();
    setState(() {
      _isLoading = false;
    });
  }

  // MARK: - BUILD MAIN
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 300,
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(context),
          const Divider(height: 1, thickness: 1, color: Colors.white10),
          Expanded(
            child:
                _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : _buildFileTree(),
          ),
        ],
      ),
    );
  }

  // MARK: - UI COMPONENTS
  Widget _buildHeader(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(left: 16, right: 8, top: 12, bottom: 12),
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              const Icon(Icons.cloud_outlined, size: 20, color: Colors.blue),
              const SizedBox(width: 8),
              Text(
                tr(context, 'storage'),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.refresh, size: 20),
                tooltip: tr(context, 'refresh'),
                onPressed: () {
                  setState(() => _isLoading = true);
                  _vfsManager.sync().then((_) {
                    if (mounted) setState(() => _isLoading = false);
                  });
                },
              ),
              if (widget.onClose != null)
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  tooltip: tr(context, 'close_btn'),
                  onPressed: widget.onClose,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFileTree() {
    final rootNodes = _vfsManager.getChildren('root');

    if (rootNodes.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_open, size: 48, color: Colors.grey.shade300),
            const SizedBox(height: 16),
            Text(
              tr(context, 'storage_empty'),
              style: TextStyle(color: Colors.grey.shade600),
            ),
          ],
        ),
      );
    }

    rootNodes.sort((a, b) {
      if (a.isFolder && !b.isFolder) return -1;
      if (!a.isFolder && b.isFolder) return 1;
      return a.name.compareTo(b.name);
    });

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: rootNodes.length,
      itemBuilder: (context, index) {
        return _buildNodeItem(rootNodes[index], 0);
      },
    );
  }

  Widget _buildNodeItem(VfsNode node, int level) {
    final double leftPadding = 16.0 + (level * 16.0);

    if (node.isFolder) {
      final children = _vfsManager.getChildren(node.id);

      children.sort((a, b) {
        if (a.isFolder && !b.isFolder) return -1;
        if (!a.isFolder && b.isFolder) return 1;
        return a.name.compareTo(b.name);
      });

      return Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.only(left: leftPadding, right: 8),
          leading: const Icon(
            Icons.folder_rounded,
            color: Colors.amber,
            size: 22,
          ),
          title: Text(
            node.name,
            style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14),
            overflow: TextOverflow.ellipsis,
          ),
          childrenPadding: EdgeInsets.zero,
          children:
              children
                  .map((child) => _buildNodeItem(child, level + 1))
                  .toList(),
        ),
      );
    }

    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.only(left: leftPadding + 8, right: 8),
      leading: Icon(
        Icons.insert_drive_file_rounded,
        color: Colors.blue.shade600,
        size: 20,
      ),
      title: Text(
        node.name,
        style: const TextStyle(fontSize: 13),
        overflow: TextOverflow.ellipsis,
      ),
      trailing:
          node.shareId != null
              ? const Icon(Icons.link_rounded, size: 14, color: Colors.blue)
              : null,
      onTap: () {
        HapticFeedback.selectionClick();
        if (widget.onFileTap != null) {
          widget.onFileTap!(node);
        }
      },
    );
  }
}
