import 'package:flutter_test/flutter_test.dart';
import 'package:chat_helper/data/models/chat_memory.dart';
import 'package:chat_helper/services/vision_service.dart';

void main() {
  group('VisionService.endpointTypeFor', () {
    test('Seed 1.6 Vision 默认走 /responses', () {
      expect(
          VisionService.endpointTypeFor('doubao-seed-1-6-vision-250815'),
          'responses');
    });

    test('Seed 1.6 Flash 走 /responses', () {
      expect(VisionService.endpointTypeFor('doubao-seed-1-6-flash-250828'),
          'responses');
    });

    test('Seed 2.0 Mini 走 /responses', () {
      expect(VisionService.endpointTypeFor('doubao-seed-2-0-mini-260428'),
          'responses');
    });

    test('1.5 Vision Pro 走 /chat/completions', () {
      expect(
          VisionService.endpointTypeFor('doubao-1-5-vision-pro-32k-250115'),
          'completions');
    });

    test('自定义模型包含 seed 关键字走 /responses', () {
      expect(VisionService.endpointTypeFor('my-custom-seed-2026'), 'responses');
    });

    test('自定义模型包含 1.5 走 /chat/completions', () {
      expect(
          VisionService.endpointTypeFor('doubao-1-5-vision-lite-250115'),
          'completions');
    });

    test('自定义模型包含 vision-pro 走 /chat/completions', () {
      expect(
          VisionService.endpointTypeFor('doubao-vision-pro-finetune-1234'),
          'completions');
    });

    test('大小写不敏感', () {
      expect(
          VisionService.endpointTypeFor('DOUBAO-1-5-VISION-PRO-32K-250115'),
          'completions');
      expect(VisionService.endpointTypeFor('DOUBAO-SEED-1-6-FLASH-250828'),
          'responses');
    });

    test('未知模型默认走 /responses', () {
      expect(VisionService.endpointTypeFor('unknown-model-2026'), 'responses');
    });
  });

  group('VisionService 预设配置', () {
    test('baseUrl 指向火山引擎方舟平台', () {
      expect(VisionService.baseUrl,
          'https://ark.cn-beijing.volces.com/api/v3');
    });

    test('responsesEndpoint 等于 baseUrl + /responses', () {
      expect(VisionService.responsesEndpoint,
          'https://ark.cn-beijing.volces.com/api/v3/responses');
    });

    test('completionsEndpoint 等于 baseUrl + /chat/completions', () {
      expect(VisionService.completionsEndpoint,
          'https://ark.cn-beijing.volces.com/api/v3/chat/completions');
    });

    test('defaultModel 是 Seed 1.6 Vision', () {
      expect(VisionService.defaultModel, 'doubao-seed-1-6-vision-250815');
    });

    test('dedupMemoryCount = 6（PRD V2 §11）', () {
      expect(VisionService.dedupMemoryCount, 6);
    });

    test('presetModels 至少包含 4 个豆包模型', () {
      expect(VisionService.presetModels.length, greaterThanOrEqualTo(4));
      expect(VisionService.presetModels.keys, contains('doubao-seed-1-6-vision-250815'));
    });
  });

  group('VisionMessage.toChatMemory', () {
    test('基本转换：speaker + content 正确保留', () {
      final m = VisionMessage(
        speaker: 'partner',
        content: '你好',
        timestamp: null,
      );
      final mem = m.toChatMemory(
        id: 'm1',
        contactId: 'c1',
        screenshotId: 's1',
      );
      expect(mem.id, 'm1');
      expect(mem.contactId, 'c1');
      expect(mem.screenshotId, 's1');
      expect(mem.speaker, 'partner');
      expect(mem.content, '你好');
      expect(mem.timestampEstimate, isNull);
    });

    test('ISO8601 时间戳正确解析为 DateTime', () {
      final m = VisionMessage(
        speaker: 'me',
        content: '在吗',
        timestamp: '2026-06-05T14:30:00.000Z',
      );
      final mem = m.toChatMemory(
        id: 'm2',
        contactId: 'c1',
        screenshotId: 's1',
      );
      expect(mem.timestampEstimate, isNotNull);
      expect(mem.timestampEstimate!.toUtc(),
          DateTime.parse('2026-06-05T14:30:00.000Z'));
    });

    test('非法时间戳被忽略，timestampEstimate 保持 null', () {
      final m = VisionMessage(
        speaker: 'me',
        content: '在吗',
        timestamp: '不是有效时间',
      );
      final mem = m.toChatMemory(
        id: 'm3',
        contactId: 'c1',
        screenshotId: 's1',
      );
      expect(mem.timestampEstimate, isNull);
    });

    test('空时间戳字符串被忽略', () {
      final m = VisionMessage(speaker: 'me', content: 'x', timestamp: '');
      final mem = m.toChatMemory(
          id: 'm4', contactId: 'c1', screenshotId: 's1');
      expect(mem.timestampEstimate, isNull);
    });
  });

  group('UnifiedResult getters', () {
    test('hasError: error != null', () {
      final r = UnifiedResult(
        messages: const [],
        suggestions: const [],
        error: const VisionError(VisionErrorKind.network, 'x'),
      );
      expect(r.hasError, true);
    });

    test('hasError: error == null', () {
      final r = UnifiedResult(messages: const [], suggestions: const []);
      expect(r.hasError, false);
    });

    test('hasNewMessages / hasSuggestions', () {
      final r = UnifiedResult(
        messages: [
          VisionMessage(speaker: 'partner', content: 'x')
        ],
        suggestions: [
          UnifiedSuggestion(style: '热情', content: 'y')
        ],
      );
      expect(r.hasNewMessages, true);
      expect(r.hasSuggestions, true);
    });

    test('isAllDuplicate: 空 messages 且无 error', () {
      final r = UnifiedResult(messages: const [], suggestions: [
        UnifiedSuggestion(style: 'x', content: 'y')
      ]);
      expect(r.isAllDuplicate, true);
    });

    test('isAllDuplicate: 即使有建议，没有新增对话也算 isAllDuplicate', () {
      final r = UnifiedResult(
        messages: const [],
        suggestions: [UnifiedSuggestion(style: 'x', content: 'y')],
      );
      expect(r.isAllDuplicate, true);
    });

    test('isAllDuplicate: 有新增对话 → false', () {
      final r = UnifiedResult(
        messages: [VisionMessage(speaker: 'partner', content: 'x')],
        suggestions: const [],
      );
      expect(r.isAllDuplicate, false);
    });
  });

  group('UnifiedSuggestion.toJson', () {
    test('包含 style + content + reason', () {
      final s = UnifiedSuggestion(style: '热情', content: '好的', reason: '积极');
      final j = s.toJson();
      expect(j['style'], '热情');
      expect(j['content'], '好的');
      expect(j['reason'], '积极');
    });

    test('reason 为 null 时序列化为 null', () {
      final s = UnifiedSuggestion(style: '幽默', content: '哈哈');
      final j = s.toJson();
      expect(j.containsKey('reason'), true);
      expect(j['reason'], isNull);
    });
  });

  group('VisionError', () {
    test('toString 包含 kind 和 message', () {
      const e = VisionError(VisionErrorKind.auth, 'key 无效');
      expect(e.toString(), contains('auth'));
      expect(e.toString(), contains('key 无效'));
    });

    test('notConfigured 是 const 静态错误', () {
      expect(VisionError.notConfigured.kind, VisionErrorKind.notConfigured);
      expect(VisionError.notConfigured.message, contains('API Key'));
    });
  });

  // 注：以下为冒烟测试，验证从 ChatMemory 反向序列化的兜底逻辑在内存对象上稳定。
  group('ChatMemory 序列化/反序列化 兼容 V2 字段', () {
    test('包含 timestampEstimate 的 ChatMemory 可往返', () {
      final ts = DateTime.parse('2026-06-01T09:00:00.000Z');
      final mem = ChatMemory(
        id: 'a',
        contactId: 'c',
        screenshotId: 's',
        speaker: 'me',
        content: 'hi',
        timestampEstimate: ts,
        platform: 'wechat',
        createdAt: DateTime.now(),
      );
      final map = mem.toMap();
      expect(map['timestamp_estimate'], ts.millisecondsSinceEpoch);
      expect(map['contact_id'], 'c');
      expect(map['speaker'], 'me');
      final restored = ChatMemory.fromMap(map);
      // 序列化为毫秒戳往返，toMap() / fromMap() 不会丢失时间精度
      expect(restored.timestampEstimate, isNotNull);
      expect(
        restored.timestampEstimate!.millisecondsSinceEpoch,
        ts.millisecondsSinceEpoch,
      );
      expect(restored.contactId, 'c');
      expect(restored.speaker, 'me');
    });
  });
}
