class AppUser {
  final int id;
  final String studentId;
  final String name;

  const AppUser({required this.id, required this.studentId, required this.name});

  factory AppUser.fromJson(Map<String, dynamic> json) {
    return AppUser(
      id: json['id'] is int ? json['id'] as int : int.parse(json['id'].toString()),
      studentId: json['student_id'] as String,
      name: json['name'] as String,
    );
  }
}
