# 按分类记忆账户 — 多代理攻击性审查问题清单

> 审查日期：2026-10-29
> 审查对象：`feat(accounts): 按分类记忆账户` 全部改动（db 迁移 / 仓储 / provider / 编辑页 / 选择器 / l10n / 测试）
> 审查方式：4 个独立审查代理（数据层与迁移、Dart/Riverpod 实现、业务流程与共享账本、测试/i18n/性能），只读攻击性审查，每条结论要求 file:line 证据；其中 2 条性能/确定性论断经本机 SQLite EXPLAIN 实证。
> 结论：**未发现 P0；4 组 P1 建议修复后再进上游主干；P2 为加固项不阻塞**。本文档随功能分支一并提交，修复时按条勾销。
>
> **修复记录（2026-10-29）**：P1-1 防御层、P1-2（Future.wait 并行 + `getAccountsByIds`
> 批量预取 + maxResults=10 早停，抽为顶层 `resolveCategoryAccountOrder`）、P1-3
> （新增 `test/utils/category_account_order_test.dart` 单测 7 例 +
> `test/widgets/account_selector_usage_order_test.dart` 组件测试 2 例 +
> 仓储并列排序 1 例）、P1-4（AI 入口改走 `TransactionEditUtils.editTransaction`）
> 已修复；P2-1～P2-8 已修复（P2-3 按「调用方只传其一」注释方案），P2-9～P2-12 未动。
> 全量 `flutter test`（Flutter 3.27.3）1029+ 过，仅 2 个与本次改动无关的存量失败
> （attachment_preview 的 Windows 临时文件锁、ai_provider_factory 的 SSE 30s 超时），
> 已在干净 HEAD worktree 上复现排除。
>
> **修复记录补充（2026-10-30）**：P2-9～P2-12 已全部清账 ——
> - P2-9：仓储补 3 例（limit 0/负 clamp、多账本隔离、双列表 OR 语义）；
> - P2-10：周期记账模板接入智能默认。管线从编辑器抽到
>   `lib/utils/smart_account_by_category.dart`（`categoryAccountOrderForPicker`
>   + `defaultAccountForKind` + `resolveCategoryAccountOrder`），编辑器与模板
>   共用同一份；转账模板不代填（与编辑器「转账不受影响」语义一致）；
> - P2-11：命名统一为 `usageOrderAccountIds`（AmountEditorSheet 参数 / 编辑器
>   局部变量），provider 块补节注释，`_getSortedAccounts` 过期注释修正；
> - P2-12：开关 prefs 未加载完不渲染该行，消除 ON→OFF 闪跳。
> 至此 P1×4 + P2×12 全部闭环。

## P1 — 建议修复后再合入

### P1-1 共享账本 Editor 视角：sync 名字回退污染统计，默认选中「选择器里不存在」的账户，保存写入 Editor 私人账户

- 位置：`lib/cloud/sync/sync_engine_apply.dart:144-148`（既有）→ `local_transaction_repository.dart:917-933` → `transaction_editor_page.dart:299-304`
- 机理：Owner 记的交易同步到 Editor 设备时，账户解析顺序是 syncId 查主表 → **按名字查 Editor 自己账户**（`sync_engine_resolvers.dart:80-90`，同名「现金/微信」极常见命中）→ 落 Editor 本地正 id、override 为 null。这些污染行进入统计后通过全部校验成为 usage 第一名；但 Editor+共享账本的选择器只显示 mirror synthetic 账户（`account_selector.dart:90-93`），正 id 不在列表 → 无 chip 高亮。用户直接点完成：`addTransaction(accountId: 正id)`，push 序列化把 Editor 私人账户 syncId 发给 server，错位传染全员。
- 定性：name fallback 是既有 sync 缺陷，本功能把它从显示层小错放大成「默认选中 + 一键写错归属」。
- 建议：① 防御层（本功能内，小改动）：`_getCategoryAccountOrder` 检测 `ctx.isEditorInShared` 时丢弃 `entry.accountId >= 0` 的 usage 行——该视角下正 id 账户必然不可选；② 根因（单独修 sync）：apply 的 isShared 场景把 mirror 查找提到 name fallback 之前。

### P1-2 选分类 → 面板打开的查询链串行 N+1，全部阻塞面板弹出

