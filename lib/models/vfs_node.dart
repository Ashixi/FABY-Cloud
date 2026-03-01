class VfsNode {
  // MARK: - PROPERTIES
  final String id;
  final String parentId;
  final String name;
  final bool isFolder;
  final bool isFavorite;
  final int? size;
  final String? encryptedFileKey;
  final String? shareId;
  final String? encryptedShareKey;

  // MARK: - CONSTRUCTORS
  VfsNode({
    required this.id,
    required this.parentId,
    required this.name,
    required this.isFolder,
    this.isFavorite = false,
    this.size,
    this.encryptedFileKey,
    this.shareId,
    this.encryptedShareKey,
  });

  // MARK: - SERIALIZATION
  Map<String, dynamic> toJson() => {
    'id': id,
    'parentId': parentId,
    'name': name,
    'isFolder': isFolder,
    'isFavorite': isFavorite,
    'size': size,
    if (encryptedFileKey != null) 'encryptedFileKey': encryptedFileKey,
    if (shareId != null) 'shareId': shareId,
    if (encryptedShareKey != null) 'encryptedShareKey': encryptedShareKey,
  };

  factory VfsNode.fromJson(Map<String, dynamic> json) => VfsNode(
    id: json['id'],
    parentId: json['parentId'],
    name: json['name'],
    isFolder: json['isFolder'] ?? false,
    isFavorite: json['isFavorite'] ?? false,
    size: json['size'],
    encryptedFileKey: json['encryptedFileKey'],
    shareId: json['shareId'],
    encryptedShareKey: json['encryptedShareKey'] ?? json['shareKey'],
  );

  // MARK: - COPY WITH
  VfsNode copyWith({
    String? id,
    String? parentId,
    String? name,
    bool? isFolder,
    bool? isFavorite,
    int? size,
    String? encryptedFileKey,
    String? shareId,
    String? encryptedShareKey,
    bool clearShareData = false,
  }) {
    return VfsNode(
      id: id ?? this.id,
      parentId: parentId ?? this.parentId,
      name: name ?? this.name,
      isFolder: isFolder ?? this.isFolder,
      isFavorite: isFavorite ?? this.isFavorite,
      size: size ?? this.size,
      encryptedFileKey: encryptedFileKey ?? this.encryptedFileKey,
      shareId: clearShareData ? null : (shareId ?? this.shareId),
      encryptedShareKey:
          clearShareData ? null : (encryptedShareKey ?? this.encryptedShareKey),
    );
  }
}
