#!/bin/sh
# =============================================================================
#  flow_check.sh —— 在 BusyBox ash 下用「假的 curl」验证 do_login 的控制流：
#    * 主接口一次成功，不会多发请求
#    * 密码错误时只发一次请求就停手（避免把账号试锁）
#    * 参数错误 / 接口不存在时，按顺序回退到 URL 写法、旧版 userV2.do
#
#  运行：  sh test/flow_check.sh       （不需要网络，不需要真 curl）
# =============================================================================

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
SCRIPT="$ROOT/usr/sbin/auto-eportal.sh"

FAILED=0
ok()  { echo "  PASS  $1"; }
bad() { echo "  FAIL  $1"; FAILED=$((FAILED + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 $3，实际 $2）"; fi; }

echo "=========== 载入函数区 ==========="
LIB="$(sed -n '1,/^# ================================ 入口/p' "$SCRIPT" | sed '$d')"
eval "$LIB" || { echo "载入失败"; exit 1; }

export LOG_FILE=/tmp/flow-check.log
export COOKIE_JAR=/tmp/flow-check.cookie
CALLS=/tmp/flow-check.calls

PORTAL_QS='wlanuserip=0123456789abcdef0123456789abcdef&nasip=00112233445566778899aabbccddeeff&t=wireless-v2&nasportid=fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210'
PORTAL_URL="http://211.87.158.84/eportal/index.jsp?$PORTAL_QS"

MODE=ok
NEED=1
check_url='http://10.240.0.1/generate_204'
# 相当于已经 source 过配置文件
username=2021000000
pwd=123456
service=

echo "=========== 安装测试桩（覆盖 sleep / ping / curl）==========="
sleep() { :; }
ping()  { return 1; }

_login_count() {
	_n=$(grep -c 'method=login' "$CALLS" 2>/dev/null)
	[ -n "$_n" ] || _n=0
	printf '%s' "$_n"
}

curl() {
	# curl 的参数里 URL 不一定在最后（POST 的 --data* 在后面），取第一个 URL 参数
	_url=''
	for _a in "$@"; do
		case "$_a" in
			http://*|https://*)
				if [ -z "$_url" ]; then _url="$_a"; fi
				;;
		esac
	done
	printf '%s\n' "$*" >> "$CALLS"

	case "$_url" in
		*generate_204*)
			if [ "$(_login_count)" -ge "$NEED" ]; then
				printf 'HTTP/1.1 204 No Content\r\n\r\n'
			else
				printf 'HTTP/1.1 302 Found\r\nLocation: %s\r\nContent-Length: 0\r\n' "$PORTAL_URL"
			fi
			;;
		*userV2.do*)
			printf '{"result":"success","msg":"ok"}'
			;;
		*method=login*)
			case "$_url" in
				*'login&wlanuserip'*) _url_variant=1 ;;
				*) _url_variant=0 ;;
			esac
			case "$MODE" in
				ok)       printf '{"userIndex":"1","result":"success","message":""}' ;;
				bad)      printf '{"result":"fail","message":"用户名或密码错误"}' ;;
				paramerr)
					if [ "$_url_variant" = 0 ]; then
						printf '{"result":"fail","message":"参数错误"}'
					else
						printf '{"userIndex":"1","result":"success","message":""}'
					fi
					;;
				legacy)
					if [ "$_url_variant" = 0 ]; then
						printf '<html>404 Not Found</html>'
					else
						printf '{"userIndex":"1","result":"success","message":""}'
					fi
					;;
				userv2)   printf '<html>404 Not Found</html>' ;;
				service)  printf '{"result":"fail","message":"用户不允许使用本服务!"}' ;;
			esac
			;;
		*method=page*)        printf '{"service":["校园网"]}' ;;
		*eportal/index.jsp*)  printf '<html></html>' ;;
		*)                    printf '' ;;
	esac
}
ok "桩函数已就位"

run_case() {
	MODE="$1"
	NEED="$2"
	rm -f "$CALLS" "$LOG_FILE"
	do_login
	DO_LOGIN_RC=$?
	LOGIN_CALLS="$(_login_count)"
	LAST_URL="$(grep 'method=login' "$CALLS" 2>/dev/null | tail -n 1)"
}

echo "=========== 场景 1：主接口一次成功 ==========="
run_case ok 1
eq "do_login 返回 0" "$DO_LOGIN_RC" "0"
eq "只发了 1 次登录请求" "$LOGIN_CALLS" "1"
if grep -q 'http://211.87.158.84/eportal/InterFace.do?method=login' "$CALLS"; then
	ok "登录地址正确（含自动识别出的认证页主机）"
else
	bad "登录地址不正确"
fi
if grep -q 'queryString=wlanuserip' "$CALLS"; then
	ok "queryString 通过 --data-urlencode 送出"
else
	bad "queryString 没有送出"
fi
if grep -q 'userId=2021000000' "$CALLS"; then ok "带上了 userId"; else bad "缺少 userId"; fi
if grep -q 'passwordEncrypt=false' "$CALLS"; then ok "带上了 passwordEncrypt=false"; else bad "缺少 passwordEncrypt"; fi
grep -q 'method=page' "$CALLS" && ok "登录前取了门户配置" || bad "没有取门户配置"

echo "=========== 场景 2：密码错误时立刻停手 ==========="
run_case bad 999
eq "do_login 返回 1" "$DO_LOGIN_RC" "1"
eq "只发了 1 次登录请求（不会连试 3 次）" "$LOGIN_CALLS" "1"
if grep -q '认证被拒绝' "$LOG_FILE"; then
	ok "把服务器的错误原因写进了日志"
else
	bad "日志里没有服务器的错误原因"
fi

echo "=========== 场景 3：接口说参数错误 -> 回退到 URL 写法 ==========="
run_case paramerr 2
eq "do_login 返回 0" "$DO_LOGIN_RC" "0"
eq "共 2 次登录请求" "$LOGIN_CALLS" "2"
case "$LAST_URL" in
	*'InterFace.do?method=login&wlanuserip'*) ok "第 2 次用的是 URL 写法" ;;
	*) bad "第 2 次写法不对: $LAST_URL" ;;
esac

echo "=========== 场景 4：InterFace.do 不存在 -> 回退到旧版 userV2.do ==========="
run_case userv2 3
eq "do_login 返回 0" "$DO_LOGIN_RC" "0"
eq "共 3 次登录请求" "$LOGIN_CALLS" "3"
case "$LAST_URL" in
	*'userV2.do?method=login&param=true&wlanuserip'*) ok "最后一次用的是旧版 userV2.do" ;;
	*) bad "最后一次写法不对: $LAST_URL" ;;
esac

echo "=========== 场景 5：已在线时不应发起登录 ==========="
MODE=ok
NEED=0
rm -f "$CALLS" "$LOG_FILE"
online_check
eq "online_check 判定为在线" "$?" "0"
eq "没有登录请求" "$(_login_count)" "0"

echo "=========== 场景 6：服务代码填错 -> 立刻停手并提示 ==========="
run_case service 999
eq "do_login 返回 1" "$DO_LOGIN_RC" "1"
eq "只发了 1 次登录请求" "$LOGIN_CALLS" "1"
if grep -q 'services' "$LOG_FILE"; then
	ok "提示了用 services 查服务名"
else
	bad "没有提示用 services 查服务名"
fi

echo
echo "==== 结果：$FAILED 项失败 ===="
[ "$FAILED" -eq 0 ] || exit 1
exit 0
