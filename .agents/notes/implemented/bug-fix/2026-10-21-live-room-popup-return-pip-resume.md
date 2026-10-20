# Agent Note: 直播间经榜单弹层返回时恢复直播源并处理应用内小窗

Status: implemented

## Problem

直播间 → 「高能观众」→ 榜单底部弹层 → 点进某用户主页 `/member` → 主页「番剧」→ 播放 → 逐层返回直播间。此时应用内小窗（番剧）没有关闭，且直播间主画面与小窗同时播放番剧。同样的过程若换成点击 UP 主头像或弹幕里的「进入其个人空间」（中间没有弹层），一切正常。

根因是路由观察器的类型过滤，不是小窗本身：

- 全局观察器是 `RouteObserver<GetPageRoute>`（[route_aware_mixin.dart](../../../../lib/common/widgets/route_aware_mixin.dart)）。
- Flutter 的 `RouteObserver.didPop` / `didPush` 都要求 `if (route is R && previousRoute is R)` 才派发（本地 Flutter `packages/flutter/lib/src/widgets/routes.dart` 的 `didPop` / `didPush`）。
- 榜单面板由 `showModalBottomSheet` 创建，`ModalBottomSheetRoute` 继承自 `PopupRoute`，不是 `GetPageRoute`。
- 于是路由栈 `直播间(GetPageRoute) → 榜单(PopupRoute) → /member → /videoV` 上每次 pop 都被过滤：pop `/member` 时 previousRoute 是弹层，pop 弹层时 route 本身不是 R。直播间的 `didPopNext()` 从不触发。
- 直播间的全部收尾（关视频小窗、必要时重拉直播流）都写在 `didPopNext` 里，所以小窗没人关，播放器单例（`PlPlayerController.getInstance()`）仍是番剧源，直播间用的是同一个单例，于是两处同时播番剧。

上游 `7312ca186`（`fix #3315`）绕开了这个过滤，但没有小窗概念：它靠 `PlayOwner` 判断「播放器是否已被其他页面占用」，用弹层的 `whenComplete` 补上 PopupRoute 的返回信号，命中时重拉直播流。上游在本场景的症状是「直播间主播放器变成番剧内容」，没有小窗叠加。

fork 只接上游会得到什么：播放那一半修好（主画面回到直播源），小窗这一半没修——小窗不关、内容被换成直播、盖在主画面上，`PipOverlayService.isInPipMode` 残留会让后续视频页的 `shouldKeepAlive` 判定继续为真，直到下一次能正常触发 `didPopNext` 的导航才被顺手清掉。

## Decision

修复基于 `b908eccfb`，在 `merge/upstream-7312ca186` 分支上将上游 `7312ca186` cherry-pick 为 `7f81aaff9`，随后单独实现 fork 的小窗恢复。其余 16 个上游提交与后续合并留待另行处理。

### 保留上游的部分

`PlayOwner` 的 `type` 改为可空（直播间用 `(tag: heroTag, type: null)` 作身份）；直播间新增 `_playOwner` getter、把裸的 `setPlayCallBack` 收敛为 `_setPlayCallBack()`；`didPopNext` 拆成 wrapper + `_onPopNext`；`_showRank` 里 `_onPushPopupRoute()` 与 `.whenComplete(...)`。

`_onPopPopupRoute` 与 `didPopNext` 都请求统一的返回处理。owner 比较位于 `_prepareLiveRoomResume()`，仅非空的外部 owner 才成为重建信号；`owner == null` 可能表示没人登记或清理时 callback 被清空，不能单独证明播放器被占用，实际播放源失配仍会触发恢复。

### fork 增加的部分

**统一返回入口与一次返回只处理一次。** 弹层是 PopupRoute，同一层返回可能同时产生两个信号；改用「返回编号」而不是布尔忙碌标志：`_beginLiveRoomLeave()` 在首次离开时递增 `_liveResumeEpoch` 并快照播放意图；两个入口都调 `_requestLiveRoomResume(epoch)`；`_liveResumeHandledEpoch` 记下已处理编号且完成后不复位，所以「第一个信号已结束、第二个迟到」同样被拦下，只有下一次离开产生的新编号才允许再次恢复。`_showRank` 捕获打开时的编号传给 `whenComplete`，避免迟到回调读到属于下一次导航的编号。

