# EyeBreak

检测「连续用屏」并弹出可关闭的护眼引导。iOS 17+。

> **状态：技术验证阶段（POC），尚不适合正式发布。**
> 核心检测链路已可编译并通过离线单测，但**尚未在真机上完成验收**。
> 详见下方「已知限制」。

---

## 它解决什么问题

iOS 没有给第三方 App 提供「连续屏幕使用时长」这样的 API。
系统只提供**区间内的累计用量**——这跟「连续用了 30 分钟」不是一回事：
零散刷十次手机和一口气刷半小时，累计用量可能完全相同。

EyeBreak 用三层策略逼近这个信号。

---

## 检测原理

### Layer 1 — `longestActivity`（最直接）

`DeviceActivityReport` 扩展读取 `ActivitySegment.longestActivity`，
这是系统直接给出的「片段内最长一次连续活动会话」。

**限制**：该扩展是 SwiftUI View，只有主 App 前台显示它时才会渲染。
也就是说这个值只在用户打开 EyeBreak 时刷新。因此 Layer 1 只作为
**打开 App 时的校准信号**，并且所有消费方都会做新鲜度校验
（超过 15 分钟未刷新的数据一律不采信），否则昨天的长会话会造成今天误触发。

### Layer 2 — 使用密度（后台主力）

这一层是真正在后台工作的。

关键约束：`DeviceActivityEvent` 的 threshold **在一个监测区间内只触发一次**，
不会重新武装；而 `DeviceActivitySchedule` 的区间**最短 15 分钟**。
所以「每 5 分钟一个滚动窗口、数够 6 个」这种做法在 API 层面根本建不出来。

实际做法是在同一个日区间里挂**一排递增阈值事件**（累计用量每 5 分钟一个），
记录每次回调的真实时钟，然后算：

```
使用密度 = 用量增量 ÷ 真实时钟增量
```

- 25 分钟用量在 ≤35 分钟真实时间内跑完 → 判为连续使用 → 触发
- 相邻里程碑之间真实时钟比用量多出 5 分钟以上 → 判为充分休息 → 连续链清零

「中途休息则重置」在这个模型里是**数学上天然成立**的：休息一定会拉长时钟间隔，
密度一定会掉下来，不依赖任何关于回调行为的假设。

### Layer 3 — 日总量（保底）

当日累计用量达到 45 分钟且 Layer 1/2 都没触发时，给一次柔性提醒；
之后每再累积 45 分钟才会再提醒一次。

---

## 提醒方式

触发后通过 `ManagedSettings` 的 Shield 遮罩产生存在感，
并推送通知。用户可以：

- **做护眼动作** — 解除遮罩，进入视频或四个动作（看远方 / 眨眼 / 闭眼 / 近远焦点）
- **稍后再说** — 立刻返回原 App，进入 15 分钟冷却

提醒始终可关闭。完成、跳过、稍后三种结果分开统计。

### Shield 的安全兜底

Shield 会遮住全部 App，因此必须保证它一定能解除。目前有三条独立恢复通道：

1. **到期看门狗** — 应用遮罩时注册一个一次性 DeviceActivity 计划，
   到期由系统回调 `intervalDidEnd` 强制解除，不依赖用户操作
2. **通知内「立即解除遮罩」** — 非前台动作，系统在后台唤起 App 执行
3. **打开 App 或扩展下次被唤醒时** 的超时检查

界面里另有「强制解除 Shield」手动按钮。

---

## 构建

需要 macOS + Xcode 16+。

```bash
cd EyeBreak
chmod +x setup.sh && ./setup.sh
```

脚本会安装 XcodeGen、生成 `Local.xcconfig`（存放你的 Team ID，已 gitignore）、
并生成 `EyeBreak.xcodeproj`。

五个 target 都需要配置 Team、App Group (`group.com.eyebreak.shared`) 和
Family Controls：

| Target | 作用 |
|---|---|
| `EyeBreak` | 主 App |
| `DeviceActivityReport` | Layer 1（**容易漏配**） |
| `DeviceActivityMonitor` | Layer 2 / 3 |
| `ShieldConfiguration` | 遮罩外观 |
| `ShieldAction` | 遮罩按钮行为 |

---

## ⚠️ 必须知道的前提

**Family Controls 和 App Groups 都需要付费的 Apple Developer Program（$99/年）。**
免费 Apple ID 无法开启这两项能力，检测功能会完全不可用。

此外 Family Controls 用于 App Store 分发时，还需要单独向 Apple 申请 entitlement 审批。

护眼引导界面不依赖任何权限，可在模拟器中预览（主界面「预览护眼界面」按钮）。

---

## 已知限制

- **尚未真机验收。** CI 只能证明编译、单测和模拟器启动，不能证明真机 Screen Time
  回调、Shield 呈现与恢复行为。v0.3 的两个 Kill Test 都还没有真机证据。
- Layer 1 只在 App 前台时刷新（见上）。
- 跨午夜时看门狗计划无法建立，此时依赖其余两条恢复通道。
- 主界面目前仍是工程调试台，不是面向普通用户的形态。
- 护眼视频没有字幕或等价文本，听觉无障碍未覆盖。

---

## 测试

- 单元测试：`EyeBreakTests`，覆盖检测算法与 v0.3 Kill Test #1 的各场景，CI 每次运行
- 真机验收清单：见 [`EyeBreak/TESTING.md`](EyeBreak/TESTING.md)

CI（GitHub Actions）每次推送会执行：生成工程 → 校验扩展 plist 与权限未被覆盖 →
校验扩展入口指向真实符号 → 单元测试 → 编译 → 校验产物内容。

---

## 隐私

不联网，无账号，无服务器。所有数据留在设备本地。
详见 [PRIVACY.md](PRIVACY.md)。

---

## 许可

[MIT](LICENSE)
