#!/bin/sh
# =============================================================================
#  run_shell_test.sh —— 在 POSIX 环境（Linux / WSL / macOS）里端到端测试路由器脚本
#
#  作用：启动 test/mock_eportal.py 假门户，然后让 usr/sbin/auto-eportal.sh
#        真的去认证一遍，覆盖：语法检查 / 正常认证 / 密码错误 / 回退接口。
#
#  运行：  sh test/run_shell_test.sh
#  依赖：  sh、curl、python3、grep、sed
# =============================================================================

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
SCRIPT="$ROOT/usr/sbin/auto-eportal.sh"
PORT="${PORT:-18080}"
PORT2=$((PORT + 1))
PIDS=""

cleanup() {
	for pid in $PIDS; do
		kill "$pid" 2>/dev/null
	done
	rm -f "$CONF_TMP" "$CONF_BAD" "$LOG_FILE" "$COOKIE_JAR"
}
trap cleanup EXIT INT TERM

command -v python3 >/dev/null 2>&1 || { echo "缺少 python3"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "缺少 curl"; exit 1; }

export LOG_FILE="${TMPDIR:-/tmp}/auto-eportal-test.log"
export COOKIE_JAR="${TMPDIR:-/tmp}/auto-eportal-test.cookie"

make_conf() {
	# $1=端口 $2=密码 $3=输出文件
	cat > "$3" <<EOF
username=2021000000
pwd=$2
portal_host=127.0.0.1
portal_scheme=http
service=
check_url=http://127.0.0.1:$1/generate_204
poll_interval=2
max_retry=2
EOF
}

FAILED=0
ok()   { echo "  PASS  $1"; }
bad()  { echo "  FAIL  $1"; FAILED=$((FAILED + 1)); }
expect() { if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1 (期望 $3，实际 $2)"; fi; }
contains() { if grep -q "$2" "$3" 2>/dev/null; then ok "$1"; else bad "$1"; fi; }

status_of() {
	curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$1/generate_204"
}

echo "=========== 1. 语法检查 ==========="
if sh -n "$SCRIPT"; then ok "sh -n 语法检查通过"; else bad "sh -n 语法检查失败"; exit 1; fi

echo "=========== 2. 正常认证（queryString 在表单）==========="
python3 "$HERE/mock_eportal.py" --port "$PORT" >/dev/null 2>&1 &
PIDS="$PIDS $!"
sleep 1
CONF_TMP="${TMPDIR:-/tmp}/auto-eportal-test.conf"
make_conf "$PORT" 123456 "$CONF_TMP"
export CONF="$CONF_TMP"
rm -f "$LOG_FILE"
expect "认证前未通过" "$(status_of "$PORT")" "302"
sh "$SCRIPT" once
expect "once 认证后已在线" "$(status_of "$PORT")" "204"
contains "日志里有认证成功" "认证成功" "$LOG_FILE"

echo "=========== 3. 已在线时不重复认证 ==========="
sh "$SCRIPT" once

echo "=========== 4. 密码错误 ==========="
python3 "$HERE/mock_eportal.py" --port "$PORT2" >/dev/null 2>&1 &
PIDS="$PIDS $!"
sleep 1
CONF_BAD="${TMPDIR:-/tmp}/auto-eportal-test-bad.conf"
make_conf "$PORT2" wrong-password "$CONF_BAD"
export CONF="$CONF_BAD"
rm -f "$LOG_FILE"
sh "$SCRIPT" login
expect "密码错误时返回码为 1" "$?" "1"
contains "报告了账号密码问题" "账号或密码" "$LOG_FILE"
expect "密码错误后仍未通过" "$(status_of "$PORT2")" "302"

echo "=========== 5. 回退：queryString 放在 URL 上 ==========="
python3 "$HERE/mock_eportal.py" --port "$((PORT2 + 1))" --require-qs-in-url >/dev/null 2>&1 &
PIDS="$PIDS $!"
sleep 1
CONF_ALT="${TMPDIR:-/tmp}/auto-eportal-test-alt.conf"
make_conf "$((PORT2 + 1))" 123456 "$CONF_ALT"
export CONF="$CONF_ALT"
rm -f "$LOG_FILE"
sh "$SCRIPT" once
expect "回退后认证成功" "$(status_of "$((PORT2 + 1))")" "204"
contains "日志显示用的是 URL 写法" "queryString 在 URL" "$LOG_FILE"

echo "=========== 6. debug 模式能跑通 ==========="
export CONF="$CONF_TMP"
if sh "$SCRIPT" debug >/dev/null 2>&1; then ok "debug 模式返回 0"; else bad "debug 模式异常退出"; fi

echo
echo "==== 结果：$FAILED 项失败 ===="
[ "$FAILED" -eq 0 ] || exit 1
exit 0
