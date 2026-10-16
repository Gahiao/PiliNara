/// 手动文件夹：用户自己取名的缓存集合，成员是条目 cid。
///
/// 只表达「用户把它们放在一起」这一层意图，以及用户排出的成员顺序。自动分组
/// （合集 / 视频页 / 分P）由条目自身的归属推导，不进这里，因此删条目不会留下
/// 需要清理的文件夹关联，成员顺序也不会被自动分组覆盖。
class DownloadFolder {
  final String id;
  String title;
  final int createdAt;
  final List<int> videoCids;

  DownloadFolder({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.videoCids,
  });

  factory DownloadFolder.fromJson(Map<String, dynamic> json) => DownloadFolder(
    id: json['id'] as String,
    title: json['title'] as String? ?? '',
    createdAt: json['createdAt'] as int? ?? 0,
    videoCids: (json['videoCids'] as List? ?? const <dynamic>[])
        .whereType<int>()
        .toList(),
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'title': title,
    'createdAt': createdAt,
    'videoCids': videoCids,
  };
}
