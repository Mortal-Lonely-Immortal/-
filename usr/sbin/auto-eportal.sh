#!/bin/sh
# =============================================================================
#  auto-eportal.sh —— 锐捷 ePortal 校园网自动认证脚本（OpenWrt / 通用 Linux）
#
#  仿照 7Ji/auto-whu 的 auto-whu.sh 编写，区别在于适配的是"新版"锐捷 ePortal：
#    认证页形如  http://<portal>/eportal/index.jsp?wlanuserip=...&t=wireless-v2
#    登录接口为  POST http://<portal>/eportal/InterFace.do?method=login
#                （表单参数 userId / password / service / queryString /
#                  operatorPwd / operatorUserId / validcode / passwordEncrypt）
#  同时保留旧版 http://<portal>:<port>/eportal/userV2.do?method=login&param=true&<query>
#  接口作为回退（auto-whu 用的就是这个旧接口）。
#
#  用法：
#    auto-eportal.sh            常驻循环（由 /etc/init.d/auto-eportal 调用）
#    auto-eportal.sh once       只检测一次：在线则退出，离线则认证一次
#    auto-eportal.sh login      跳过检测，直接认证一次
#    auto-eportal.sh debug      输出诊断信息（探测响应 / 认证页地址 / 各接口返回原文）
#    auto-eportal.sh services    列出门户支持的服务代码（service 该填什么）
#
#  依赖：完整版 curl（需要 --data-urlencode、-G）、grep（需要 -o、-q）、sed、ping
#        OpenWrt 上先执行:  opkg update && opkg install curl grep
# =============================================================================

CONF="${CONF:-/etc/auto-eportal.conf}"
LOG_FILE="${LOG_FILE:-/tmp/auto-eportal.log}"
COOKIE_JAR="${COOKIE_JAR:-/tmp/auto-eportal.cookie}"
UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36'

# ---------------------------- 默认配置（可被 CONF 覆盖） ----------------------
portal_host='211.87.158.84'   # 认证页服务器；一般无需改，脚本会自动从跳转地址识别
portal_scheme='http'
service=''                    # 运营商/服务名，多数学校留空；如区分"校园网/电信/联通"再填
check_url='http://connect.rom.miui.com/generate_204'
poll_interval=10              # 两次检测之间的间隔（秒）
max_retry=5                   # 一次性认证失败后额外重试次数
debug=0

PROBE=''

# ============================== 基础工具 ====================================
say() {
	printf '%s\n' "$*"
	printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE" 2>/dev/null
	return 0
}

die() {
	say "ERROR: $*"
	exit 1
}

dbg() {
	if [ "$debug" = 1 ]; then
		printf '[debug] %s\n' "$*" >&2
	fi
	return 0
}

# ============================== 配置文件 ====================================
# 返回值: 0=配置完整  1=文件不存在  2=缺少账号或密码
load_conf() {
	[ -r "$CONF" ] || return 1
	# shellcheck disable=SC1090
	. "$CONF"
	if [ -n "$username" ] && [ -n "$pwd" ]; then
		return 0
	fi
	return 2
}

require_conf() {
	load_conf
	_rc=$?
	case "$_rc" in
		0) return 0 ;;
		1) die "配置文件 $CONF 不存在或不可读" ;;
		*) die "请在 $CONF 中填写 username 和 pwd" ;;
	esac
}

# ============================== 网络探测 ====================================
# 探测一次，结果放进全局变量 PROBE（含响应头 + 响应体）
probe() {
	PROBE="$(curl -s -m 8 -i -A "$UA" "$check_url" 2>/dev/null)"
	[ -n "$PROBE" ]
}

# 只看探测响应内容判断是否在线: 0=在线  1=未认证/离线（纯函数，方便单测）
judge_online() {
	[ -n "$1" ] || return 1
	# 被认证网关劫持的特征：跳转(3xx) 或 响应里出现 eportal
	if printf '%s' "$1" | grep -qi '^HTTP/[0-9.]* 30[0-9]'; then
		return 1
	fi
	if printf '%s' "$1" | grep -qi 'eportal'; then
		return 1
	fi
	# 标准的 204 / 200 才算真的通
	if printf '%s' "$1" | grep -qi '^HTTP/[0-9.]* 20[04]'; then
		return 0
	fi
	return 1
}

