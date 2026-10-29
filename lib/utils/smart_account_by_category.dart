/// 按分类记忆账户 — 共享查询管线（交易编辑器 / 周期记账模板两处共用）。
///
/// 流程：开关早退 → 分类子树 / 共享账本 override 展开 → 使用统计（仓储按
/// 次数+最近使用排序）→ 逐条校验（共享视角 / 隐藏 / 币种 / 估值账户）→
/// 候选顺序。上层语义：统计第一名默认选中；统计为空时回退全局默认账户
/// （[defaultAccountForKind]）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db.dart';
import '../data/repositories/local/local_repository.dart';
import '../providers/database_providers.dart';
import '../providers/ui_state_providers.dart';
import '../services/system/logger_service.dart';
import 'account_type_utils.dart';
import 'shared_ledger_picker_filter.dart';

/// 校验使用统计并按序返回可选账户 id（顶层可注入函数，便于直接单测）。
/// [usage] 由仓储排好序，这里只做逐条过滤：
///
/// - [enabled] 为 false 直接返回空（开关关闭不发任何数据，防御性双保险）；
/// - P1-1 防御层：共享账本 Editor 视角下正 id 是 Editor 私人账户，必然不在
///   选择器候选里（那里只列 mirror synthetic 账户），整行丢弃 —— 否则会
///   「默认选中列表里没有的账户」，一键保存把交易写进私人账户并同步错位；
/// - 隐藏 / 币种不符 / 估值账户（P2-1，investment/insurance/loan 等不可记账）
///   跳过，由后续候选顺延；
/// - 正 id 走 [accountsByIds] 批量预取（P1-2：一次 IN 查询替代逐条 PK）；
///   synthetic 行走 [currencyByAnyId] 逐条查，由 [maxResults] 早停兜住次数。
Future<List<int>> resolveCategoryAccountOrder({
  required bool enabled,
  required List<({int accountId, int usageCount})> usage,
  required String ledgerCurrency,
  required bool isEditorInShared,
  required Future<List<Account>> Function(List<int> accountIds) accountsByIds,
  required Future<String?> Function(int accountId) currencyByAnyId,
  int maxResults = 10,
}) async {
  if (!enabled || usage.isEmpty) return const [];
  final wanted = ledgerCurrency.toUpperCase();

  final positiveIds = [
    for (final e in usage)
      if (e.accountId >= 0) e.accountId,
  ];
  final accountsById = <int, Account>{};
  if (positiveIds.isNotEmpty && !isEditorInShared) {
    for (final a in await accountsByIds(positiveIds)) {
      accountsById[a.id] = a;
    }
  }

  final ordered = <int>[];
  for (final entry in usage) {
    if (ordered.length >= maxResults) break;
    if (entry.accountId >= 0) {
      if (isEditorInShared) continue;
      final account = accountsById[entry.accountId];
      if (account == null || account.hidden) continue;
      if (!isTradableType(account.type)) continue;
      if (account.currency.toUpperCase() != wanted) continue;
    } else {
      final currency = await currencyByAnyId(entry.accountId);
      // 归一化比较，与正 id 分支口径一致（仓储实现已 toUpperCase，此处防御）
      if (currency == null || currency.toUpperCase() != wanted) continue;
    }
    ordered.add(entry.accountId);
  }
  return ordered;
}

/// 按分类推导账户候选顺序（读开关 → 展开分类 → 查统计 → 校验）。
/// 返回空 = 无候选，调用方回退全局默认。
/// [currencyWanted] 传调用方的生效币种（模板币种 / 记账币种）；不传按账本本位币。
Future<List<int>> categoryAccountOrderForPicker({
  required WidgetRef ref,
  required int ledgerId,
  required Category category,
  String? currencyWanted,
}) async {
  try {
    final enabled =
        await ref.read(smartAccountByCategoryEnabledProvider.future);
    if (!enabled) return const [];
    final repo = ref.read(repositoryProvider);

    // picker 上下文读一次：合成分类反查子树 + P1-1 防御层判断共用
    final pickerCtx = repo is LocalRepository
        ? await repo.db.loadLedgerPickerContext(ledgerId)
        : null;

    final categoryIds = <int>[];
    final categorySyncIds = <String>[];
    if (category.id >= 0) {
      categoryIds.add(category.id);
      if (category.level == 1) {
        final subs = await repo.getSubCategories(category.id);
        categoryIds.addAll(subs.map((s) => s.id));
      }
    } else if ((category.syncId ?? '').isNotEmpty) {
      categorySyncIds.add(category.syncId!);
      if (category.level == 1 && repo is LocalRepository) {
        final ledgerSyncId = pickerCtx?.ledgerSyncId;
        if (ledgerSyncId != null) {
          final subs = await repo.db
              .getSharedSubCategoriesBySyntheticParentId(category.id, ledgerSyncId);
          categorySyncIds.addAll(
              subs.map((s) => s.syncId ?? '').where((s) => s.isNotEmpty));
        }
      }
    }
    if (categoryIds.isEmpty && categorySyncIds.isEmpty) return const [];

    final usage = await repo.getCategoryAccountUsage(
      ledgerId: ledgerId,
      categoryIds: categoryIds,
      categorySyncIds: categorySyncIds,
    );
    if (usage.isEmpty) return const [];

    final ledger = await ref.read(ledgerByIdProvider(ledgerId).future);
    if (ledger == null) return const [];

    return await resolveCategoryAccountOrder(
      enabled: enabled,
      usage: usage,
      ledgerCurrency: currencyWanted ?? ledger.currency,
      isEditorInShared: pickerCtx?.isEditorInShared ?? false,
      accountsByIds: repo.getAccountsByIds,
      currencyByAnyId: repo.getAccountCurrencyByAnyId,
    );
  } catch (e) {
    logger.debug('SmartAccount', '按分类记忆账户排序失败,回退全局默认: $e');
    return const [];
  }
}

/// 全局默认账户（支出/收入各一），带隐藏与币种校验（P2-7 归一化比较）。
/// 账户隐藏 #240 E3：默认账户已被隐藏时按「无默认」处理（defensive 兜底，
/// 正常路径下隐藏时已清 pref，这里防同步竞态等边缘情况）。
Future<int?> defaultAccountForKind(
  WidgetRef ref,
  String kind,
  int ledgerId, {
  String? currencyWanted,
}) async {
  try {
    final defaultAccountId = kind == 'income'
        ? await ref.read(defaultIncomeAccountIdProvider.future)
        : await ref.read(defaultExpenseAccountIdProvider.future);
    if (defaultAccountId == null) return null;

    final ledger = await ref.read(ledgerByIdProvider(ledgerId).future);
    if (ledger == null) return null;

    final account = await ref.read(accountByIdProvider(defaultAccountId).future);
    if (account == null) return null;
    if (account.hidden) return null;

    final wanted = (currencyWanted ?? ledger.currency).toUpperCase();
    if (account.currency.toUpperCase() != wanted) return null;

    return defaultAccountId;
  } catch (e) {
    return null;
  }
}
