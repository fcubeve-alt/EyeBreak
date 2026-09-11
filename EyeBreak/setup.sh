#!/bin/bash
# EyeBreak — Mac 构建环境一键配置
# 运行前提：macOS + Xcode 16+ 已安装
# 用法：chmod +x setup.sh && ./setup.sh

set -euo pipefail

echo "=== EyeBreak Setup ==="

# 1. XcodeGen
if ! command -v xcodegen &>/dev/null; then
    echo "→ 安装 XcodeGen..."
    brew install xcodegen
else
    echo "✓ XcodeGen 已安装：$(xcodegen --version)"
fi

# 2. 签名配置写入本地 xcconfig
#
# 注意：不要把 Team ID 写进 project.yml —— 那个文件受 git 追踪，
# 个人签名身份会被误提交。Local.xcconfig 已在 .gitignore 中。
CONFIG="Local.xcconfig"
if [ ! -f "$CONFIG" ]; then
    echo ""
    echo "→ 创建 $CONFIG（本地签名配置，不会被提交）"
    echo "   Team ID 可在 developer.apple.com/account → Membership 找到"
    echo "   直接回车可跳过，之后在 Xcode 的 Signing & Capabilities 里选也行"
    echo ""
    read -r -p "输入 Apple Developer Team ID: " TEAM_ID || TEAM_ID=""
    {
        echo "// EyeBreak 本地签名配置（不提交到 git）"
        echo "// 由 setup.sh 生成，可手工编辑"
        echo "DEVELOPMENT_TEAM = ${TEAM_ID}"
    } > "$CONFIG"
    if [ -n "$TEAM_ID" ]; then
        echo "✓ Team ID 已写入 $CONFIG：$TEAM_ID"
    else
        echo "✓ 已创建空的 $CONFIG，稍后可自行填写 DEVELOPMENT_TEAM"
    fi
else
    echo "✓ $CONFIG 已存在，保持不变"
fi

# 3. 生成 Xcode 项目
echo "→ 生成 EyeBreak.xcodeproj..."
xcodegen generate

cat <<'EOF'

✅ 完成！后续步骤：

1. open EyeBreak.xcodeproj

2. 五个 target 都要确认 Signing & Capabilities：
     - EyeBreak                （主 App）
     - DeviceActivityReport    （Layer 1，容易漏）
     - DeviceActivityMonitor   （Layer 2 / 3）
     - ShieldConfiguration
     - ShieldAction
   每个都需要：Team、App Group (group.com.eyebreak.shared)、Family Controls

3. 在真机（iPhone / iPad）上 Build & Run
     模拟器不支持 Family Controls；护眼界面可在模拟器预览，检测功能不可用。

4. App 内点「申请授权」，同意 Screen Time 授权

5. 点「开始监测」，目标阈值先设 2 分钟，
   连续使用手机 2 分钟后观察 Shield 是否弹出

⚠️ Family Controls 与 App Groups 均需要付费的 Apple Developer Program。
   免费 Apple ID 无法开启这两项能力，检测功能将完全不可用。

详见 TESTING.md。
EOF