# 探测 + 判断: 0=在线  1=未认证/离线
online_check() {
	probe
	if [ -n "$PROBE" ]; then
		judge_online "$PROBE"
		return $?
	fi
	# 探测地址完全没响应（例如 DNS 被拦），退化为 ping 公网地址判断
	ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1 && return 0
	return 1
}

# ========================= 从探测响应里解析认证页 ============================
# 用法: extract_portal_url "<响应原文>"   —— 成功时把完整认证页 URL 打印到 stdout
extract_portal_url() {
	_raw="$1"
	[ -n "$_raw" ] || return 1

	# 1) 跳转响应头 Location:
	_loc="$(printf '%s\n' "$_raw" | tr -d '\r' \
		| sed -n 's/^[Ll]ocation:[[:space:]]*\(http[s]*:\/\/[^[:space:]]*\).*$/\1/p' \
		| head -n 1)"
	if [ -n "$_loc" ]; then
		printf '%s' "$_loc"
		return 0
	fi

	# 2) 页面 JS 里的跳转，例如 top.self.location.href='http://x/eportal/index.jsp?...'
	_flat="$(printf '%s' "$_raw" | tr -d '\r' | tr '"' '\n' | tr "'" '\n' | tr '<' '\n' | tr '>' '\n')"
	_loc="$(printf '%s\n' "$_flat" \
		| grep -o 'http[s]*://[^[:space:]]*eportal/index\.jsp[^[:space:]]*' \
		| head -n 1)"
	if [ -n "$_loc" ]; then
		printf '%s' "$_loc"
		return 0
	fi

	# 3) 兜底：任意 eportal 地址
	_loc="$(printf '%s\n' "$_flat" \
		| grep -o 'http[s]*://[^[:space:]]*eportal/[^[:space:]]*' \
		| head -n 1)"
	if [ -n "$_loc" ]; then
		printf '%s' "$_loc"
		return 0
	fi
	return 1
}

# 取 URL 中 ? 之后的部分（即门户要求的 queryString）
build_query_string() {
	case "$1" in
		*\?*) printf '%s' "${1#*\?}" ;;
		*) printf '' ;;
	esac
}

# 取 URL 的 scheme://host[:port]
build_host() {
	printf '%s' "$1" | sed -n 's#^\(http[s]*://[^/]*\).*$#\1#p' | head -n 1
}

# ============================== 登录请求 ====================================
# 新版接口: queryString 放在表单里（最常见）
login_interfacedo() {
	_dl_referer="$1"
	_dl_endpoint="$2"
	_dl_query="$3"
	curl -s -m 15 -c "$COOKIE_JAR" -b "$COOKIE_JAR" -A "$UA" \
		-H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
		-H 'X-Requested-With: XMLHttpRequest' \
		-H 'Accept: application/json, text/javascript, */*; q=0.01' \
		-H "Referer: $_dl_referer" \
		-X POST "$_dl_endpoint" \
		--data-urlencode "userId=$username" \
		--data-urlencode "password=$pwd" \
		--data-urlencode "service=$service" \
		--data-urlencode "queryString=$_dl_query" \
		--data "operatorPwd=" \
		--data "operatorUserId=" \
		--data-urlencode "validcode=" \
		--data "passwordEncrypt=false" 2>/dev/null
}

# 旧版接口（auto-whu 用的那个）
login_userv2() {
	_dl_referer="$1"
	_dl_endpoint="$2"
	curl -s -m 15 -c "$COOKIE_JAR" -b "$COOKIE_JAR" -A "$UA" \
		-H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
		-H 'X-Requested-With: XMLHttpRequest' \
		-H "Referer: $_dl_referer" \
		-X POST "$_dl_endpoint" \
		--data-urlencode "username=$username" \
		--data-urlencode "pwd=$pwd" 2>/dev/null
}