- 位置：`transaction_editor_page.dart:329-331` + `:298-311`
- 机理：两个独立 await 串行（统计 + 全局默认）；统计校验对 usage（上限 50）**逐条** `getAccount` PK 查询；synthetic 条目走 `findAccountBySyntheticId` = 镜像表全表加载 + 线性扫。`showModalBottomSheet` 在全部查询完成后才执行——设计文档 §4.4「耗时被面板动画掩盖」不成立（动画还没开始）。重度用户最坏估算 50~300ms，发生在每一次选分类。
- 建议：1) 两 await 改 `Future.wait` 并行（一行）；2) 正 id 批量校验用既有 `getAccountsByIds`（`local_repository.dart:2160`）替代 N 次 `getAccount`；3) 校验循环收集满前 ~10 个有效账户即早停。

### P1-3 测试欠账：核心校验逻辑零覆盖、组件级零覆盖、开关关闭无回归

- 位置：`test/`（现状只有仓储 SQL 6 例 + 排序纯函数 6 例）
- 缺口：`_getCategoryAccountOrder`/`_onCategorySelected` 的全部分支（开关关闭早退 `:261`、一级子树展开 vs 二级仅自身、synthetic 子分类反查、隐藏/币种/tradable 跳过、全不合规回退全局默认 `:332-333`、全局默认追加排序末位 `:336-339`）无任何测试；无任何测试 pump `AccountSelector` 断言 chip 顺序与选中态；「关闭→不查 SQL」无回归锁定。
- 建议：把 `:298-311` 校验循环抽成可注入查找函数的顶层函数直接单测（参照 `sortAccountsForSelector` 已有做法）；补一个 pumpWidget 测试断言 chip 文本顺序；随抽取一并测 `enabled=false` 返回空。

### P1-4（既有缺陷，本功能外，审查中发现）AI 聊天编辑入口未做 override→synthetic 映射

- 位置：`lib/pages/ai/ai_chat_page.dart:1166-1176`
- 机理：直接传 `initialCategoryId/initialAccountId` 原始值；共享账本交易两者均为 null（真实引用在 `*SyncIdOverride`）→ 面板不自动开、显示「无账户」，保存时 `updateTransaction` 无条件清空 override → **编辑即静默丢失原账户**并同步。主入口 `transaction_edit_utils.dart:117-125` 已处理映射，AI 入口没走。
- 建议：AI 入口复用 `TransactionEditUtils.editTransaction` 或同样按 override 转 `syntheticIdForSyncId`。非本功能引入，可单独提交修复。

## P2 — 加固项（不阻塞）

| # | 问题 | 位置 | 说明与建议 |
|---|---|---|---|
| P2-1 | 校验缺 `isTradableType`，usage 榜首可为估值账户（不可见默认选中） | `transaction_editor_page.dart:299-311` | 选择器过滤 `isTradableType`（`account_selector.dart:98-101`，排除 investment/insurance/loan 等），校验只查存在/隐藏/币种。历史数据挂估值账户时「选中但列表没有」。修法：校验循环补一行 `isTradableType(account.type)`（三个代理独立发现）。设计文档 §2.2 校验清单同样漏列 |
| P2-2 | 全并列时排序不定，默认账户可在会话间翻转 | `local_transaction_repository.dart:927` | 次数与 `MAX(happened_at)`（秒级）都相同时无最终 tiebreaker（已实测复现）。修法：追加 `account_id DESC, account_sync_id_override DESC` 第三键 |
| P2-3 | OR 形态下两条新索引退化为 ledger 前缀扫描 | `local_transaction_repository.dart:923-925` | EXPLAIN 实证：两列表同传时 `SEARCH ... (ledger_id=?)` 扫全账本；单列表（当前唯一调用方形态）完整命中复合索引，今天无损害。修法：双非空拆两条查询 Dart 层合并，或 UNION ALL，或注释声明「调用方只传其一」 |
| P2-4 | `GROUP BY` 互斥不变量无 DB 层保障，结果可能含重复 accountId | `local_transaction_repository.dart:926` | 当前三条写路径保证 `account_id`/`account_sync_id_override` 互斥（editor `:388-392`、sync apply `:150`），现状无误；未来调用方双写或 `syntheticIdForSyncId` 哈希冲突（2^-32）会产生重复条目，调用方 `ordered` 不去重。修法：`GROUP BY COALESCE(account_sync_id_override, '#' \|\| account_id)` 或 Dart 侧按 accountId 去重 |
| P2-5 | await 后无 `mounted` 检查（存量模式，本次加宽窗口） | `transaction_editor_page.dart:330-343` | 查询链变长，等待期 pop 页面后 `showModalBottomSheet` 用已卸载 context。修法：`:341` 后加 `if (!mounted) return;` |
| P2-6 | `catch (_)` 全吞无日志 | `transaction_editor_page.dart:313-315` | 与项目惯例一致但掩盖面大一个数量级。修法：`logger.debug('SmartAccount', ...)` 一行 |
| P2-7 | `_getDefaultAccountId` 币种比较未归一化（存量） | `transaction_editor_page.dart:249` | `!=` 区分大小写 vs 新代码两侧 `toUpperCase()`，库里确实可能大小写混存。两条默认逻辑口径不一致，建议顺手对齐 |
| P2-8 | 设计文档与实现漂移 | `docs/design/smart-account-by-category.md` §4.1/§4.4 | §4.1 草图签名（单值 categoryId + currency 下推 SQL）未按实现更新——currency 过滤移到了页面层，正是 P1-2 N+1 的来源；§4.4「与默认账户查询同时发生 / 被动画掩盖」与串行实现不符 |
| P2-9 | 仓储测试次级缺口 | `test/repositories/category_account_usage_test.dart` | 缺：clamp 边界（limit 0/负）、多账本隔离（`ledger_id = ?` 守卫）、双列表 OR 路径（当前生产互斥，属潜伏路径） |
| P2-10 | 周期交易编辑页未接入智能默认 | `recurring_transaction_edit_page.dart:384-409` | 设计缺口（模板低频配置，收益小），后续版本可补 |
| P2-11 | 命名三层漂移 + 两处小卫生 | `amount_editor_sheet.dart:213` / `account_selector.dart:21,265` / `ui_state_providers.dart:410` / `account_selector.dart:135` | `accountUsageOrder`→`usageOrderAccountIds`→`usageOrder` 建议统一；新 provider 块缺节注释；`_getSortedAccounts` 注释仍是「根据 LRU 排序」 |
| P2-12 | 开关首开 ON→OFF 闪跳 | `accounts_page.dart:1275-1279` | prefs 未加载完显示 `?? true`，与弹窗内既有开关模式一致，纯外观可不做 |

