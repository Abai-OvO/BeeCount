# 按分类记忆账户（智能账户排序）

> 状态：已实现（2026-10-29）
> 关联：账户默认值（`_CompactDefaultAccount`）、备注历史（`NoteHistoryService`）

## 1. 目标

记账时选完分类，账户选择器 **按该分类的历史使用次数排序**，并默认选中用得最多的账户。全局「默认支出/收入账户」降级为兜底，优先级低于分类统计结果。

核心诉求：大多数人 90% 的支出固定走一两个账户，但不同分类对应的账户不同（餐饮→微信、通勤→交通卡、房租→银行卡）。让选择器自己学，减少每次记账的点击。

## 2. 行为规格

### 2.1 排序

选择器里账户 chip 的顺序，按优先级：

1. 当前选中/初始账户（编辑态钉住，不受统计影响）
2. 本分类使用次数降序（含子分类，见 2.3）
3. 全局默认账户（若存在且尚未出现在 1、2 中）
4. 现有 LRU 顺序
5. 账户创建顺序

与现状一致：「无账户」chip 永远在第 0 位，不参与排序。

### 2.2 默认选中

新建交易（非编辑、非复制、无 `initialAccountId`）时：

```
usageTop = 该分类下使用次数最多、且通过校验（存在 / 未隐藏 / 币种 == 账本本位币）的账户
initialAccountId = usageTop ?? 全局默认账户 ?? null
```

注意币种：记账面板打开时交易币种尚未确定（跟随账户），默认按账本本位币筛选。若使用最多的账户是外币账户，不算命中，顺延到下一个本位币账户。

编辑/复制交易：`initialAccountId` 已存在，直接置顶，不查统计。

### 2.3 分类范围

| 所选分类 | 统计范围 |
|---|---|
| 一级分类 | 自身 + 全部二级子分类（子树汇总） |
| 二级分类 | 仅自身 |

交易表存的是用户实际点的那个分类 id，所以子树汇总是把「一级 + 子分类 id 列表」做 `IN (...)`。

### 2.4 统计口径

- 时间范围：**全部历史**（与「数据最多」的语义一致）。
- 只统计挂在有效分类上的交易；转账的 `category_id` 为 null，天然排除。
- 账户维度：`account_id`（普通）与 `account_sync_id_override`（共享账本 Editor 视角），见 3.2。
- 已删除/隐藏账户的历史仍计入统计，但排序时因候选集过滤而不显示，不影响结论。

### 2.5 开关

- 关闭 = 完全回退现状（全局默认 → LRU → 创建顺序），不查统计 SQL。
- 默认开启。
- 持久化：SharedPreferences `smart_account_for_category_enabled`（bool，默认 true），与 `account_feature_enabled` 同层。

## 3. 开关位置（UI）

放在 **资产页 → 右上角齿轮 → 通用设置Sheet**，紧随「默认支出账户 / 默认收入账户」两行之后。理由：这三项语义同族（记账时的账户默认值），用户在配默认账户时能顺带发现；不必在「我的」里新开一个设置入口。

```
┌──────────────────────────────────────┐
│                ────                  │
│  通用设置                             │
│ ──────────────────────────────────── │
│  使用账户                     [ ●]   │
│ ──────────────────────────────────── │
│  汇率管理                       >    │
│ ──────────────────────────────────── │
│  默认支出账户            微信钱包 >  │
│ ──────────────────────────────────── │
│  默认收入账户               不设置 > │
│ ──────────────────────────────────── │
│  按分类记忆账户               [ ●]   │  ← 新增
│  记账时优先选该分类常用的账户         │
└──────────────────────────────────────┘
```

规格：

- 控件沿用同弹窗里「使用账户」那行：`SwitchListTile(dense: true, visualDensity: compact)`，标题 14px `textPrimary`，`activeColor` 用主题色。
- 副标题 12px `textTertiary`（该弹窗现有行都没有副标题，这行信息量需要一句解释）。
- 显示条件与两个默认账户行一致（`enabled && accounts.isNotEmpty`）；账户功能关闭时整块隐藏。
- 关闭时两个默认账户行照常可用，语义不变。

i18n（四个语言文件都要加）：

| key | zh | zh_TW | en | ko |
|---|---|---|---|---|
| `smartAccountByCategoryTitle` | 按分类记忆账户 | 依分類記憶帳戶 | Remember account by category | 분류별 계정 기억 |
| `smartAccountByCategoryDesc` | 记账时优先选该分类常用的账户 | 記帳時優先選該分類常用的帳戶 | Prefer the account most used for this category | 기록 시 해당 분류에서 가장 많이 쓴 계정을 우선 선택 |

## 4. 数据与实现

### 4.1 聚合查询

