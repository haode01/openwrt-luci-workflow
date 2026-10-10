#!/bin/bash
# ============================================================================
#  wf.sh — ArcWrt LuCI 工作流：配置解析 / 自检 / 包路径映射
#  只读配置，不探测、不猜测。
# ============================================================================
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONF="${ARCRWT_CONF:-$HOME/.dsh/arcwrt-luci.conf}"
TEMPLATE="$SKILL_DIR/references/workflow.conf.template"

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; BLU=$'\033[34m'; NC=$'\033[0m'
err() { printf '%s[ERR]%s %s\n' "$RED" "$NC" "$*" >&2; }
ok()  { printf '%s[OK]%s  %s\n' "$GRN" "$NC" "$*"; }
warn(){ printf '%s[WARN]%s %s\n' "$YEL" "$NC" "$*"; }
info(){ printf '%s[INFO]%s %s\n' "$BLU" "$NC" "$*"; }
# 脱敏：只露头尾，绝不把密码打到终端/日志里
mask(){ local v="$1"; if [ -z "$v" ]; then echo '(未设置)'; else printf '%s****%s (%d 位)' "${v:0:2}" "${v: -2}" "${#v}"; fi; }

REQUIRED_KEYS=(
  LOCAL_REPO PROJECT VERSION PATCH_SUBDIR
  SYNC_TOOL SYNC_SERVER
  BUILD_HOST BUILD_USER BUILD_PASS OPENWRT_ROOT CONTAINER MAKE_JOBS IPK_DIR
  ROUTER_HOST ROUTER_USER ROUTER_PASS ROUTER_WEB_URL
)

load_conf() {
  if [ ! -f "$CONF" ]; then
    err "找不到配置文件：$CONF"
    echo "  复制模板并填写："
    echo "    mkdir -p \"$(dirname "$CONF")\""
    echo "    cp \"$TEMPLATE\" \"$CONF\""
    echo "  或用 ARCRWT_CONF=/别的路径.conf 覆盖"
    exit 2
  fi
  # shellcheck disable=SC1090
  source "$CONF" || { err "解析失败：$CONF"; exit 2; }
  LOCAL_PATCH="$LOCAL_REPO/$PROJECT/$VERSION/$PATCH_SUBDIR"
  REMOTE_FEED_ROOT="$OPENWRT_ROOT/feeds/feeds_addon/package"
  IPK_PATH="$OPENWRT_ROOT/$IPK_DIR"
}

missing_keys() {
  local k
  for k in "${REQUIRED_KEYS[@]}"; do
    [ -n "${!k:-}" ] || echo "$k"
  done
}

cmd_conf() {
  echo "配置文件 : $CONF"
  echo
  printf '%-18s %s\n' "LOCAL_REPO"      "$LOCAL_REPO"
  printf '%-18s %s\n' "PROJECT/VERSION" "$PROJECT / $VERSION"
  printf '%-18s %s\n' "LOCAL_PATCH"     "$LOCAL_PATCH"
  printf '%-18s %s\n' "SYNC"            "$SYNC_TOOL  [$SYNC_SERVER]"
  printf '%-18s %s\n' "BUILD"           "$BUILD_USER@$BUILD_HOST:$BUILD_PORT  pass=$(mask "$BUILD_PASS")"
  printf '%-18s %s\n' "OPENWRT_ROOT"    "$OPENWRT_ROOT"
  printf '%-18s %s\n' "CONTAINER"       "$CONTAINER"
  printf '%-18s %s\n' "IPK_PATH"        "$IPK_PATH"
  printf '%-18s %s\n' "ROUTER"          "$ROUTER_USER@$ROUTER_HOST"
  printf '%-18s %s\n' "WEB"             "$ROUTER_WEB_URL ($ROUTER_WEB_USER)"
  echo "                     （密码已脱敏；真实值见配置文件）"
  printf '%-18s %s\n' "SWITCHES"        "clean_index=$REQUIRE_CLEAN_INDEX tree_verify=$VERIFY_CONTAINER_TREE ai_review=$AI_REVIEW product_verify=$REQUIRE_PRODUCT_VERIFY"
}

