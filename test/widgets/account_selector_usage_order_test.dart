import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/l10n/app_localizations.dart';
import 'package:beecount/providers/database_providers.dart';
import 'package:beecount/widgets/biz/account_selector.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// P1-3 组件级覆盖:usage 顺序必须真实反映为 AccountSelector 的 chip 顺序,
/// 而不只是排序纯函数层面的约定(排序函数本身已有 account_selector_sort_test)。
void main() {
  late BeeDatabase db;
  late LocalRepository repo;
  late int ledgerId;
  late List<int> usageOrder;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    ledgerId = await repo.createLedger(name: '日常');
    final wechat = await repo.createAccount(ledgerId: ledgerId, name: '微信');
    final bank = await repo.createAccount(ledgerId: ledgerId, name: '招行');
    final cat = await repo.createCategory(name: '餐饮', kind: 'expense');

    for (var i = 0; i < 3; i++) {
      await repo.addTransaction(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 10,
        categoryId: cat,
        accountId: wechat,
        happenedAt: DateTime(2026, 1, 1, 12, i),
      );
    }
    await repo.addTransaction(
      ledgerId: ledgerId,
      type: 'expense',
      amount: 10,
      categoryId: cat,
      accountId: bank,
      happenedAt: DateTime(2026, 1, 1, 12, 9),
    );

    final usage = await repo.getCategoryAccountUsage(
      ledgerId: ledgerId,
      categoryIds: [cat],
    );
    usageOrder = usage.map((e) => e.accountId).toList();
  });
  tearDown(() => db.close());

  Widget host(Widget child) => ProviderScope(
        overrides: [repositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: child),
        ),
      );

  testWidgets('统计第一名(微信)排在 chip 序列最前,招行靠后', (tester) async {
    await tester.pumpWidget(host(AccountSelector(
      selectedAccountId: null,
      onAccountSelected: (_) {},
      ledgerId: ledgerId,
      usageOrderAccountIds: usageOrder,
    )));
    await tester.pumpAndSettle();

    final wechat = tester.getRect(find.text('微信'));
    final bank = tester.getRect(find.text('招行'));
    expect(wechat.left, lessThan(bank.left));
    await tester.pumpWidget(const SizedBox());
    // 清理生产 logger 的延迟落盘任务(与 account_transfer_presentation_test 同法)
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('usage 为空时回退创建顺序,微信仍先于招行', (tester) async {
    await tester.pumpWidget(host(AccountSelector(
      selectedAccountId: null,
      onAccountSelected: (_) {},
      ledgerId: ledgerId,
    )));
    await tester.pumpAndSettle();

    final wechat = tester.getRect(find.text('微信'));
    final bank = tester.getRect(find.text('招行'));
    expect(wechat.left, lessThan(bank.left));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
}
