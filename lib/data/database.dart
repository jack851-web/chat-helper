import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'models/contact.dart';
import 'models/chat_memory.dart';
import 'models/screenshot_record.dart';
import 'models/suggestion.dart';
import 'models/draft.dart';

class AppDatabase {
  static AppDatabase? _instance;
  late Database _db;

  AppDatabase._();

  static AppDatabase get instance {
    _instance ??= AppDatabase._();
    return _instance!;
  }

  Database get db => _db;

  Future<void> initialize() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'chat_helper.db');
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: _onCreate,
      onConfigure: _onConfigure,
    );
  }

  Future<void> _onConfigure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE contacts (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        avatar_uri TEXT,
        relationship TEXT,
        gender TEXT,
        notes TEXT,
        tone_preference TEXT DEFAULT 'neutral',
        length_preference TEXT DEFAULT 'medium',
        creativity_preference REAL DEFAULT 0.5,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        last_active_at INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE chat_memories (
        id TEXT PRIMARY KEY,
        contact_id TEXT NOT NULL,
        screenshot_id TEXT,
        speaker TEXT NOT NULL CHECK(speaker IN ('me', 'partner')),
        content TEXT NOT NULL,
        timestamp_estimate INTEGER,
        platform TEXT,
        created_at INTEGER NOT NULL,
        is_deleted INTEGER DEFAULT 0,
        FOREIGN KEY (contact_id) REFERENCES contacts(id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
        'CREATE INDEX idx_memories_contact ON chat_memories(contact_id, created_at)');

    await db.execute('''
      CREATE TABLE screenshots (
        id TEXT PRIMARY KEY,
        contact_id TEXT,
        file_path TEXT NOT NULL,
        thumbnail_path TEXT,
        ai1_result_json TEXT,
        ai1_status TEXT DEFAULT 'pending',
        ai1_error TEXT,
        parse_confidence TEXT DEFAULT 'high',
        created_at INTEGER NOT NULL,
        FOREIGN KEY (contact_id) REFERENCES contacts(id) ON DELETE SET NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE suggestions (
        id TEXT PRIMARY KEY,
        contact_id TEXT NOT NULL,
        screenshot_id TEXT,
        style TEXT,
        content TEXT NOT NULL,
        reason TEXT,
        is_favorited INTEGER DEFAULT 0,
        is_copied INTEGER DEFAULT 0,
        created_at INTEGER NOT NULL,
        FOREIGN KEY (contact_id) REFERENCES contacts(id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE drafts (
        id TEXT PRIMARY KEY,
        contact_id TEXT,
        suggestion_id TEXT,
        content TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        FOREIGN KEY (contact_id) REFERENCES contacts(id) ON DELETE SET NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE favorites (
        id TEXT PRIMARY KEY,
        contact_id TEXT,
        content TEXT NOT NULL,
        category TEXT,
        source TEXT DEFAULT 'ai_suggestion',
        source_id TEXT,
        created_at INTEGER NOT NULL,
        FOREIGN KEY (contact_id) REFERENCES contacts(id) ON DELETE SET NULL
      )
    ''');
  }

  // ---- Contact CRUD ----

  Future<List<Contact>> getContacts({String? searchQuery}) async {
    if (searchQuery != null && searchQuery.isNotEmpty) {
      final escaped = _escapeLike(searchQuery);
      final results = await _db.query(
        'contacts',
        where: 'name LIKE ? ESCAPE \'\\\' OR relationship LIKE ? ESCAPE \'\\\'',
        whereArgs: ['%$escaped%', '%$escaped%'],
        orderBy: 'updated_at DESC',
      );
      return results.map((e) => Contact.fromMap(e)).toList();
    }
    final results =
        await _db.query('contacts', orderBy: 'last_active_at DESC');
    return results.map((e) => Contact.fromMap(e)).toList();
  }

  Future<Contact?> getContact(String id) async {
    final results = await _db.query('contacts', where: 'id = ?', whereArgs: [id]);
    if (results.isEmpty) return null;
    return Contact.fromMap(results.first);
  }

  Future<void> insertContact(Contact contact) async {
    await _db.insert('contacts', contact.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> updateContact(Contact contact) async {
    await _db.update('contacts', contact.toMap(),
        where: 'id = ?', whereArgs: [contact.id]);
  }

  Future<void> deleteContact(String id) async {
    // 先清理该联系人关联的截图物理文件（ON DELETE SET NULL 不会删文件）
    await cleanupContactScreenshots(id);
    await _db.delete('contacts', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> touchContact(String id) async {
    await _db.update('contacts', {'last_active_at': DateTime.now().millisecondsSinceEpoch},
        where: 'id = ?', whereArgs: [id]);
  }

  // ---- ChatMemory ----

  Future<List<ChatMemory>> getMemories(String contactId,
      {int limit = 50, int offset = 0}) async {
    final results = await _db.query(
      'chat_memories',
      where: 'contact_id = ? AND is_deleted = 0',
      whereArgs: [contactId],
      orderBy: 'created_at ASC',
      limit: limit,
      offset: offset,
    );
    return results.map((e) => ChatMemory.fromMap(e)).toList();
  }

  Future<void> insertMemory(ChatMemory memory) async {
    await _db.insert('chat_memories', memory.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> insertMemories(List<ChatMemory> memories) async {
    final batch = _db.batch();
    for (final m in memories) {
      batch.insert('chat_memories', m.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<void> deleteMemory(String id) async {
    await _db.update('chat_memories', {'is_deleted': 1},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> clearContactMemories(String contactId) async {
    await _db.update('chat_memories', {'is_deleted': 1},
        where: 'contact_id = ?', whereArgs: [contactId]);
  }

  Future<List<ChatMemory>> searchMemories(
      {String? keyword, String? contactId}) async {
    var where = 'is_deleted = 0';
    final args = <dynamic>[];
    if (keyword != null && keyword.isNotEmpty) {
      where += ' AND content LIKE ? ESCAPE \'\\\'';
      args.add('%${_escapeLike(keyword)}%');
    }
    if (contactId != null) {
      where += ' AND contact_id = ?';
      args.add(contactId);
    }
    final results = await _db.query('chat_memories',
        where: where, whereArgs: args, orderBy: 'created_at DESC', limit: 200);
    return results.map((e) => ChatMemory.fromMap(e)).toList();
  }

  /// 转义LIKE语句中的通配符 % 和 _
  static String _escapeLike(String s) =>
      s.replaceAll('\\', '\\\\').replaceAll('%', '\\%').replaceAll('_', '\\_');

  // ---- Screenshot ----

  Future<void> insertScreenshot(ScreenshotRecord record) async {
    await _db.insert('screenshots', record.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> updateScreenshot(ScreenshotRecord record) async {
    await _db.update('screenshots', record.toMap(),
        where: 'id = ?', whereArgs: [record.id]);
  }

  Future<ScreenshotRecord?> getScreenshot(String id) async {
    final rows = await _db.query('screenshots',
        where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return ScreenshotRecord.fromMap(rows.first);
  }

  /// 物理删除截图文件 - 用于记忆库清理时联动清理磁盘上的 PII。
  /// 删除失败不影响主流程（仅记录日志）。
  Future<void> deleteScreenshotFile(String? path) async {
    if (path == null || path.isEmpty) return;
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      // PII 删除失败记录到日志（release 包中 print 仍可见于 logcat）
      // 不抛异常以避免阻塞用户操作
      debugPrint('[DB] PII 文件删除失败: $path (${e.runtimeType})');
    }
  }

  /// 删除一条记忆并清理其关联截图（仅当截图无其他引用时）。
  Future<void> deleteMemoryCascade(String id) async {
    // 1) 找到关联的 screenshot_id
    final rows = await _db
        .query('chat_memories', columns: ['screenshot_id'], where: 'id = ?', whereArgs: [id]);
    final screenshotId = rows.isNotEmpty ? rows.first['screenshot_id'] as String? : null;

    // 2) 软删除记忆
    await _db.update('chat_memories', {'is_deleted': 1},
        where: 'id = ?', whereArgs: [id]);

    // 3) 软删除后检查该截图是否还被其他记忆引用
    if (screenshotId != null) {
      final refs = await _db.query('chat_memories',
          where: 'screenshot_id = ? AND is_deleted = 0',
          whereArgs: [screenshotId],
          limit: 1);
      if (refs.isEmpty) {
        final screenshot = await getScreenshot(screenshotId);
        if (screenshot != null) {
          await deleteScreenshotFile(screenshot.filePath);
          await deleteScreenshotFile(screenshot.thumbnailPath);
          await _db.delete('screenshots', where: 'id = ?', whereArgs: [screenshotId]);
        }
      }
    }
  }

  /// 物理级清理某个联系人的全部截图文件
  Future<void> cleanupContactScreenshots(String contactId) async {
    final rows = await _db.query('screenshots',
        columns: ['file_path', 'thumbnail_path'],
        where: 'contact_id = ?', whereArgs: [contactId]);
    for (final row in rows) {
      await deleteScreenshotFile(row['file_path'] as String?);
      await deleteScreenshotFile(row['thumbnail_path'] as String?);
    }
    await _db.delete('screenshots', where: 'contact_id = ?', whereArgs: [contactId]);
  }

  // ---- Suggestion ----

  Future<void> insertSuggestion(Suggestion suggestion) async {
    await _db.insert('suggestions', suggestion.toMap());
  }

  Future<void> insertSuggestions(List<Suggestion> suggestions) async {
    final batch = _db.batch();
    for (final s in suggestions) {
      batch.insert('suggestions', s.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<void> updateSuggestion(Suggestion suggestion) async {
    await _db.update('suggestions', suggestion.toMap(),
        where: 'id = ?', whereArgs: [suggestion.id]);
  }

  Future<List<Suggestion>> getRecentSuggestions(String contactId,
      {int limit = 10}) async {
    final results = await _db.query('suggestions',
        where: 'contact_id = ?',
        whereArgs: [contactId],
        orderBy: 'created_at DESC',
        limit: limit);
    return results.map((e) => Suggestion.fromMap(e)).toList();
  }

  Future<List<Suggestion>> getFavoritedSuggestions() async {
    final results = await _db.query('suggestions',
        where: 'is_favorited = 1', orderBy: 'created_at DESC');
    return results.map((e) => Suggestion.fromMap(e)).toList();
  }

  /// 按 screenshotId + content 查找已有建议（用于去重/更新）
  Future<Suggestion?> findSuggestionByContent(
      String? screenshotId, String content) async {
    final rows = await _db.query(
      'suggestions',
      where: 'screenshot_id = ? AND content = ?',
      whereArgs: [screenshotId, content],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Suggestion.fromMap(rows.first);
  }

  // ---- Draft ----

  Future<List<Draft>> getDrafts() async {
    final results =
        await _db.query('drafts', orderBy: 'updated_at DESC');
    return results.map((e) => Draft.fromMap(e)).toList();
  }

  Future<void> insertDraft(Draft draft) async {
    await _db.insert('drafts', draft.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> updateDraft(Draft draft) async {
    await _db.update('drafts', draft.toMap(),
        where: 'id = ?', whereArgs: [draft.id]);
  }

  Future<void> deleteDraft(String id) async {
    await _db.delete('drafts', where: 'id = ?', whereArgs: [id]);
  }

  // ---- Favorites ----
  Future<void> insertFavorite({
    required String id,
    String? contactId,
    required String content,
    String? category,
  }) async {
    await _db.insert('favorites', {
      'id': id,
      'contact_id': contactId,
      'content': content,
      'category': category,
      'source': 'manual',
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> deleteFavorite(String id) async {
    await _db.delete('favorites', where: 'id = ?', whereArgs: [id]);
  }

  // ---- 全量清除（设置页"清除所有数据"入口）----

  /// 清空所有用户数据 - 物理删除截图 + 清空全部表。
  /// 不会关闭数据库连接，调用后应用可继续运行。
  Future<void> clearAll() async {
    // 1) 先物理删除所有截图文件（PII）
    final screenshots = await _db.query('screenshots',
        columns: ['file_path', 'thumbnail_path']);
    for (final row in screenshots) {
      await deleteScreenshotFile(row['file_path'] as String?);
      await deleteScreenshotFile(row['thumbnail_path'] as String?);
    }

    // 2) 清空所有业务表（保留 schema）
    await _db.transaction((txn) async {
      await txn.delete('chat_memories');
      await txn.delete('suggestions');
      await txn.delete('drafts');
      await txn.delete('favorites');
      await txn.delete('screenshots');
      await txn.delete('contacts');
    });
  }
}