## 已核实无问题（四代理交叉确认）

- **SQL 安全与正确性**：占位符拼接无注入面，顺序与变量严格对应；BigInt/num 双兼容；`MAX(happened_at)` 全库统一 INTEGER 秒级时间戳，同列类型一致；limit clamp 边界正确。
- **迁移**：onUpgrade/onCreate 两侧 DDL 逐字相同且幂等，中途被杀重跑安全；降级（v34 库被 v33 代码打开）为静默 no-op + 版本号回写，仅加索引无表结构变更是降级最友好形态；全测试目录仅一处版本断言已同步。
- **性能现实规模**：单列表形态完整命中复合索引，10 万行账本扫描量为子树行数（千级）+ 小 GROUP BY；SQLite 变量上限（捆绑 ≥3.45，32766）不构成风险（两级分类最大扇出 9）。
- **入口矩阵**（6 处构造点逐一核验）：中央按钮/日历/小组件深链走智能默认 ✓；编辑/复制（含 mirror 缺失校验）跳过并钉住原账户 ✓；账户详情仅转账不适用 ✓；kind 传递与 tab 切换正确 ✓。
- **共享账本正常路径**：Editor 自记交易写 override → 统计映射 synthetic ✓；Owner 视角全正 id ✓；镜像未同步完成时降级安全（仅父级统计/跳过该行），pull 后自愈 ✓；哈希冲突在 SQL 分组维度不重复计数 ✓。
- **业务语义**：优先级（统计 > 全局默认，默认账户只追加排序不抢选中）、开关关闭完全不发 SQL、外币/隐藏/已删账户逐个顺延、连续记账后统计含刚记那笔、隐式默认不污染 LRU、「无账户」chip 恒在第 0 位、转账不受影响——全部符合设计。
- **i18n**：四语言两条 key 齐全、用词与各语言既有词汇表一致；生成文件（含 zh/zh_TW 两个 class）与 arb 逐字一致；新增代码无硬编码用户可见文案。
- **Riverpod/Widget**：新 provider 与同文件 12 个既有 provider 逐行同构；开关反馈回路正确无闪烁；AmountEditorSheet 每次新建实例不存在 usageOrder 失效路径；排序纯函数去重/排除双保险；`const []` 默认值无 aliasing 风险。
- **提交卫生**：无构建产物/临时文件混入。

## 修复顺序建议

1. P1-1 防御层（十几行）+ P2-1（一行）——两者同属「不可见默认选中」类，一起修一起测；
2. P1-2（Future.wait + 批量校验 + 早停）；
3. P1-3 抽函数补测试（顺带覆盖 P2-1/P1-1 防御层）；
4. P2-2/P2-3/P2-4 数据层加固（各一两行）；
5. P1-4 单独提交修 sync 既有缺陷；其余 P2 择机。