新增仓储方法（镜像 `getNoteHistory` 的写法）。**实现与草图有一处偏差：SQL 不做
currency 过滤**，币种匹配移到了页面层校验循环（正 id 读账户时比、synthetic 行
用 `getAccountCurrencyByAnyId` 比）—— 交易表没有账户币种列，下推 SQL 需要额外
JOIN，收益不抵复杂度：

```dart
Future<List<CategoryAccountUsage>> getCategoryAccountUsage({
  required int ledgerId,
  List<int> categoryIds = const [],   // 正 id 分类（含子树，调用方展开）
  List<String> categorySyncIds = const [], // 共享账本 Editor：按 override 匹配
  int limit = 50,
});
```

SQL 草图：

```sql
SELECT account_id, account_sync_id_override, COUNT(*) AS usage_count,
       MAX(happened_at) AS last_used_at
FROM transactions
WHERE ledger_id = ?
  AND (category_id IN (...) OR category_sync_id_override IN (...))
  AND (account_id IS NOT NULL OR account_sync_id_override IS NOT NULL)
GROUP BY COALESCE(account_sync_id_override, '#' || account_id)
ORDER BY usage_count DESC, last_used_at DESC
LIMIT ?
```

调用方（编辑器按分类记忆）两类条件互斥、每次只传其一，完整命中
`idx_transactions_ledger_category{,_sync}` 复合索引。

### 4.2 共享账本 id 映射

Editor 视角下账户是 `syntheticIdForSyncId(syncId)` 派生的负数 id，交易落库时 `account_id` 为 null、身份存在 `account_sync_id_override`。聚合结果需映射回 picker 的 id 空间：

- `account_sync_id_override` 非空 → `syntheticIdForSyncId(...)`
- 否则 → `account_id`

### 4.3 索引

`transactions` 目前只有 `sync_id` 索引，聚合会全表扫描。加两条（schemaVersion 33 → 34，`onUpgrade` 里 `CREATE INDEX IF NOT EXISTS`）：

```sql
CREATE INDEX IF NOT EXISTS idx_transactions_ledger_category
  ON transactions(ledger_id, category_id);
CREATE INDEX IF NOT EXISTS idx_transactions_ledger_category_sync
  ON transactions(ledger_id, category_sync_id_override);
```

索引构建是一次性 O(n)，之后每次聚合只扫子树行数，几万行的账本在毫秒级。

### 4.4 缓存

不引入缓存。每次打开金额面板查一次，天然反映最新数据，无需设计失效逻辑。两条查询链（分类统计 + 全局默认账户）互不依赖，在 `_onCategorySelected` 里 `Future.wait` 并行取（P1-2 修复后），面板打开前的阻塞只剩其中最慢一条。

### 4.5 代码落点

| 文件 | 改动 |
|---|---|
| `lib/data/repositories/transaction_repository.dart` | 接口新增 `getCategoryAccountUsage` |
| `lib/data/repositories/local/local_transaction_repository.dart` | 实现（照 `getNoteHistory` 结构） |
| `lib/data/db.dart:514` | schemaVersion 34 + 两条索引 |
| `lib/providers/ui_state_providers.dart` | 开关 provider + setter |
| `lib/pages/account/accounts_page.dart:1236` | 新增开关行 |
| `lib/pages/transaction/transaction_editor_page.dart:227` | 查 usage、选默认账户（替换 `_getDefaultAccountId` 的返回） |
| `lib/widgets/biz/amount_editor_sheet.dart` | 新增 `accountUsageOrder` 参数并传给选择器 |
| `lib/widgets/biz/account_selector.dart:135` | `_getSortedAccounts` 插入 usage 层 |
| `lib/l10n/app_{zh,zh_TW,en,ko}.arb` | 新增两组文案 |

## 5. 边界

| 场景 | 行为 |
|---|---|
| 分类无历史 | 回退全局默认 → LRU → 创建顺序 |
| 使用最多的账户已删除/隐藏 | 跳过，顺延下一位 |
| 使用最多的账户币种 ≠ 账本本位币 | 跳过（用户在面板里换币种后，选择器重新按该币种过滤，但排序不变） |
| 新用户、零交易 | 等价于现状 |
| 复制交易 | 原账户置顶，不查统计 |
| 共享账本 Owner 视角 | 全部是本地正 id，走普通分支 |
| 共享账本 Editor 视角 | override 匹配 + synthetic id 映射 |
| 记账保存后 | 当前面板不重排（与 LRU 一致，下次打开生效） |

## 6. 测试

- 仓储层（内存 drift）：子树汇总、二级分类只算自身、共享账本 override、无数据返回空、limit 生效。
- 排序层（纯函数抽出后单测）：usage → 默认 → LRU → 创建顺序的合并与去重。
- Widget：`AccountSelector` chip 顺序、默认选中态。
- 回归：开关关闭时与现状逐项一致（订单验证默认账户仍置顶）。

## 7. 工作量

约 0.5–1 天（含测试与四个语言文案）。核心逻辑 150 行以内，无表结构变更，只有索引迁移。