# 返回体是不是 ePortal 的 JSON 应答（说明该接口存在并且被正确处理了）
is_json_response() {
	case "$1" in
		*'"result"'*|*"'result'"*) return 0 ;;
	esac
	return 1
}

# 从应答里抠出 message / msg 文本
extract_message() {
	_msg="$(printf '%s' "$1" \
		| sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
		| head -n 1)"
	if [ -z "$_msg" ]; then
		_msg="$(printf '%s' "$1" \
			| sed -n 's/.*"msg"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
			| head -n 1)"
	fi
	printf '%s' "$_msg"
}

# 应答像"接口/参数不对"这类问题（值得换种写法再试一次）
is_protocol_error() {
	case "$1" in
		*参数*|*格式*|*请求*|*无效*|*不支持*|*非法*|*异常*) return 0 ;;
	esac
	return 1
}

# 服务器在业务层明确拒绝：换写法也没用，再试只会把账号试锁
is_final_error() {
	case "$1" in
		*服务*|*密码*|*账号*|*帐号*|*用户名*|*用户不存在*|*锁定*|*冻结*|*验证码*|*校验码*|*余额*|*欠费*|*在线*) return 0 ;;
	esac
	return 1
}

# 是不是"服务名/服务代码填错了"这一类
is_service_error() {
	case "$1" in
		*服务*) return 0 ;;
	esac
	return 1
}

# ============================== 认证主流程 ==================================
do_login() {
	probe
	_purl="$(extract_portal_url "$PROBE")"
	if [ -n "$_purl" ]; then
		_host="$(build_host "$_purl")"
		_qs="$(build_query_string "$_purl")"
	else
		_host=''
		_qs=''
		say "WARNING: 没能从探测响应里解析出认证页地址，改用 $portal_scheme://$portal_host"
	fi
	[ -n "$_host" ] || _host="$portal_scheme://$portal_host"

	dbg "认证页 URL : $_purl"
	dbg "登录主机   : $_host"
	dbg "queryString: $_qs"

	rm -f "$COOKIE_JAR"
	# 先访问认证页，拿到 JSESSIONID 之类的会话 Cookie
	if [ -n "$_purl" ]; then
		curl -s -m 10 -c "$COOKIE_JAR" -b "$COOKIE_JAR" -A "$UA" -o /dev/null "$_purl" 2>/dev/null
	fi
	# 再取一次门户页面配置（浏览器登录前的标准动作，失败无所谓）
	if [ -n "$_qs" ]; then
		curl -s -m 10 -o /dev/null -A "$UA" -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
			-H "Referer: $_purl" \
			-G --data-urlencode "queryString=$_qs" \
			"$_host/eportal/InterFace.do?method=page" 2>/dev/null
	fi

	_attempt=0
	_last_msg=''
	while [ "$_attempt" -lt 3 ]; do
		_attempt=$((_attempt + 1))
		case "$_attempt" in
			1)
				_iface='InterFace.do（queryString 在表单）'
				_resp="$(login_interfacedo "$_purl" "$_host/eportal/InterFace.do?method=login" "$_qs")"
				;;
			2)
				_iface='InterFace.do（queryString 在 URL）'
				_resp="$(login_interfacedo "$_purl" "$_host/eportal/InterFace.do?method=login&$_qs" '')"
				;;
			3)
				_iface='userV2.do（旧版接口）'
				_resp="$(login_userv2 "$_purl" "$_host/eportal/userV2.do?method=login&param=true&$_qs")"
				;;
		esac

		dbg "[$_iface] 原始应答: $_resp"
		sleep 2
		if online_check; then
			say "INFO: 认证成功（接口: $_iface）"
			return 0
		fi

		# 成不成功以探测结果为准；下面只是把失败原因讲清楚
		_msg="$(extract_message "$_resp")"
		if [ -n "$_msg" ]; then
			_last_msg="$_msg"
			say "WARNING: $_iface 返回: $_msg"
		fi

		# 服务器在业务层明确拒绝（服务/账号/密码/验证码…）：换写法也没用，立刻停手
		if [ -n "$_msg" ] && is_final_error "$_msg"; then
			say "ERROR: 认证被拒绝（$_msg）"
			if is_service_error "$_msg"; then
				say "提示: 多半是 service 填错了，执行 'auto-eportal.sh services' 看门户支持哪些服务。"
				say "      注意要填服务代码（例如 internet / local），不是界面上显示的中文。"
			fi
			return 1
		fi

		# 应答是规范的 JSON，而且不属于"参数不对"这类问题 -> 接口已经找对，没必要再换写法
		if is_json_response "$_resp" && ! is_protocol_error "$_msg"; then
			say "ERROR: 认证失败（$_msg）"
			return 1
		fi
	done

	if [ -n "$_last_msg" ]; then
		say "ERROR: 三种接口写法都失败了，服务器最后的消息: $_last_msg"
	else
		say "ERROR: 三种接口写法都失败了，请运行 'auto-eportal.sh debug' 看接口原文"
	fi
	return 1
}

