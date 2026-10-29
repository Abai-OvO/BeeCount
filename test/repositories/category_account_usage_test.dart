import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/utils/shared_ledger_picker_filter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BeeDatabase db;
  late LocalRepository repo;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
  });

  tearDown(() async => db.close());

  test('一级分类按子树汇总,按次数降序', () async {
    final lid = await repo.createLedger(name: 'L');
    final parent =
        await repo.createCategory(name: '餐饮', kind: 'expense');
    final sub = await repo.createCategory(
        name: '午餐', kind: 'expense', level: 2, parentId: parent);
    final a = await repo.createAccount(ledgerId: lid, name: '微信');
    final b = await repo.createAccount(ledgerId: lid, name: '招行');

    for (var i = 0; i < 3; i++) {
      await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 10,
        categoryId: sub,
        accountId: a,
        happenedAt: DateTime(2026, 1, 1),
      );
    }
    await repo.addTransaction(
      ledgerId: lid,
      type: 'expense',
      amount: 20,
      categoryId: parent,
      accountId: b,
      happenedAt: DateTime(2026, 1, 2),
    );

    final usage = await repo.getCategoryAccountUsage(
      ledgerId: lid,
      categoryIds: [parent, sub],
    );

    expect(usage.length, 2);
    expect(usage[0].accountId, a);
    expect(usage[0].usageCount, 3);
    expect(usage[1].accountId, b);
    expect(usage[1].usageCount, 1);
  });

  test('二级分类只统计自身', () async {
    final lid = await repo.createLedger(name: 'L');
    final parent =
        await repo.createCategory(name: '餐饮', kind: 'expense');
    final sub = await repo.createCategory(
        name: '午餐', kind: 'expense', level: 2, parentId: parent);
    final other = await repo.createCategory(
        name: '晚餐', kind: 'expense', level: 2, parentId: parent);
    final a = await repo.createAccount(ledgerId: lid, name: '微信');

    await repo.addTransaction(
      ledgerId: lid,
      type: 'expense',
      amount: 10,
      categoryId: sub,
      accountId: a,
      happenedAt: DateTime(2026, 1, 1),
    );
    await repo.addTransaction(
      ledgerId: lid,
      type: 'expense',
      amount: 10,
      categoryId: other,
      accountId: a,
      happenedAt: DateTime(2026, 1, 1),
    );

    final usage = await repo.getCategoryAccountUsage(
      ledgerId: lid,
      categoryIds: [sub],
    );

    expect(usage.length, 1);
    expect(usage[0].accountId, a);
    expect(usage[0].usageCount, 1);
  });

  test('共享账本 override 行映射为 synthetic id', () async {
    final lid = await repo.createLedger(name: 'L');
    final a = await repo.createAccount(ledgerId: lid, name: '本地');

    await repo.addTransaction(
      ledgerId: lid,
      type: 'expense',
      amount: 5,
      categorySyncIdOverride: 'cat-sync-1',
      accountSyncIdOverride: 'acc-sync-1',
      happenedAt: DateTime(2026, 1, 2),
    );
    await repo.addTransaction(
      ledgerId: lid,
      type: 'expense',
      amount: 5,
      categorySyncIdOverride: 'cat-sync-1',
      accountSyncIdOverride: 'acc-sync-1',
      happenedAt: DateTime(2026, 1, 3),
    );
    await repo.addTransaction(
      ledgerId: lid,
      type: 'expense',
      amount: 5,
      categorySyncIdOverride: 'cat-sync-1',
      accountId: a,
      happenedAt: DateTime(2026, 1, 4),
    );

    final usage = await repo.getCategoryAccountUsage(
      ledgerId: lid,
      categorySyncIds: ['cat-sync-1'],
    );

    final syntheticAcc = syntheticIdForSyncId('acc-sync-1');
    expect(usage.length, 2);
    expect(usage[0].accountId, syntheticAcc);
    expect(usage[0].usageCount, 2);
    expect(usage[1].accountId, a);
    expect(usage[1].usageCount, 1);
  });

  test('无账户的交易不计入,空过滤条件返回空', () async {
    final lid = await repo.createLedger(name: 'L');
    final cat = await repo.createCategory(name: '餐饮', kind: 'expense');

    await repo.addTransaction(
      ledgerId: lid,
      type: 'expense',
      amount: 10,
      categoryId: cat,
      happenedAt: DateTime(2026, 1, 1),
    );

    final emptyFilter = await repo.getCategoryAccountUsage(ledgerId: lid);
    expect(emptyFilter, isEmpty);

    final usage = await repo.getCategoryAccountUsage(
      ledgerId: lid,
      categoryIds: [cat],
    );
    expect(usage, isEmpty);
  });

  test('次数相同取最近使用的优先', () async {
    final lid = await repo.createLedger(name: 'L');
    final cat = await repo.createCategory(name: '餐饮', kind: 'expense');
    final a = await repo.createAccount(ledgerId: lid, name: '微信');
    final b = await repo.createAccount(ledgerId: lid, name: '招行');

    await repo.addTransaction(
      ledgerId: lid,
      type: 'expense',
      amount: 10,
      categoryId: cat,
      accountId: a,
      happenedAt: DateTime(2026, 1, 1),
    );
    await repo.addTransaction(
      ledgerId: lid,
      type: 'expense',
      amount: 10,
      categoryId: cat,
      accountId: b,
      happenedAt: DateTime(2026, 3, 1),
    );

    final usage = await repo.getCategoryAccountUsage(
      ledgerId: lid,
      categoryIds: [cat],
    );

    expect(usage.length, 2);
    expect(usage[0].accountId, b);
    expect(usage[1].accountId, a);
  });

  test('limit 截断结果', () async {
    final lid = await repo.createLedger(name: 'L');
    final cat = await repo.createCategory(name: '餐饮', kind: 'expense');
    final a = await repo.createAccount(ledgerId: lid, name: 'A');
    final b = await repo.createAccount(ledgerId: lid, name: 'B');

    for (var i = 0; i < 2; i++) {
      await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 10,
        categoryId: cat,
        accountId: a,
        happenedAt: DateTime(2026, 1, 1),
      );
      await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 10,
        categoryId: cat,
        accountId: b,
        happenedAt: DateTime(2026, 1, 1),
      );
    }

    final usage = await repo.getCategoryAccountUsage(
      ledgerId: lid,
      categoryIds: [cat],
      limit: 1,
    );
    expect(usage.length, 1);
  });

  test('次数与最近使用完全并列时,按 account_id 降序稳定排序(P2-2)', () async {
    final lid = await repo.createLedger(name: 'L');
    final cat = await repo.createCategory(name: '餐饮', kind: 'expense');
    final a = await repo.createAccount(ledgerId: lid, name: '早创建');
    final b = await repo.createAccount(ledgerId: lid, name: '晚创建');

    // 同一笔数、同一秒:此前无第三排序键,结果在会话间可翻转
    for (final acc in [a, b]) {
      await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 10,
        categoryId: cat,
        accountId: acc,
        happenedAt: DateTime(2026, 1, 1, 12, 0, 0),
      );
    }

    final usage = await repo.getCategoryAccountUsage(
      ledgerId: lid,
      categoryIds: [cat],
    );
    expect(usage.map((e) => e.accountId).toList(), [b, a]);
  });

  test('limit 0 与负数被 clamp 到 1(P2-9 边界)', () async {
    final lid = await repo.createLedger(name: 'L');
    final cat = await repo.createCategory(name: '餐饮', kind: 'expense');
    final a = await repo.createAccount(ledgerId: lid, name: 'A');
    final b = await repo.createAccount(ledgerId: lid, name: 'B');
    for (final acc in [a, b]) {
      await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 10,
        categoryId: cat,
        accountId: acc,
        happenedAt: DateTime(2026, 1, 1),
      );
    }

    for (final bad in [0, -5]) {
      final usage = await repo.getCategoryAccountUsage(
        ledgerId: lid,
        categoryIds: [cat],
        limit: bad,
      );
      expect(usage, hasLength(1), reason: 'limit=$bad');
    }
  });

  test('多账本隔离:只统计传入 ledger 的交易(P2-9)', () async {
    final lid1 = await repo.createLedger(name: 'L1');
    final lid2 = await repo.createLedger(name: 'L2');
    final cat = await repo.createCategory(name: '餐饮', kind: 'expense');
    final a1 = await repo.createAccount(ledgerId: lid1, name: 'L1微信');
    final a2 = await repo.createAccount(ledgerId: lid2, name: 'L2招行');

    await repo.addTransaction(
      ledgerId: lid1,
      type: 'expense',
      amount: 10,
      categoryId: cat,
      accountId: a1,
      happenedAt: DateTime(2026, 1, 1),
    );
    await repo.addTransaction(
      ledgerId: lid2,
      type: 'expense',
      amount: 99,
      categoryId: cat,
      accountId: a2,
      happenedAt: DateTime(2026, 1, 2),
    );

    final usage1 = await repo.getCategoryAccountUsage(
      ledgerId: lid1,
      categoryIds: [cat],
    );
    expect(usage1.map((e) => e.accountId).toList(), [a1]);
    expect(usage1.single.usageCount, 1);
  });

  test('双列表同传走 OR 语义,两类各自计入不互相污染(P2-9 潜伏路径)', () async {
    final lid = await repo.createLedger(name: 'L');
    final cat = await repo.createCategory(name: '餐饮', kind: 'expense');
    final a = await repo.createAccount(ledgerId: lid, name: '本地账户');

    // 本地路径:category_id 命中;共享路径:category_sync_id_override 命中
    await repo.addTransaction(
      ledgerId: lid,
      type: 'expense',
      amount: 10,
      categoryId: cat,
      accountId: a,
      happenedAt: DateTime(2026, 1, 1),
    );
    await repo.addTransaction(
      ledgerId: lid,
      type: 'expense',
      amount: 10,
      categorySyncIdOverride: 'cat-sync-9',
      accountSyncIdOverride: 'acc-sync-9',
      happenedAt: DateTime(2026, 1, 2),
    );

    final usage = await repo.getCategoryAccountUsage(
      ledgerId: lid,
      categoryIds: [cat],
      categorySyncIds: ['cat-sync-9'],
    );

    expect(usage, hasLength(2));
    expect(usage.map((e) => e.accountId).toSet(),
        {a, syntheticIdForSyncId('acc-sync-9')});
    expect(usage.every((e) => e.usageCount == 1), isTrue);
  });
}
