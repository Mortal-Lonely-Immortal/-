#!/bin/sh
# =============================================================================
#  busybox_check.sh —— 在 BusyBox ash 环境（OpenWrt 用的就是它）下验证
#  usr/sbin/auto-eportal.sh 的语法与各解析函数。
#
#  运行：  sh test/busybox_check.sh
#  说明：  不需要网络、不需要 curl，纯粹验证 shell 语法 + sed/grep 解析逻辑。
# =============================================================================

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
SCRIPT="$ROOT/usr/sbin/auto-eportal.sh"

FAILED=0
ok()  { echo "  PASS  $1"; }
bad() { echo "  FAIL  $1"; FAILED=$((FAILED + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望[$3] 实际[$2]）"; fi; }

echo "=========== 0. 运行环境 ==========="
echo "shell   : $0"
busybox 2>/dev/null | head -n 1
printf 'grep -o : '
if echo abc | grep -o b >/dev/null 2>&1; then echo "支持"; else echo "不支持（需安装完整版 grep）"; fi

echo "=========== 1. sh -n 语法检查 ==========="
if sh -n "$SCRIPT" 2>/tmp/busybox-synerr; then
	ok "auto-eportal.sh 语法检查通过"
else
	bad "auto-eportal.sh 语法检查失败"
	cat /tmp/busybox-synerr
	exit 1
fi

if sh -n "$HERE/../install.sh" 2>/dev/null; then
	ok "install.sh 语法检查通过"
else
	bad "install.sh 语法检查失败"
fi

echo "=========== 2. 载入脚本内的函数区 ==========="
LIB="$(sed -n '1,/^# ================================ 入口/p' "$SCRIPT" | sed '$d')"
eval "$LIB" || { bad "无法载入函数区"; exit 1; }
type extract_portal_url >/dev/null 2>&1 && ok "函数已载入" || bad "函数未载入"

# ---------------------------------------------------------------- 测试数据
QS='wlanuserip=0123456789abcdef0123456789abcdef&wlanacname=aabbccddeeff00112233445566778899&ssid=&nasip=00112233445566778899aabbccddeeff&snmpagentip=&mac=deadbeefdeadbeefdeadbeefdeadbeef&t=wireless-v2&url=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef&apmac=&nasid=aabbccddeeff00112233445566778899&vid=0011223344556677&port=8899aabbccddeeff&nasportid=fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210'
PORTAL="http://211.87.158.84/eportal/index.jsp?$QS"
SQ="'"

echo "=========== 3. 认证页地址解析 ==========="

RESP_A="HTTP/1.1 302 Found
Location: $PORTAL
Content-Length: 0"
eq "Location 响应头解析" "$(extract_portal_url "$RESP_A")" "$PORTAL"

RESP_B="HTTP/1.1 200 OK
Content-Type: text/html

<html><script>top.self.location.href=\"$PORTAL\";</script></html>"
eq "页面双引号 JS 跳转解析" "$(extract_portal_url "$RESP_B")" "$PORTAL"

RESP_C="HTTP/1.1 200 OK

<html><script>window.location.href=${SQ}$PORTAL${SQ}</script></html>"
eq "页面单引号 JS 跳转解析" "$(extract_portal_url "$RESP_C")" "$PORTAL"

RESP_D="HTTP/1.1 200 OK

<html><a href=\"http://211.87.158.84/eportal/InterFace.do?method=page\">x</a>
<script>location.href=\"$PORTAL\"</script></html>"
eq "页面内多个 eportal 链接时优先取 index.jsp" "$(extract_portal_url "$RESP_D")" "$PORTAL"

RESP_E="HTTP/1.1 204 No Content"
if extract_portal_url "$RESP_E" >/dev/null; then bad "没有跳转地址时不应返回成功"; else ok "没有跳转地址时正确返回失败"; fi

echo "=========== 4. queryString / host 解析 ==========="
eq "queryString 原样取出" "$(build_query_string "$PORTAL")" "$QS"
eq "queryString 长度不被截断" "$(printf '%s' "$(build_query_string "$PORTAL")" | wc -c | tr -d ' ')" "$(printf '%s' "$QS" | wc -c | tr -d ' ')"
eq "没有 ? 时返回空" "$(build_query_string 'http://x/eportal/index.jsp')" ""
eq "带端口的 host" "$(build_host 'http://172.19.1.9:8080/eportal/index.jsp?x=1')" "http://172.19.1.9:8080"
eq "https 的 host" "$(build_host 'https://a.b.c/eportal/index.jsp?x=1')" "https://a.b.c"
eq "无端口的 host" "$(build_host "$PORTAL")" "http://211.87.158.84"

echo "=========== 5. 在线判定 ==="
P204="HTTP/1.1 204 No Content"
P200="HTTP/1.1 200 OK
Content-Type: text/html

<html>hello</html>"
P302="HTTP/1.1 302 Found
Location: $PORTAL"
PHIJACK="HTTP/1.1 200 OK
Content-Type: text/html

<html><script>window.location='$PORTAL'</script></html>"
P500="HTTP/1.1 500 Server Error"

judge_online "$P204" && ok "204 判定为在线" || bad "204 应判定为在线"
judge_online "$P200" && ok "普通 200 判定为在线" || bad "普通 200 应判定为在线"
if judge_online "$P302"; then bad "302 应判定为离线"; else ok "302 判定为离线"; fi
if judge_online "$PHIJACK"; then bad "被劫持的 200 应判定为离线"; else ok "被劫持的 200 判定为离线"; fi
if judge_online "$P500"; then bad "500 应判定为离线"; else ok "500 判定为离线"; fi
if judge_online ""; then bad "空响应应判定为离线"; else ok "空响应判定为离线"; fi

echo "=========== 6. 服务器应答解析 ==="
eq "提取 message" "$(extract_message '{"result": "fail", "message": "用户名或密码错误"}')" "用户名或密码错误"
eq "提取 msg" "$(extract_message '{"result":"fail","msg":"账号或密码错误"}')" "账号或密码错误"
eq "提取中文空 message" "$(extract_message '{"result":"success","message":""}')" ""
is_json_response '{"result": "fail"}' && ok "识别 JSON 应答" || bad "应识别出 JSON 应答"
if is_json_response '<html>404 Not Found</html>'; then bad "HTML 不应被当成 JSON"; else ok "HTML 正确排除"; fi
if is_json_response ''; then bad "空应答不应被当成 JSON"; else ok "空应答正确排除"; fi

echo "=========== 7. 错误分类（决定要不要换写法重试）==========="
is_final_error '用户不允许使用本服务!' && ok "服务错误=终局错误" || bad "服务错误应算终局"
is_final_error '用户名或密码错误' && ok "密码错误=终局错误" || bad "密码错误应算终局"
if is_final_error '参数错误'; then bad "参数错误不该算终局"; else ok "参数错误不算终局"; fi
is_protocol_error '参数错误' && ok "参数错误=协议错误" || bad "参数错误应算协议类"
if is_protocol_error '用户不允许使用本服务!'; then bad "服务错误不该算协议类"; else ok "服务错误不算协议类"; fi
is_service_error 'ePortal上有多个服务,服务不能为空' && ok "识别服务类错误" || bad "应识别出服务类错误"
if is_service_error '用户名或密码错误'; then bad "密码错误不该算服务类"; else ok "密码错误不算服务类"; fi

echo "=========== 8. 服务列表提取 ==========="
SVC='{"serviceContent":"x","serviceJson":"[{\"serviceName\":\"internet\",\"serviceShowName\":\"互联网\"},{\"serviceName\":\"local\",\"serviceShowName\":\"内网\"}]"}'
SVC_OUT="$(print_services "$SVC")"
case "$SVC_OUT" in
	*"service=internet"*) ok "提取到 internet" ;;
	*) bad "没提取到 internet: $SVC_OUT" ;;
esac
case "$SVC_OUT" in
	*"service=local"*) ok "提取到 local" ;;
	*) bad "没提取到 local: $SVC_OUT" ;;
esac
case "$SVC_OUT" in
	*互联网*) ok "带上了界面显示名" ;;
	*) bad "没带上界面显示名: $SVC_OUT" ;;
esac
eq "没有服务时输出为空" "$(print_services '{"a":1}')" ""

# 未转义的形式（有的门户直接返回 JSON 对象）也要能提取
SVC2='{"services":[{"serviceName":"internet","serviceShowName":"互联网"}]}'
case "$(print_services "$SVC2")" in
	*"service=internet"*) ok "未转义形式也能提取" ;;
	*) bad "未转义形式提取失败" ;;
esac
# 重复出现的服务（真实应答里同一份数组常出现 3 次）应去重
SVC3='{"a":{"serviceName":"internet","serviceShowName":"互联网"},"b":{"serviceName":"internet","serviceShowName":"互联网"}}'
eq "重复服务去重" "$(print_services "$SVC3" | grep -c 'service=internet')" "1"

echo
echo "==== 结果：$FAILED 项失败 ===="
[ "$FAILED" -eq 0 ] || exit 1
exit 0
