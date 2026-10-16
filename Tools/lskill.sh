#!/bin/zsh
#
# Tools/lskill.sh — 查看 / 清理 LaunchServices 与插件库里的「脏注册」
#
# 为什么需要它：
#   用 `lsregister -f <临时目录里的构建>` 注册过之后，即使把那个目录 `rm -rf` 删掉，
#   LS 数据库里那条记录**依然在、而且仍然是 active 的**，会盖住你新构建的同名记录。
#   典型症状：「我明明改了 Info.plist / 重新构建了，行为却一点没变」。
#   `rm -rf` 不会注销记录，必须显式 `lsregister -u <路径>`。
#
# 用法：
#   Tools/lskill.sh list                       列出本项目的全部类型注册（含 active/inactive 与路径是否还在）
#   Tools/lskill.sh probe <文件>               现场解析该文件的 UTI（不走 Spotlight 缓存），并显示声明它的记录
#   Tools/lskill.sh clean                      只打印将要注销的脏记录（dry-run，不动手）
#   Tools/lskill.sh clean --yes                真的注销（默认只清「路径已不存在」的记录）
#   Tools/lskill.sh clean --yes --include-temp 连 /private/var/folders 下的临时构建记录一起清
#   Tools/lskill.sh register <App 路径>        把一个构建注册成 active，并启用 QL 扩展
#   Tools/lskill.sh clean --yes --register <App 路径>   清完脏记录后顺手重新注册指定构建
#
set -eu

LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
EXT_ID=com.oces.UnityAssetsQuickLook.Extension
MATCH=UnityAssetsQuickLook   # 用它把「属于本项目的路径」筛出来

DMP=$(mktemp -t lskill-dump)
trap 'rm -f "$DMP"' EXIT
"$LSREG" -dump > "$DMP" 2>/dev/null

# 本项目的注册路径（bundle 与 appex 都算），去重
all_paths() {
  grep '^path:' "$DMP" | awk '{print $2}' | grep -F "$MATCH" | sort -u || true
}

# 类型记录：UTI <TAB> 状态 <TAB> 声明来源路径（只输出本项目声明的）
type_records() {
  awk -v m="$MATCH" '
    # 记录之间用一串横线分隔；在分隔处清状态，避免把上一条的 uti/声明者串到下一条（claim 记录没有 type id）
    /^-{10,}/ { uti = ""; pl = ""; next }
    /^(bundle|plugin) id:/ {
      id = $0; sub(/^.*\(/, "", id); sub(/\).*$/, "", id); next
    }
    /^path:/ { if (id != "" && index($2, m) > 0) map[id] = $2; id = ""; next }
    /^type id:/ { uti = $3; pl = ""; next }
    /^(plugin|bundle):/ {
      pl = $0; sub(/^.*\(/, "", pl); sub(/\).*$/, "", pl); next
    }
    /^flags:/ {
      if (uti != "" && pl != "" && (pl in map)) {
        printf "%s\t%s\t%s\n", uti, $2, map[pl]
        uti = ""
      }
      next
    }
  ' "$DMP"
}

# 路径是否算脏：文件系统里已经不存在，或（--include-temp 时）在系统临时目录下
is_stale() {
  local p=$1
  if [ ! -e "$p" ]; then
    return 0
  fi
  if [ "$INCLUDE_TEMP" = 1 ]; then
    case "$p" in
      /private/var/folders/*|/var/folders/*) return 0 ;;
    esac
  fi
  return 1
}

cmd=${1:-list}
shift 2>/dev/null || true
ARG=${1:-}
YES=0
INCLUDE_TEMP=0
REGISTER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) YES=1 ;;
    --include-temp) INCLUDE_TEMP=1 ;;
    --register) REGISTER=$2; shift ;;
    *) if [ -z "$REGISTER" ]; then REGISTER=$1; fi ;;
  esac
  shift
done

case "$cmd" in
  list)
    printf '%-30s %-9s %s\n' "UTI" "状态" "声明来源"
    # 注意：循环变量不能叫 path —— zsh 里 path 与 PATH 绑定，赋值会把 PATH 清空
    type_records | while IFS=$'\t' read -r uti state src; do
      note=""
      if [ ! -e "$src" ]; then
        note="  ← 路径已不存在 = 脏记录"
      fi
      printf '%-30s %-9s %s%s\n' "$uti" "$state" "$src" "$note"
    done
    ;;

  probe)
    f=$ARG
    if [ -z "$f" ] || [ ! -e "$f" ]; then
      echo "用法：$0 probe <文件>"; exit 1
    fi
    echo "文件系统层面：$f"
    # mdls 走 Spotlight 索引会给你旧值，所以这里用 mdimport -t 现场重算
    uti=$(mdimport -t -d2 "$f" 2>&1 | sed -n 's/^ *kMDItemContentType = "\(.*\)";/\1/p' | head -1)
    echo "现场解析的 UTI：${uti:-（解析失败）}"
    mdimport -t -d2 "$f" 2>&1 | sed -n '/kMDItemContentTypeTree = /,/    );/p' | sed 's/^/    /'
    if [ -n "$uti" ]; then
      echo "声明它的类型记录（状态 / 来源路径）："
      type_records | awk -F'\t' -v u="$uti" '$1 == u { printf "    %-9s %s\n", $2, $3 }'
    fi
    ;;

  clean)
    targets=()
    while read -r p; do
      if is_stale "$p"; then targets+=("$p"); fi
    done < <(all_paths)
    if [ ${#targets[@]} -eq 0 ]; then
      echo "没有发现脏记录（路径都在）。当前注册："
      "$0" list
      exit 0
    fi
    echo "将要注销的脏记录："
    printf '  %s\n' "${targets[@]}"
    if [ "$YES" != 1 ]; then
      echo
      echo "这是 dry-run。加 --yes 才会真的执行。"
      exit 0
    fi
    for p in "${targets[@]}"; do
      echo "注销 $p"
      "$LSREG" -u "$p" || true
      case "$p" in
        *.appex) pluginkit -r "$p" 2>/dev/null || true ;;
      esac
    done
    ;;

  register)
    app=$ARG
    case "$app" in --*) app=$REGISTER ;; esac
    if [ -z "$app" ] || [ ! -d "$app" ]; then
      echo "用法：$0 register <App 路径>"; exit 1
    fi
    "$LSREG" -f "$app"
    for appex in "$app"/Contents/PlugIns/*.appex; do
      if [ -d "$appex" ]; then pluginkit -a "$appex" 2>/dev/null || true; fi
    done
    pluginkit -e use -i "$EXT_ID" 2>/dev/null || true
    echo "已注册：$app"
    "$0" list
    ;;

  *)
    sed -n '2,19p' "$0"
    exit 1
    ;;
esac