cmd_check() {
  local rc=0 miss
  miss="$(missing_keys)"
  if [ -n "$miss" ]; then
    err "缺少必填项："; echo "$miss" | sed 's/^/      /'; return 1
  fi
  ok "配置必备项齐全"

  # 本地仓库
  if [ -d "$LOCAL_REPO/.git" ]; then
    ok "本地仓库存在：$LOCAL_REPO  (branch $(git -C "$LOCAL_REPO" branch --show-current 2>/dev/null))"
  else
    err "不是 git 仓库：$LOCAL_REPO"; rc=1
  fi

  # 本地源码
  if [ -d "$LOCAL_PATCH/feeds/feeds_addon/package/arcadyan-utility/arc_luci" ]; then
    ok "本地源码存在：$LOCAL_PATCH/feeds/.../arc_luci"
  else
    err "本地源码缺失：$LOCAL_PATCH"; rc=1
  fi

  # 同步工具
  if [ -x "$SYNC_TOOL" ]; then
    ok "同步工具可执行：$SYNC_TOOL"
  else
    err "同步工具不可执行：$SYNC_TOOL"; rc=1
  fi

  # build server 密码 vs ~/.sync_remote.conf 的一致性
  local sc="$HOME/.sync_remote.conf"
  if [ -f "$sc" ]; then
    local sftp_pass
    sftp_pass="$(bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "${SFTP_PASSWORD:-}"' _ "$sc")"
    if [ -z "$sftp_pass" ]; then
      warn "$sc 里没有 SFTP_PASSWORD，无法核对一致性"
    elif [ "$sftp_pass" = "$BUILD_PASS" ]; then
      ok "BUILD_PASS 与 ~/.sync_remote.conf 的 SFTP_PASSWORD 一致"
    else
      warn "BUILD_PASS 与 ~/.sync_remote.conf 的 SFTP_PASSWORD **不一致** —— 两个都会用到，建议改成一样"
    fi
  else
    warn "找不到 $sc（sync_remote.sh 会不会用别人的配置？）"
  fi

  # 暂存区
  local staged
  staged="$(git -C "$LOCAL_REPO" status --porcelain 2>/dev/null | grep -cE '^[MADRC]')"
  if [ "$staged" = "0" ]; then
    ok "暂存区为空（干净起点）"
  elif [ "${REQUIRE_CLEAN_INDEX:-1}" = "1" ]; then
    err "暂存区已有 $staged 个文件 —— 开工前必须清空（提交掉或 git reset）"; rc=1
  else
    warn "暂存区已有 $staged 个文件（REQUIRE_CLEAN_INDEX=0，放行）"
  fi

  echo
  info "以下需在 build server 上执行（本脚本只在本地检查）："
  cat <<EOF
      # 树存在？
      ls $OPENWRT_ROOT/Makefile

      # 容器在跑？
      docker ps --format '{{.Names}}' | grep -x $CONTAINER

      # ★ 容器看到的树 = 你同步的树？（编译前必做）
      docker exec $CONTAINER md5sum $REMOTE_FEED_ROOT/arcadyan-utility/arc_luci/luci-arcadyan/luasrc/view/admin/<改动文件>
      # 与本地 md5sum 比对，不一致 = 树选错了，立刻停
EOF
  return $rc
}

cmd_targets() {
  local e p t w=24
  for e in "${PACKAGE_MAP[@]}"; do
    p="${e%%|*}"
    [ "${#p}" -gt "$w" ] && w="${#p}"
  done
  w=$((w + 2))
  printf "%-${w}s %s\n" "源码相对路径前缀" "make target"
  printf "%-${w}s %s\n" "$(printf '%*s' "$w" '' | tr ' ' '-')" "-----------"
  for e in "${PACKAGE_MAP[@]}"; do
    p="${e%%|*}"; t="${e##*|}"
    printf "%-${w}s %s\n" "$p" "$t"
  done
  if [ "${#DENY_PACKAGES[@]}" -gt 0 ]; then
    echo
    echo "禁用（永不使用）：${DENY_PACKAGES[*]}"
  fi
}

cmd_pkg() {
  [ $# -ge 1 ] || { err "用法: wf.sh pkg <改动文件路径>"; exit 2; }
  local f="$1"
  # 归一化：去绝对前缀 → 去 project_patch/ → 去 ./
  f="${f#"$LOCAL_PATCH"/}"
  f="${f#"$LOCAL_REPO"/}"
  f="${f#*project_patch/}"
  f="${f#./}"

  local best_len=-1 best_target=""
  local e p t
  for e in "${PACKAGE_MAP[@]}"; do
    p="${e%%|*}"; t="${e##*|}"
    case "$f" in
      "$p"/*|"$p")
        if [ "${#p}" -gt "$best_len" ]; then
          best_len="${#p}"; best_target="$t"
        fi
        ;;
    esac
  done

  # 禁用包先判：给出专门报错，而不是笼统的"无匹配"
  local d
  for d in "${DENY_PACKAGES[@]:-}"; do
    [ -n "$d" ] || continue
    case "$f" in
      */"$d"/*|*/"$d")
        err "命中禁用包：$d"
        echo "   它的 Build/Compile 是空的，只装配置/证书/init —— 改页面编它等于没编。" >&2
        exit 1 ;;
    esac
  done

  if [ -z "$best_target" ]; then
    err "没有匹配的包映射：$f"
    echo "   可在配置的 PACKAGE_MAP 里补一条" >&2
    exit 1
  fi

  local base="${best_target##*/}"
  for d in "${DENY_PACKAGES[@]:-}"; do
    [ -n "$d" ] && [ "$base" = "$d" ] && { err "命中禁用包：$d（Build/Compile 为空，编了等于没编）"; exit 1; }
  done

  echo "文件   : $f"
  echo "包     : $best_target"
  echo "命令   : make $best_target/clean $best_target/compile"
  echo "         （页面类文件必须带 clean —— .prepared stamp 不随源文件变化失效）"
}

case "${1:-help}" in
  conf)    load_conf; cmd_conf ;;
  check)   load_conf; cmd_check ;;
  pkg)     shift; load_conf; cmd_pkg "$@" ;;
  targets) load_conf; cmd_targets ;;
  *) cat <<EOF
wf.sh — ArcWrt LuCI 工作流配置工具

  wf.sh conf               打印解析后的全部参数（参数卡）
  wf.sh check              本地自检 + 输出需在 build server 跑的校验命令
  wf.sh pkg <改动文件>      改动文件 → make target
  wf.sh targets            打印包路径映射表

配置：\${ARCRWT_CONF:-~/.dsh/arcwrt-luci.conf}
模板：$TEMPLATE
EOF
     ;;
esac
