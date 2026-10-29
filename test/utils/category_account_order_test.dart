import 'package:flutter_test/flutter_test.dart';

import 'package:beecount/data/db.dart';
import 'package:beecount/utils/smart_account_by_category.dart';

Account _acc(int id,
        {String type = 'cash', String currency = 'CNY', bool hidden = false}) =>
    Account(
      id: id,
      ledgerId: 1,
      name: 'A$id',
      type: type,
      currency: currency,
      initialBalance: 0,
      sortOrder: 0,
      hidden: hidden,
    );

List<({int accountId, int usageCount})> usageOf(List<int> ids) => [
      for (final id in ids) (accountId: id, usageCount: 100 - id),
    ];

void main() {
  test('开关关闭直接返回空,不发起任何账户查询', () async {
    var called = false;
    Future<List<Account>> accountsByIds(List<int> ids) async {
      called = true;
      return const [];
    }

    Future<String?> currencyByAnyId(int id) async {
      called = true;
      return null;
    }

    final r = await resolveCategoryAccountOrder(
      enabled: false,
      usage: usageOf([1]),
      ledgerCurrency: 'CNY',
      isEditorInShared: false,
      accountsByIds: accountsByIds,
      currencyByAnyId: currencyByAnyId,
    );
    expect(r, isEmpty);
    expect(called, isFalse);
  });

  test('空统计返回空', () async {
    final r = await resolveCategoryAccountOrder(
      enabled: true,
      usage: const [],
      ledgerCurrency: 'CNY',
      isEditorInShared: false,
      accountsByIds: (_) async => const [],
      currencyByAnyId: (_) async => null,
    );
    expect(r, isEmpty);
  });

  test('隐藏/币种不符/估值账户跳过,由后续候选顺延(P2-1)', () async {
    final accounts = {
      1: _acc(1, hidden: true),
      2: _acc(2, currency: 'USD'),
      3: _acc(3, type: 'investment'), // 估值账户,选择器里不会出现
      4: _acc(4),
    };
    final r = await resolveCategoryAccountOrder(
      enabled: true,
      usage: usageOf([1, 2, 3, 4]),
      ledgerCurrency: 'CNY',
      isEditorInShared: false,
      accountsByIds: (ids) async => [
        for (final id in ids) if (accounts[id] != null) accounts[id]!,
      ],
      currencyByAnyId: (_) async => null,
    );
    expect(r, [4]);
  });

  test('P1-1:共享账本 Editor 视角丢弃正 id,只保留 synthetic', () async {
    var batchCalled = false;
    final r = await resolveCategoryAccountOrder(
      enabled: true,
      usage: const [
        (accountId: 5, usageCount: 9), // Editor 私人账户
        (accountId: -9, usageCount: 3), // Owner mirror synthetic
      ],
      ledgerCurrency: 'CNY',
      isEditorInShared: true,
      accountsByIds: (ids) async {
        batchCalled = true;
        return const [];
      },
      currencyByAnyId: (id) async => id < 0 ? 'CNY' : null,
    );
    expect(r, [-9]);
    expect(batchCalled, isFalse); // 正 id 全丢弃时不该发起批量查询
  });

  test('synthetic 币种不符或为空跳过', () async {
    final r = await resolveCategoryAccountOrder(
      enabled: true,
      usage: const [
        (accountId: -1, usageCount: 5),
        (accountId: -2, usageCount: 4),
        (accountId: -3, usageCount: 3),
      ],
      ledgerCurrency: 'CNY',
      isEditorInShared: true,
      accountsByIds: (_) async => const [],
      currencyByAnyId: (id) async =>
          id == -1 ? 'USD' : (id == -2 ? null : 'cny'),
    );
    expect(r, [-3]); // 大小写归一化比较
  });

  test('正 id 一次批量预取,达到 maxResults 早停', () async {
    final accounts = {for (var i = 1; i <= 15; i++) i: _acc(i)};
    final batches = <List<int>>[];
    final r = await resolveCategoryAccountOrder(
      enabled: true,
      usage: usageOf([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]),
      ledgerCurrency: 'CNY',
      isEditorInShared: false,
      accountsByIds: (ids) async {
        batches.add(ids);
        return [for (final id in ids) accounts[id]!];
      },
      currencyByAnyId: (_) async => null,
    );
    expect(r.length, 10);
    expect(r, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
    expect(batches, hasLength(1)); // 一次 IN 查询,不是逐条 PK
    expect(batches.single, hasLength(15));
  });

  test('usage 顺序决定结果顺序(仓储已按次数+最近使用排序)', () async {
    final accounts = {
      7: _acc(7),
      3: _acc(3),
      9: _acc(9),
    };
    final r = await resolveCategoryAccountOrder(
      enabled: true,
      usage: const [
        (accountId: 9, usageCount: 8),
        (accountId: 7, usageCount: 5),
        (accountId: 3, usageCount: 1),
      ],
      ledgerCurrency: 'CNY',
      isEditorInShared: false,
      accountsByIds: (ids) async => [for (final id in ids) accounts[id]!],
      currencyByAnyId: (_) async => null,
    );
    expect(r, [9, 7, 3]);
  });
}