# ============================== 常驻循环 ====================================
daemon_loop() {
	require_conf
	say "INFO: auto-eportal 已启动，账号 $username，每 ${poll_interval} 秒检测一次"
	while : ; do
		if online_check; then
			say "INFO: 网络正常，${poll_interval} 秒后再检测"
		else
			say "WARNING: 检测到未认证/已掉线，正在尝试认证"
			if do_login; then
				say "INFO: (重新)认证成功"
			else
				_retry=1
				while [ "$_retry" -le "$max_retry" ]; do
					say "WARNING: 第 $_retry 次重试，${poll_interval} 秒后开始"
					sleep "$poll_interval"
					if do_login; then
						say "INFO: (重新)认证成功"
						break
					fi
					_retry=$((_retry + 1))
				done
				if [ "$_retry" -gt "$max_retry" ]; then
					say "ERROR: 连续 $max_retry 次认证失败，请检查账号密码；可用 'auto-eportal.sh debug' 排查"
				fi
			fi
		fi
		sleep "$poll_interval"
	done
}

# ============================== 诊断模式 ====================================
do_debug() {
	debug=1
	load_conf
	if [ $? -ne 0 ]; then
		say "WARNING: 读不到 $CONF 或里面没填账号密码，仅做网络诊断"
	fi

	say '=== 0. 环境 ==='
	curl --version 2>/dev/null | head -n 1
	say "check_url = $check_url"

	say '=== 1. 网络探测原始响应（前 40 行）==='
	probe
	printf '%s\n' "$PROBE" | head -n 40

	say '=== 2. 解析出的认证页地址 ==='
	_purl="$(extract_portal_url "$PROBE")"
	printf '%s\n' "$_purl"
	_host="$(build_host "$_purl")"
	_qs="$(build_query_string "$_purl")"
	[ -n "$_host" ] || _host="$portal_scheme://$portal_host"
	printf 'host        = %s\n' "$_host"
	printf 'queryString = %s\n' "$_qs"

	if [ -n "$_purl" ]; then
		say '=== 3. 认证页 HTTP 状态 ==='
		curl -s -m 10 -o /dev/null -w 'index.jsp -> HTTP %{http_code}\n' -A "$UA" "$_purl"
	fi

	if [ -n "$_qs" ]; then
		say '=== 4. 门户支持的服务（method=getServices）==='
		_resp="$(curl -s -m 10 -A "$UA" -H "Referer: $_purl" \
			-G --data-urlencode "queryString=$_qs" \
			"$_host/eportal/InterFace.do?method=getServices" 2>/dev/null)"
		case "$_resp" in
			''|*404*)
				say '（没有 getServices 接口，退回 method=page）'
				_resp="$(curl -s -m 10 -A "$UA" -H "Referer: $_purl" \
					-G --data-urlencode "queryString=$_qs" \
					"$_host/eportal/InterFace.do?method=page" 2>/dev/null)"
				;;
		esac
		print_services "$_resp"
		printf '%s\n' "$_resp" | head -c 2000
		printf '\n'
	fi

	say '=== 5. 登录接口原始应答 ==='
	rm -f "$COOKIE_JAR"
	[ -n "$_purl" ] && curl -s -m 10 -c "$COOKIE_JAR" -b "$COOKIE_JAR" -A "$UA" -o /dev/null "$_purl"

	printf -- '--- InterFace.do（queryString 在表单）---\n'
	login_interfacedo "$_purl" "$_host/eportal/InterFace.do?method=login" "$_qs"
	printf '\n--- InterFace.do（queryString 在 URL）---\n'
	login_interfacedo "$_purl" "$_host/eportal/InterFace.do?method=login&$_qs" ''
	printf '\n--- userV2.do（旧版接口）---\n'
	login_userv2 "$_purl" "$_host/eportal/userV2.do?method=login&param=true&$_qs"
	printf '\n'
	say 'INFO: 诊断结束，请把上面 1~5 段内容贴出来'
}

