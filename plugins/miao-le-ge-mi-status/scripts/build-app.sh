#!/bin/zsh
set -euo pipefail

plugin_root="${0:A:h:h}"
build_dir="${plugin_root}/.build"
app_dir="${plugin_root}/assets/喵了个咪的赶紧干活.app"
binary_dir="${app_dir}/Contents/MacOS"
resources_dir="${app_dir}/Contents/Resources"
module_cache="${build_dir}/module-cache"

/bin/mkdir -p "${build_dir}/bin" "${module_cache}" "${binary_dir}" "${resources_dir}"

env CLANG_MODULE_CACHE_PATH="${module_cache}" /usr/bin/clang \
  -fobjc-arc \
  -fmodules \
  -O2 \
  -mmacosx-version-min=13.0 \
  -framework Foundation \
  -I "${plugin_root}/Sources" \
  "${plugin_root}/Sources/StatusCore.m" \
  "${plugin_root}/Tests/StatusCoreTests.m" \
  -o "${build_dir}/bin/status-core-tests"

"${build_dir}/bin/status-core-tests"

env CLANG_MODULE_CACHE_PATH="${module_cache}" /usr/bin/clang \
  -fobjc-arc \
  -fmodules \
  -O2 \
  -mmacosx-version-min=13.0 \
  -framework Cocoa \
  -I "${plugin_root}/Sources" \
  "${plugin_root}/Sources/StatusCore.m" \
  "${plugin_root}/Sources/main.m" \
  -o "${binary_dir}/MiaoStatusMenu"

/bin/cp "${plugin_root}/assets/Info.plist" "${app_dir}/Contents/Info.plist"
/usr/bin/codesign --force --sign - "${app_dir}"
/usr/bin/plutil -lint "${app_dir}/Contents/Info.plist"
