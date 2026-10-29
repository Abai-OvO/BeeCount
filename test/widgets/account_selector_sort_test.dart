import 'package:flutter_test/flutter_test.dart';

import 'package:beecount/data/db.dart';
import 'package:beecount/widgets/biz/account_selector.dart';

Account _acc(int id, String name) => Account(
      id: id,
      ledgerId: 1,
      name: name,
      type: 'cash',
      currency: 'CNY',
      initialBalance: 0,
      sortOrder: 0,
      hidden: false,
    );

void main() {
  final accounts = [_acc(1, 'A'), _acc(2, 'B'), _acc(3, 'C')];

  test('usage 顺序优先于 LRU 和创建顺序', () {
    final sorted = sortAccountsForSelector(
      accounts: accounts,
      usageOrder: [3, 2],
      lruOrder: [1, 3],
    );
    expect(sorted.map((a) => a.id).toList(), [3, 2, 1]);
  });

  test('初始选中账户置顶,不被 usage 重排', () {
    final sorted = sortAccountsForSelector(
      accounts: accounts,
      usageOrder: [3, 2],
      lruOrder: [],
      initialSelectedAccountId: 1,
    );
    expect(sorted.map((a) => a.id).toList(), [1, 3, 2]);
  });

  test('LRU 在 usage 之后生效', () {
    final sorted = sortAccountsForSelector(
      accounts: accounts,
      usageOrder: [3],
      lruOrder: [2, 1],
    );
    expect(sorted.map((a) => a.id).toList(), [3, 2, 1]);
  });

  test('重复 id 去重', () {
    final sorted = sortAccountsForSelector(
      accounts: accounts,
      usageOrder: [2, 2, 3],
      lruOrder: [2, 3],
    );
    expect(sorted.map((a) => a.id).toList(), [2, 3, 1]);
  });

  test('未知 id 忽略,回退创建顺序', () {
    final sorted = sortAccountsForSelector(
      accounts: accounts,
      usageOrder: [99],
      lruOrder: [],
    );
    expect(sorted.map((a) => a.id).toList(), [1, 2, 3]);
  });

  test('空列表返回空', () {
    final sorted = sortAccountsForSelector(
      accounts: [],
      usageOrder: [1],
      lruOrder: [1],
    );
    expect(sorted, isEmpty);
  });
}