# ============================== 查询服务名 ==================================
# 很多门户的 service 要填"代码"（如 internet / local），不是界面上显示的中文，
# 这里把门户实际支持的服务列出来。
print_services() {
	# 门户返回里服务数组常常被转义成 \"serviceName\"，先把反斜杠去掉再解析
	_clean="$(printf '%s\n' "$1" | tr -d '\\')"
	_out="$(printf '%s\n' "$_clean" | tr '}' '\n' \
		| sed -n 's/.*"serviceName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*"serviceShowName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1|\2/p' \
		| sort -u)"
	if [ -z "$_out" ]; then
		# 兜底：只拿到服务代码，没拿到界面显示名
		_out="$(printf '%s\n' "$_clean" | tr '}' '\n' \
			| sed -n 's/.*"serviceName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1|/p' \
			| sort -u)"
	fi
	printf '%s\n' "$_out" | while IFS='|' read -r _name _show; do
		[ -n "$_name" ] || continue
		printf '  service=%s    （界面上叫：%s）\n' "$_name" "$_show"
	done
}

do_services() {
	load_conf
	probe
	_purl="$(extract_portal_url "$PROBE")"
	_host="$(build_host "$_purl")"
	[ -n "$_host" ] || _host="$portal_scheme://$portal_host"
	_qs="$(build_query_string "$_purl")"

	if [ -z "$_qs" ]; then
		say "WARNING: 没解析到 queryString（可能当前已在线），结果可能不准"
	fi

	say '=== 门户支持的服务 ==='
	_resp="$(curl -s -m 10 -A "$UA" -H "Referer: $_purl" \
		-G --data-urlencode "queryString=$_qs" \
		"$_host/eportal/InterFace.do?method=getServices" 2>/dev/null)"
	case "$_resp" in
		''|*404*)
			say '（该门户没有 getServices 接口，改用 method=page）'
			_resp="$(curl -s -m 10 -A "$UA" -H "Referer: $_purl" \
				-G --data-urlencode "queryString=$_qs" \
				"$_host/eportal/InterFace.do?method=page" 2>/dev/null)"
			;;
	esac

	print_services "$_resp"
	printf '\n--- 原始应答 ---\n%s\n' "$_resp"
	say "请把上面的 service= 值填进 $CONF（填代码，不是界面上的中文）"
}

# ================================ 入口 ======================================
case "${1:-daemon}" in
	daemon|'')
		daemon_loop
		;;
	once)
		require_conf
		if online_check; then
			say "INFO: 网络正常，无需认证"
			exit 0
		fi
		say "WARNING: 未认证，开始认证"
		do_login || exit 1
		;;
	login)
		require_conf
		do_login || exit 1
		;;
	debug)
		do_debug
		;;
	services)
		do_services
		;;
	*)
		printf '用法: %s [daemon|once|login|debug|services]\n' "$0"
		exit 2
		;;
esac
exit 0
