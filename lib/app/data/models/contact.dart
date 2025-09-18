/// Contact data model representing a simple person/contact card.
/// Supports JSON serialization and size estimation for NFC payload limits.
class Contact {
  final String name;
  final String phone;
  final String email;

  const Contact({required this.name, required this.phone, required this.email});

  Contact copyWith({String? name, String? phone, String? email}) => Contact(
    name: name ?? this.name,
    phone: phone ?? this.phone,
    email: email ?? this.email,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'phone': phone,
    'email': email,
  };

  factory Contact.fromJson(Map<String, dynamic> json) => Contact(
    name: (json['name'] ?? '') as String,
    phone: (json['phone'] ?? '') as String,
    email: (json['email'] ?? '') as String,
  );

  /// Estimate the UTF-8 byte size of JSON representation.
  int byteSize() {
    // Basic naive estimation (Dart strings are UTF-16 but we assume ASCII mostly here).
    return toJson().toString().codeUnits.length;
  }

  @override
  String toString() => 'Contact(name: $name, phone: $phone, email: $email)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Contact &&
          runtimeType == other.runtimeType &&
          name == other.name &&
          phone == other.phone &&
          email == other.email;

  @override
  int get hashCode => Object.hash(name, phone, email);
}