**顺序：先关小窗，再恢复播放。** 小窗关闭回调会 `setPlayCallBack(null)`，视频页 `_handleInAppPipCloseCleanup()` 在页面已 dispose 时还会对共享单例调 `dispose()`。若先登记直播 owner 再关小窗，刚登记的 callback 会被清掉。所以顺序固定为：保存 owner 与播放意图 → 关视频小窗 → 处理直播小窗 → 刷新播放器引用 → 判定是否重建 → 最后 `_setPlayCallBack()` 并重挂监听。

**小窗处理独立成方法**，不塞进 `_onPopNext`。上游的 owner 判据表达不了小窗状态：同房间直播小窗归位时 owner 可能仍属于本页，但仍需走归位动画与 attach；owner 为 null 时小窗也可能还开着。判别按「小窗房间号 + 实际播放源是否有效」二分：同房间且源有效 → 走原有 `transition.beginRestore()` 归位握手（非销毁式）；否则关闭。失配的直播小窗如果保存的正是当前 `_liveRoomController`，用 `callOnClose: false`，避免 `_handleLivePipCloseCleanup()` 把仍在显示的 controller 清掉。

**`needsRecovery` 以实际播放源为主判据**，`identical(player, PlPlayerController.instance)`、`videoPlayerController != null`、`isLive`、`roomId` 匹配、`cid == null`、`dataStatus == DataStatus.loaded` 全成立才算源就是本直播间；owner 只作为补充信号，且仅在「同房间小窗归位复用」不成立时计入。

**`isReturningFromPip` 的无条件早返回要拆掉**：它证明不了当前源仍属于直播间，会让失配源跳过恢复。改为源有效时跳过 `playerInit` 但保留该标志给原有的元数据加载路径；源失配时清为 false 再重拉。

**`playerInit` 按实例身份重新取得引用**：仅在 `!identical(plPlayerController, PlPlayerController.instance)` 时调用 `getInstance()`，为直播 controller 在新单例上保留一次引用。完整 `dispose()` 会清空 `_instance`；仅减少引用计数的分支不会清空。同一单例仅缺少内部播放器时不重复增加引用，由 `setDataSource()` 内的 `_createVideoController()` 初始化。返回入口的实际源判定仍检查 `videoPlayerController != null`。

**`late final plPlayerController` 改 `late`**：该字段在现有代码里已有两处重新赋值，`late final` 第二次赋值会抛 `LateInitializationError`。这是既有潜在缺陷，不是本方案引入的行为变化。

**`_findIntroController` 明确无 intro 的查询结果**：owner 为 null 或 `type == null` 时在入口返回 null，未知非空类型仍保持 debug 抛错。全仓查询确认该函数只有 `skipToNext` / `skipToPrevious` 两个调用点；两个媒体操作入口都在自定义 callback 前识别直播 owner 并直接返回，防止残留 callback 或 tag 驱动旧视频切集。

### 已知不修

`didPushNext` 同样被类型过滤，弹层之上进入主页/番剧期间直播间弹幕流与计时器不停。两个返回信号都识别不到「在弹层之上 push」的时刻，本变更不声称修复离场资源暂停。

## Alternatives considered

- **把全部小窗逻辑塞进 `_onPopNext`** — 最强理由是入口最少、代码最集中，与上游形态最接近。否掉原因：owner 判据无法表达同房间归位、失配小窗、owner 为 null 但小窗仍开着这几类状态，且会把 fork 的关闭顺序约束嵌进上游恢复主体，未来上游改 owner 登记位置或提前返回条件时会产生语义冲突——Git 自动合并成功也可能出现「提前返回绕过小窗处理」或「先登记 owner 后被关闭回调清空」。

- **把全局观察器从 `RouteObserver<GetPageRoute>` 泛化成 `RouteObserver<ModalRoute>`** — 最强理由是一处改动覆盖所有页面，不必为每个弹层单独接信号。否掉原因：视频页与直播间会在任何弹窗打开时收到 `didPushNext`，直接触发 `_shouldStartLivePip` 与视频进小窗，是比原 bug 更严重的回归。

- **扩展 `routeStackObserver` 统一治理页面恢复** — 最强理由是它已镜像根 Navigator 的路由栈，长期看能覆盖 popup 之上的 push/pop，包括本次不修的 `didPushNext` 缺口。否掉原因：它目前只有栈镜像、没有订阅通知能力，扩展属于播放页恢复的统一治理，会把本次修复的范围从「一条返回路径」放大到「全局路由事件分发」。

