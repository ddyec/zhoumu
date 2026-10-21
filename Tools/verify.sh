#!/bin/bash
# 一键校验：周目计算逻辑 + iOS 编译检查（App 与小组件两个 target）+ 生成图标。
# 不依赖真机，也不依赖模拟器运行时。
set -euo pipefail
cd "$(dirname "$0")/.."

export SWIFT_MODULECACHE_PATH="$PWD/build/ModuleCache"
export CLANG_MODULE_CACHE_PATH="$PWD/build/ModuleCache"
mkdir -p "$SWIFT_MODULECACHE_PATH"
CACHE="$SWIFT_MODULECACHE_PATH"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"

echo "==> 1/4 校验周目计算逻辑"
swiftc -module-cache-path "$CACHE" -O \
  Tools/CalculatorCheck/main.swift \
  Shared/SemesterCalculator.swift \
  Shared/SharedStorage.swift \
  Shared/Theme.swift \
  Shared/ScheduleModel.swift \
  Shared/ScheduleOverride.swift \
  ZhouMu/Models/AppSettings.swift \
  -o build/zhoumu-check
./build/zhoumu-check

echo
echo "==> 2/4 App target 编译检查 (SDK: ${SDK})"
# 先去掉 #Preview 宏：它需要 swift-plugin-server，在受限沙箱里跑不起来。
SRC="$PWD/build/Typecheck"
rm -rf "$SRC"
mkdir -p "$SRC/App/Views" "$SRC/App/Models" "$SRC/Shared" "$SRC/Widget"
for f in ZhouMu/Views/*.swift; do
  sed '/^#Preview/,$d' "$f" > "$SRC/App/Views/$(basename "$f")"
done
cp ZhouMu/Models/*.swift "$SRC/App/Models/"
cp ZhouMu/ZhouMuApp.swift "$SRC/App/"
cp Shared/*.swift "$SRC/Shared/"
swiftc -typecheck -target arm64-apple-ios17.0 -sdk "$SDK" -module-cache-path "$CACHE" \
  "$SRC/App/ZhouMuApp.swift" "$SRC/App/Models/"*.swift "$SRC/App/Views/"*.swift "$SRC/Shared/"*.swift
echo "App 编译检查通过，无错误。"

echo
echo "==> 3/4 小组件 target 编译检查"
# 小组件必须单独检查：它有自己的 @main，和 App 的 @main 不能一起编译。
cp ZhouMuWidget/ZhouMuWidget.swift "$SRC/Widget/"
swiftc -typecheck -target arm64-apple-ios17.0 -sdk "$SDK" -module-cache-path "$CACHE" \
  "$SRC/Widget/ZhouMuWidget.swift" "$SRC/Shared/"*.swift
echo "小组件编译检查通过，无错误。"

echo
echo "==> 3.5/4 检查实时活动开关（NSSupportsLiveActivities）"
LIVE=$(grep -c "INFOPLIST_KEY_NSSupportsLiveActivities = YES" ZhouMu.xcodeproj/project.pbxproj || true)
if [ "$LIVE" -ge 2 ]; then
  echo "已开启 NSSupportsLiveActivities（$LIVE 处配置）。"
else
  echo "⚠️  NSSupportsLiveActivities 未开启，灵动岛不会工作。"
  exit 1
fi

echo
echo "==> 3.6/4 检查实时活动是否注册进 WidgetBundle"
# 踩过的坑：ActivityConfiguration 写好了但忘了加进 WidgetBundle，
# 结果活动能创建、SpringBoard 也收得到，但灵动岛和锁屏都不显示。
if grep -q "ClassActivityWidget()" ZhouMuWidget/ZhouMuWidget.swift \
   && grep -q "ActivityConfiguration(for: ClassActivityAttributes.self)" ZhouMuWidget/ZhouMuWidget.swift; then
  echo "实时活动已注册进 WidgetBundle。"
else
  echo "⚠️  ClassActivityWidget 没有加进 WidgetBundle，灵动岛不会显示。"
  exit 1
fi

echo
echo "==> 4/4 生成 App 图标"
ICON=ZhouMu/Assets.xcassets/AppIcon.appiconset
swift -module-cache-path "$CACHE" Tools/make_icon.swift "$ICON/AppIcon-1024.png" light
swift -module-cache-path "$CACHE" Tools/make_icon.swift "$ICON/AppIcon-1024-dark.png" dark

echo
echo "==> 全部通过"
echo "    界面预览（可选）：./Tools/render_ui.sh  和  ./Tools/render_widget.sh"

