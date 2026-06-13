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
      version: 2,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
      onConfigure: _onConfigure,
    );
  }

  Future<void> _onConfigure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
  }

  /// V1→V2 迁移：补 V2 字段（场景/画像/方向/耗时）
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // screenshots 表加 V2 字段
      await db.execute('ALTER TABLE screenshots ADD COLUMN scene TEXT');
      await db
          .execute('ALTER TABLE screenshots ADD COLUMN scene_description TEXT');
      await db
          .execute('ALTER TABLE screenshots ADD COLUMN contact_insight TEXT');
      await db.execute('ALTER TABLE screenshots ADD COLUMN direction TEXT');
      await db
          .execute('ALTER TABLE screenshots ADD COLUMN duration_ms INTEGER');
      // contacts 表加 V2 字段
      await db.execute('ALTER TABLE contacts ADD COLUMN latest_insight TEXT');
      await db.execute(
          'ALTER TABLE contacts ADD COLUMN insight_updated_at INTEGER');
    }
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
        last_active_at INTEGER,
        latest_insight TEXT,
        insight_updated_at INTEGER
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
    // V2：用于"最近 N 条"快速查询（增量去重 + 全量历史加载）
    await db.execute(
        'CREATE INDEX idx_memories_recent ON chat_memories(contact_id, is_deleted, created_at)');

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
        scene TEXT,
        scene_description TEXT,
        contact_insight TEXT,
        direction TEXT,
        duration_ms INTEGER,
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
    final results = await _db.query('contacts', orderBy: 'last_active_at DESC');
    return results.map((e) => Contact.fromMap(e)).toList();
  }

  Future<Contact?> getContact(String id) async {
    final results =
        await _db.query('contacts', where: 'id = ?', whereArgs: [id]);
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
    await _db.update(
        'contacts', {'last_active_at': DateTime.now().millisecondsSinceEpoch},
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

  /// V2：获取最近 N 条记忆（按 created_at 降序），用于增量去重基准
  Future<List<ChatMemory>> getRecentMemories(String contactId,
      {int limit = 6}) async {
    final results = await _db.query(
      'chat_memories',
      where: 'contact_id = ? AND is_deleted = 0',
      whereArgs: [contactId],
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return results.map((e) => ChatMemory.fromMap(e)).toList();
  }

  /// V2：获取全量历史（按 created_at 升序），用于建议生成时的头尾保留
  ///
  /// PRD v2.2 硬上限策略：取前 20 条（早期对话建立人物关系）+ 最近 200 条（近期上下文），
  /// 总上限 220 条，防止 token 爆炸。
  Future<List<ChatMemory>> getAllMemories(String contactId) async {
    // 头尾保留：前 N_HEAD 条 + 最近 N_TAIL 条
    const nHead = 20;
    const nTail = 200;

    final headRows = await _db.query(
      'chat_memories',
      where: 'contact_id = ? AND is_deleted = 0',
      whereArgs: [contactId],
      orderBy: 'created_at ASC',
      limit: nHead,
    );

    final tailRows = await _db.query(
      'chat_memories',
      where: 'contact_id = ? AND is_deleted = 0',
      whereArgs: [contactId],
      orderBy: 'created_at DESC',
      limit: nTail,
    );

    // 合并：head 按时间正序 + tail 反转后接在后面（去重中间重叠部分）
    final headIds = <String>{};
    for (final r in headRows) {
      headIds.add(r['id'] as String);
    }
    final result = [...headRows];
    // tail 是 DESC 取的，需要反转回 ASC 顺序，同时跳过已在 head 中的
    for (final r in tailRows.reversed) {
      if (!headIds.contains(r['id'] as String)) {
        result.add(r);
      }
    }

    return result.map((e) => ChatMemory.fromMap(e)).toList();
  }

  /// V2：更新联系人画像（覆盖式）
  Future<void> updateContactInsight(String contactId, String insight) async {
    await _db.update(
      'contacts',
      {
        'latest_insight': insight,
        'insight_updated_at': DateTime.now().millisecondsSinceEpoch,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [contactId],
    );
  }

  /// V2：幂等插入消息（按 contact_id + speaker + content + timestamp_estimate 去重）
  ///
  /// 同样的消息可能在两次调用中都被识别出来；通过唯一索引 UNIQUE
  /// (contact_id, speaker, content, timestamp_estimate) 避免重复。
  /// 这里用"先查后插"软实现，零迁移成本。
  /// 批量增量插入记忆（幂等去重）
  ///
  /// 优化版：先 1 次 SELECT 查出所有重复，剩余非重复项 1 次 batch INSERT，
  /// 整体从 O(N) 次 RTT 降到 O(1) 次 RTT。
  ///
  /// 冲突处理：`ConflictAlgorithm.replace` 配合 try/catch 兜底极端并发场景。
  Future<List<ChatMemory>> insertMemoriesDedupe(
      List<ChatMemory> candidates) async {
    if (candidates.isEmpty) return const [];
    if (candidates.length == 1) {
      // 单条退化走单条路径，保持语义一致
      return _insertOneWithDedup(candidates.first);
    }

    // 1) 一次性查重：对所有 (speaker, content[, ts]) 组合做并集查询
    final withTs =
        candidates.where((m) => m.timestampEstimate != null).toList();
    final withoutTs =
        candidates.where((m) => m.timestampEstimate == null).toList();

    final existingKeys = <String>{};

    Future<void> queryKeys(List<ChatMemory> group, bool withTsFilter) async {
      if (group.isEmpty) return;
      // 用 IN 子句做单次查询
      final placeholders = List.filled(group.length, '?').join(',');
      final contactIds = {for (final m in group) m.contactId}.toList();
      final speakers = {for (final m in group) m.speaker}.toList();
      final contents = [for (final m in group) m.content];

      final where = StringBuffer(
          'contact_id IN ($placeholders) AND speaker IN ($placeholders) '
          'AND content IN ($placeholders) AND is_deleted = 0');
      final args = <Object?>[];
      args.addAll(contactIds);
      args.addAll(speakers);
      args.addAll(contents);

      if (withTsFilter) {
        final tsValues = group
            .map((m) => m.timestampEstimate!.millisecondsSinceEpoch)
            .toSet()
            .toList();
        final tsPlaceholders = List.filled(tsValues.length, '?').join(',');
        where.write(' AND timestamp_estimate IN ($tsPlaceholders)');
        args.addAll(tsValues);
      }

      final rows = await _db.query('chat_memories',
          columns: ['contact_id', 'speaker', 'content', 'timestamp_estimate'],
          where: where.toString(),
          whereArgs: args);

      for (final row in rows) {
        final key = _dedupKey(
          contactId: row['contact_id'] as String,
          speaker: row['speaker'] as String,
          content: row['content'] as String,
          tsMs: row['timestamp_estimate'] as int?,
        );
        existingKeys.add(key);
      }
    }

    await queryKeys(withTs, true);
    await queryKeys(withoutTs, false);

    // 2) 过滤出非重复的，做 batch INSERT
    final toInsert = <ChatMemory>[];
    for (final m in candidates) {
      final key = _dedupKey(
        contactId: m.contactId,
        speaker: m.speaker,
        content: m.content,
        tsMs: m.timestampEstimate?.millisecondsSinceEpoch,
      );
      if (!existingKeys.contains(key)) {
        toInsert.add(m);
      }
    }

    if (toInsert.isEmpty) return const [];

    // 3) 单次 batch insert
    final batch = _db.batch();
    for (final m in toInsert) {
      batch.insert('chat_memories', m.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    try {
      await batch.commit(noResult: true);
    } catch (_) {
      // 极端并发：极端情况下 batch 中某条冲突，回退到逐条 try/catch
      final fallback = <ChatMemory>[];
      for (final m in toInsert) {
        try {
          await _db.insert('chat_memories', m.toMap(),
              conflictAlgorithm: ConflictAlgorithm.replace);
          fallback.add(m);
        } catch (_) {}
      }
      return fallback;
    }
    return toInsert;
  }

  /// 单条去重插入的内部实现（被批量路径复用，避免重复代码）
  Future<List<ChatMemory>> _insertOneWithDedup(ChatMemory m) async {
    final where = StringBuffer(
        'contact_id = ? AND speaker = ? AND content = ? AND is_deleted = 0');
    final args = <Object?>[m.contactId, m.speaker, m.content];
    if (m.timestampEstimate != null) {
      where.write(' AND timestamp_estimate = ?');
      args.add(m.timestampEstimate!.millisecondsSinceEpoch);
    }
    final existing = await _db.query('chat_memories',
        where: where.toString(), whereArgs: args, limit: 1);
    if (existing.isNotEmpty) return const [];
    try {
      await _db.insert('chat_memories', m.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace);
      return [m];
    } catch (_) {
      return const [];
    }
  }

  /// 计算"去重 key"：归一化空白后拼 (contact, speaker, content[, ts])
  String _dedupKey({
    required String contactId,
    required String speaker,
    required String content,
    int? tsMs,
  }) {
    final c = content.replaceAll(RegExp(r'\s+'), ' ').trim();
    return tsMs == null
        ? '$contactId|$speaker|$c|'
        : '$contactId|$speaker|$c|$tsMs';
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
    final rows = await _db.query('chat_memories',
        columns: ['screenshot_id'], where: 'id = ?', whereArgs: [id]);
    final screenshotId =
        rows.isNotEmpty ? rows.first['screenshot_id'] as String? : null;

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
          await _db.delete('screenshots',
              where: 'id = ?', whereArgs: [screenshotId]);
        }
      }
    }
  }

  /// 物理级清理某个联系人的全部截图文件
  Future<void> cleanupContactScreenshots(String contactId) async {
    final rows = await _db.query('screenshots',
        columns: ['file_path', 'thumbnail_path'],
        where: 'contact_id = ?',
        whereArgs: [contactId]);
    for (final row in rows) {
      await deleteScreenshotFile(row['file_path'] as String?);
      await deleteScreenshotFile(row['thumbnail_path'] as String?);
    }
    await _db
        .delete('screenshots', where: 'contact_id = ?', whereArgs: [contactId]);
  }

  /// 清理过期截图文件：仅保留最近 [keepCount] 张，超出部分物理删除。
  /// 按创建时间倒序排列，删除最旧的记录及其磁盘文件。
  Future<int> cleanupOldScreenshots({int keepCount = 50}) async {
    // 仅查询需删除的行（按 created_at 升序，跳过最新的 keepCount 条）
    // 避免全量加载所有截图到内存
    final toDelete = await _db.query(
      'screenshots',
      columns: ['id', 'file_path', 'thumbnail_path'],
      orderBy: 'created_at ASC',
    );
    if (toDelete.length <= keepCount) return 0;

    // 只保留最新的 keepCount 条，删除更旧的
    final excessRows = toDelete.sublist(0, toDelete.length - keepCount);
    var deleted = 0;
    for (final row in excessRows) {
      await deleteScreenshotFile(row['file_path'] as String?);
      await deleteScreenshotFile(row['thumbnail_path'] as String?);
      await _db.delete('screenshots', where: 'id = ?', whereArgs: [row['id']]);
      deleted++;
    }
    debugPrint('[DB] 清理过期截图: 删除 $deleted 张（保留最新 $keepCount 张）');
    return deleted;
  }

  /// 启动时恢复卡在 processing 状态的截图记录（App 被杀导致）。
  /// 将 status 从 'processing' 标记为 'error'，并设置错误信息。
  Future<int> recoverStuckProcessingRecords() async {
    final stuckRows = await _db.query(
      'screenshots',
      where: "ai1_status = 'processing'",
    );
    if (stuckRows.isEmpty) return 0;
    // 单条 SQL 批量更新所有 processing 记录（替代逐条循环）
    final count = await _db.update(
      'screenshots',
      {'ai1_status': 'error', 'ai1_error': 'App 异常中断，处理未完成'},
      where: "ai1_status = 'processing'",
    );
    debugPrint('[DB] 恢复卡住的记录: $count 条 processing → error');
    return count;
  }

  /// 查询某截图下已存在的建议内容集合（用于批量查重）
  Future<Set<String>> getExistingSuggestionContents(
    String screenshotId,
    List<String> contents,
  ) async {
    if (contents.isEmpty) return <String>{};
    final placeholders = List.filled(contents.length, '?').join(',');
    final rows = await _db.query(
      'suggestions',
      columns: ['content'],
      where: 'screenshot_id = ? AND content IN ($placeholders)',
      whereArgs: [screenshotId, ...contents],
    );
    return rows.map((r) => r['content'] as String).toSet();
  }

  // ---- Suggestion ----

  /// 批量插入建议（单次 batch.commit，1 次 RTT）
  Future<void> insertSuggestionsBatch(List<Suggestion> suggestions) async {
    if (suggestions.isEmpty) return;
    final batch = _db.batch();
    for (final s in suggestions) {
      batch.insert('suggestions', s.toMap());
    }
    await batch.commit(noResult: true);
  }

  Future<void> updateSuggestion(Suggestion suggestion) async {
    await _db.update('suggestions', suggestion.toMap(),
        where: 'id = ?', whereArgs: [suggestion.id]);
  }

  // ---- Draft ----

  Future<List<Draft>> getDrafts() async {
    final results = await _db.query('drafts', orderBy: 'updated_at DESC');
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
    final screenshots = await _db
        .query('screenshots', columns: ['file_path', 'thumbnail_path']);
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