- **在榜单里先关面板再跳主页** — 最强理由是直接消除了 PopupRoute 夹在两个播放页之间这个前提，改动最小。否掉原因：丢失「返回后回到榜单面板」的既有体验，且只修这一处弹层，超级聊天等其他从弹层进主页的入口仍有同样问题。

- **只接上游，小窗问题不修** — 最强理由是影响面小、且不必在合并窗口内动最敏感的文件。否掉原因：小窗会变成盖在直播页上、显示直播画面、要等下次导航才消失的浮层，期间 `isInPipMode` 残留影响后续视频页保活判断；且合并时若整体采用上游那段会丢掉 fork 的四个 `didPopNext` 分支（直播小窗归位、视频小窗关闭、`isReturningFromPip` 早返回、`needsRecovery` 刷新引用），属功能回归。

## Verification

静态检查：

- `flutter analyze --no-pub` 最终全项目分析：0 error、4 warning、66 info，退出码 1，耗时 62.9 秒。四个 warning 是登录 controller 的重复 import、视频 controller 的 try 内 Future 未 await 与多余非空断言、播放器 view 的未使用 import；这些文件均未改动。70 条诊断均不位于本次新增代码行，完整日志保存在执行环境临时目录。新增 cascade_invocations 已消除。
- `lib/pages/live_room/view.dart` 中不再有裸的 `setPlayCallBack(plPlayerController.play)`。
- `_onPopNext()` 中只有一处 `playerInit()`；`super.didPopNext()` 只出现在 `didPopNext()` wrapper 内。
- 未改动 lock、两个小窗服务、视频页小窗关闭回调、`routeStackObserver`。
- 笔记校验三脚本通过，且不能以 `0 note(s)` 当作通过。

运行时验收由用户在真机执行，以下各项尚未验证：

1. 原复现路径：榜单进主页看番剧，逐层返回 → 番剧小窗关闭、直播间回到直播源、不再双份播放。
2. 头像路径：仍正常，且同一次返回只执行一次恢复。
3. 只开关榜单：直播继续，不重新缓冲（不调 `playerInit`）。
4. 直播暂停态进出：保持暂停，不自动播放。
5. 主页手动关掉番剧小窗再返回：靠实际源判定恢复，不黑屏。
6. 同房间直播小窗归位：动画正常，不重建源。
7. 其他直播间的小窗：关闭，本房间恢复自己的源与 owner。
8. 媒体通知上一项/下一项：直播 owner 下无操作、不抛错；普通视频与番剧仍可切集。
9. 双入口与迟到信号：调试器额外触发一次 `didPopNext()` / `_onPopPopupRoute(旧编号)`，恢复逻辑只执行一次。

## Consequences

- **`_handleInAppPipCloseCleanup()` 对已 dispose 页面调 `dispose()`**：目标路径用 `immediate: true` 关闭，Dart 层 `onClose` 与引用计数先执行，但不断言 native `pause`/`dispose` 的 Future 已完成。已 dispose 的视频页 State 会给共享单例减一次计数甚至销毁，因此直播侧必须在关闭之后才重新取引用；实例确实变化时用 `getInstance()` 保留一次计数，否则 `setDataSource` 会因计数为 0 早退。
- **恢复过程中立即进入其他播放页**：编号与路由检查能阻止旧任务继续登记 owner、监听与页面状态，但无法取消已进入 `setDataSource()` 的内部异步换源，存在竞争。
- **在任意其他页面点击早已失配的小窗**：`onTapToReturn` 会恢复失效 controller 并携带错误的 `fromPip` 状态。本方案只在直播返回入口先移除失配小窗，不改任意驻留页面的点击逻辑。
- **`didPushNext` 缺口保留**：弹层之上浏览主页/番剧期间直播弹幕流与计时器继续运行。属既有行为。
- **`setState` 时机**：microtask 只用于返回任务的串行调度，不作为帧尾保证。`_setPipRestoreInFlight()` 同步更新字段，`_performUpdate()` 合并刷新请求并在 post-frame 回调检查 mounted 后 setState；`ensureVisualUpdate()` 请求必要的新帧，避免 idle 时刷新等待不到帧。
- **`late final` 改 `late`**：修复初始化后再次赋值必然抛 `LateInitializationError` 的既有声明错误；不能由尚未观察到异常推断原分支不可达。延迟初始化保留，恢复时允许重新绑定播放器引用。
- **提交与回滚**：cherry-pick 与 fork 适配分成两个提交，适配提交是可供真机验收的完整实现；单独回退适配会恢复到未完成 fork 兼容的上游移植中间态，不能视为本缺陷已修复。
