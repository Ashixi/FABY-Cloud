class UserData {
  // MARK: - PROPERTIES
  final String userId;
  final String username;
  final String email;
  final String publicId;
  final bool isPro;
  final int storageLimitMb;
  final double storageUsedMb;

  // MARK: - CONSTRUCTORS
  UserData({
    required this.userId,
    required this.username,
    required this.email,
    required this.publicId,
    this.isPro = false,
    this.storageLimitMb = 500,
    this.storageUsedMb = 0.0,
  });

  // MARK: - SERIALIZATION
  factory UserData.fromJson(Map<String, dynamic> json) {
    return UserData(
      userId: json['user_id'] ?? '',
      username: json['username'] ?? '',
      email: json['email'] ?? '',
      publicId: json['public_id'] ?? '',
      isPro: json['is_pro'] == true || json['is_pro'] == 1,
      storageLimitMb: json['storage_limit_mb'] ?? 500,
      storageUsedMb:
          (json['storage_used_mb'] ?? json['storageUsedMb'] ?? 0).toDouble(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'user_id': userId,
      'username': username,
      'email': email,
      'public_id': publicId,
      'is_pro': isPro,
      'storage_limit_mb': storageLimitMb,
      'storage_used_mb': storageUsedMb,
    };
  }
}
