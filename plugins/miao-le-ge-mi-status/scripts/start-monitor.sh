#!/bin/zsh
set -euo pipefail

app_path="${PLUGIN_ROOT}/assets/喵了个咪的赶紧干活.app"
if [[ -d "${app_path}" ]]; then
  /usr/bin/open -g "${app_path}"
fi
