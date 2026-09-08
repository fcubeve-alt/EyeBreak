#!/bin/bash
# EyeBreak — Mac 构建环境一键配置
# 运行前提：macOS + Xcode 16+ 已安装，有 Apple Developer 账号
# 用法：chmod +x setup.sh && ./setup.sh

set -e

echo "=== EyeBreak Setup ==="

# 1. 安装 XcodeGen
if ! command -v xcodegen &>/dev/null; then
    echo "→ 安装 XcodeGen..."
    brew install xcodegen
else
    echo "✓ XcodeGen 已安装：$(xcodegen --version)"
fi

# 2. 检查 project.yml 中的 Team ID
if grep -q 'DEVELOPMENT_TEAM: ""' project.yml; then
    echo ""
    echo "⚠️  需要填写 Apple Developer Team ID！"
    echo "   打开 project.yml，把 DEVELOPMENT_TEAM: \"\" 改为你的 Team ID"
    echo "   Team ID 可在 developer.apple.com/account → Membership 找到"
    echo ""
    read -p "输入 Team ID（直接回车跳过，之后在 Xcode 里改也行）: " TEAM_ID
    if [[ -n "$TEAM_ID" ]]; then
        sed -i '' "s/DEVELOPMENT_TEAM: \"\"/DEVELOPMENT_TEAM: \"$TEAM_ID\"/" project.yml
        echo "✓ Team ID 已设置：$TEAM_ID"
    fi
fi

# 3. 生成 Xcode 项目
echo "→ 生成 EyeBreak.xcodeproj..."
xcodegen generate

echo ""
echo "✅ 完成！后续步骤："
echo ""
echo "1. open EyeBreak.xcodeproj"
echo "2. 选中 EyeBreak target → Signing & Capabilities"
echo "   → 确认 Team、App Group (group.com.eyebreak.shared)、Family Controls"
echo "   → 对 DeviceActivityMonitor / ShieldConfiguration / ShieldAction 同样操作"
echo "3. 在真机（iPhone / iPad）上 Build & Run"
echo "4. App 内点「申请授权」，同意 Screen Time 授权"
echo "5. 点「开始监测」，阈值设 2 分钟，使用手机 2 分钟后观察 Shield 是否弹出"
echo ""
echo "注意：Family Controls 扩展只能在真机上测试，模拟器不支持。"
