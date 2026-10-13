#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
eportal_login.py —— 锐捷 ePortal 认证调试 / 登录工具（PC 端，只用标准库，无需 pip）

路由器上跑的是 usr/sbin/auto-eportal.sh；这个脚本给你在电脑上（Windows/Linux/macOS）
先验证门户接口、看清服务器返回的原文用。确认无误后再把账号密码填进路由器。

用法示例
--------
  # 只看当前是否已认证
  python eportal_login.py --check

  # 看门户支持哪些服务（service 该填什么，注意要填代码而不是中文）
  python eportal_login.py --services

  # 登录一次，并把每一步的原始返回都打印出来
  python eportal_login.py --user 2021000000 --password 123456 --debug

  # 从配置文件读账号（和路由器的 /etc/auto-eportal.conf 同一格式）
  python eportal_login.py --conf auto-eportal.conf

  # 学校有多个服务（校园网/电信/联通/移动）时指定服务名
  python eportal_login.py --user 学号 --password 密码 --service 校园网

退出码：0 = 认证成功（或已在线），1 = 认证失败，2 = 参数/网络错误
"""

import argparse
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from http.cookiejar import CookieJar

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36")

DEFAULT_CHECK_URL = "http://connect.rom.miui.com/generate_204"
DEFAULT_PORTAL = "211.87.158.84"

PORTAL_RE = re.compile(r"""https?://[^\s"'<>]*eportal/index\.jsp[^\s"'<>]*""")
PORTAL_FALLBACK_RE = re.compile(r"""https?://[^\s"'<>]*eportal/[^\s"'<>]*""")
MESSAGE_RE = re.compile(r'"(?:message|msg)"\s*:\s*"([^"]*)"')

# 服务器在业务层明确拒绝：换写法也没用，再试只会把账号试锁
FINAL_ERROR_WORDS = ("服务", "密码", "账号", "帐号", "用户名", "用户不存在",
                     "锁定", "冻结", "验证码", "校验码", "余额", "欠费", "在线")
# 像是"接口/参数不对"：值得换一种写法再试
PROTOCOL_ERROR_WORDS = ("参数", "格式", "请求", "无效", "不支持", "非法", "异常")


def is_final_error(message):
    return any(word in message for word in FINAL_ERROR_WORDS)


def is_protocol_error(message):
    return any(word in message for word in PROTOCOL_ERROR_WORDS)


def is_service_error(message):
    return "服务" in message


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """关掉自动跳转，这样能看到网关把我们 302 到哪儿去了。"""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def http_request(url, method="GET", data=None, cookie_jar=None,
                 headers=None, timeout=10, follow=True):
    """返回 (status, headers_dict, body_text)；网络异常时 status=0。"""
    handlers = []
    if cookie_jar is not None:
        handlers.append(urllib.request.HTTPCookieProcessor(cookie_jar))
    if not follow:
        handlers.append(NoRedirect())
    opener = urllib.request.build_opener(*handlers)

    hdrs = {"User-Agent": UA}
    if headers:
        hdrs.update(headers)

    body = data.encode("utf-8") if isinstance(data, str) else data
    req = urllib.request.Request(url, data=body, headers=hdrs, method=method)
    try:
        with opener.open(req, timeout=timeout) as resp:
            return resp.status, dict(resp.headers), resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        return exc.code, dict(exc.headers), exc.read().decode("utf-8", "replace")
    except Exception as exc:                                  # noqa: BLE001
        return 0, {}, "%s: %s" % (type(exc).__name__, exc)


def probe(check_url, cookie_jar=None, timeout=8):
    return http_request(check_url, cookie_jar=cookie_jar,
                        timeout=timeout, follow=False)


def is_online(status, body):
    """标准做法：探测地址返回 204/200 且没被劫持到认证页，就算已认证。"""
    if status not in (200, 204):
        return False
    low = body.lower()
    return "eportal" not in low and "wlanuserip" not in low


def extract_portal_url(status, headers, body):
    """从 302 的 Location 或页面 JS 里找出认证页完整地址。"""
    for key, value in headers.items():
        if key.lower() == "location" and "eportal" in value:
            return value.strip()
    for regex in (PORTAL_RE, PORTAL_FALLBACK_RE):
        match = regex.search(body)
        if match:
            return match.group(0)
    return ""


def split_portal_url(portal_url, fallback_host, fallback_scheme="http"):
    parts = urllib.parse.urlsplit(portal_url)
    if parts.scheme and parts.netloc:
        host = "%s://%s" % (parts.scheme, parts.netloc)
    else:
        host = "%s://%s" % (fallback_scheme, fallback_host)
    return host, parts.query


def login_interfacedo(host, portal_url, query_string, user, password,
                      service, cookie_jar, put_qs_in_url=False, timeout=15):
    endpoint = host + "/eportal/InterFace.do?method=login"
    form = {
        "userId": user,
        "password": password,
        "service": service,
        "queryString": "" if put_qs_in_url else query_string,
        "operatorPwd": "",
        "operatorUserId": "",
        "validcode": "",
        "passwordEncrypt": "false",
    }
    if put_qs_in_url and query_string:
        endpoint += "&" + query_string
    headers = {
        "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
        "X-Requested-With": "XMLHttpRequest",
        "Accept": "application/json, text/javascript, */*; q=0.01",
        "Referer": portal_url or host + "/eportal/index.jsp",
    }
    return http_request(endpoint, method="POST",
                        data=urllib.parse.urlencode(form),
                        cookie_jar=cookie_jar, headers=headers, timeout=timeout)


def login_userv2(host, portal_url, query_string, user, password,
                 cookie_jar, timeout=15):
    endpoint = host + "/eportal/userV2.do?method=login&param=true"
    if query_string:
        endpoint += "&" + query_string
    headers = {
        "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
        "X-Requested-With": "XMLHttpRequest",
        "Referer": portal_url or host + "/eportal/index.jsp",
    }
    form = {"username": user, "pwd": password}
    return http_request(endpoint, method="POST",
                        data=urllib.parse.urlencode(form),
                        cookie_jar=cookie_jar, headers=headers, timeout=timeout)


def extract_message(body):
    match = MESSAGE_RE.search(body or "")
    return match.group(1) if match else ""


def fetch_services(host, portal_url, query_string):
    """问门户支持哪些服务。返回 (原始应答, [(serviceName, serviceShowName), ...])"""
    referer = portal_url or (host + "/eportal/index.jsp")
    query = urllib.parse.urlencode({"queryString": query_string})
    text = ""
    for method in ("getServices", "page"):
        status, _, text = http_request(
            "%s/eportal/InterFace.do?method=%s&%s" % (host, method, query),
            headers={"Referer": referer}, timeout=10)
        # 用 HTTP 状态判断接口存不存在，别拿响应体猜
        if status == 200 and text and "serviceName" in text.replace("\\", ""):
            break
    # 门户返回里服务数组常常被转义成 \"serviceName\"，先把反斜杠去掉再解析
    clean = (text or "").replace("\\", "")
    names = re.findall(r'"serviceName"\s*:\s*"([^"]*)"', clean)
    shows = re.findall(r'"serviceShowName"\s*:\s*"([^"]*)"', clean)
    pairs = []
    seen = set()
    for i, name in enumerate(names):
        if name in seen:
            continue
        seen.add(name)
        pairs.append((name, shows[i] if i < len(shows) else ""))
    return text, pairs


def show_services(host, portal_url, query_string, debug=False):
    text, pairs = fetch_services(host, portal_url, query_string)
    if pairs:
        print("门户支持的服务（service 要填代码，不是界面上显示的中文）：")
        for name, show in pairs:
            print("  service=%-12s （界面上叫：%s）" % (name, show))
    else:
        print("没能解析出服务列表，原始应答如下：")
    if debug or not pairs:
        print("--- 原始应答 ---")
        print((text or "(空)")[:2000])
    return 0


def run(args):
    log = (lambda *a: print(*a)) if args.debug else (lambda *a: None)

    # ---------- 1. 探测：现在通不通？网关把我们跳到哪儿？ ----------
    status, headers, body = probe(args.check_url)
    print("探测 %s -> HTTP %s" % (args.check_url, status))
    if args.debug:
        print("--- 探测响应头 ---")
        for key, value in headers.items():
            print("  %s: %s" % (key, value))
        print("--- 探测响应体（前 500 字）---")
        print(body[:500])

    if is_online(status, body):
        print("结果: 当前已经在线，无需认证")
        return 0

    portal_url = extract_portal_url(status, headers, body)
    host, query_string = split_portal_url(portal_url, args.portal, args.scheme)
    print("认证页   : %s" % (portal_url or "(未解析到，回退到 %s)" % host))
    print("登录主机 : %s" % host)
    print("queryString 长度: %d" % len(query_string))
    log("queryString = %s" % query_string)

    if not query_string:
        print("警告: 没拿到 queryString。网关的跳转参数是认证必需的，"
              "请确认当前确实处于未认证状态。")

    if args.services:
        return show_services(host, portal_url, query_string, args.debug)

    if args.check:
        return 0

    if not args.user or not args.password:
        print("错误: 需要 --user 和 --password（或 --conf 指定配置文件）")
        return 2

    cookie_jar = CookieJar()
    if portal_url:
        http_request(portal_url, cookie_jar=cookie_jar, timeout=10)
    if query_string:
        http_request(host + "/eportal/InterFace.do?method=page",
                     cookie_jar=cookie_jar,
                     headers={"Referer": portal_url or host},
                     timeout=10)
        # 上面这一句只为建立会话，拿不到东西也无所谓
        pass

    # ---------- 2. 依次尝试三种接口写法 ----------
    attempts = (
        ("InterFace.do（queryString 在表单）",
         lambda: login_interfacedo(host, portal_url, query_string,
                                   args.user, args.password, args.service,
                                   cookie_jar, put_qs_in_url=False)),
        ("InterFace.do（queryString 在 URL）",
         lambda: login_interfacedo(host, portal_url, query_string,
                                   args.user, args.password, args.service,
                                   cookie_jar, put_qs_in_url=True)),
        ("userV2.do（旧版接口）",
         lambda: login_userv2(host, portal_url, query_string,
                              args.user, args.password, cookie_jar)),
    )

    last_message = ""
    for name, call in attempts:
        status, headers, body = call()
        print("\n[%s] -> HTTP %s" % (name, status))
        print("  原始返回: %s" % (body.strip()[:500] or "(空)"))
        message = extract_message(body)
        if message:
            last_message = message
            print("  服务器消息: %s" % message)

        # 认证后立刻再探一次网络，以探测结果为准
        status2, _, body2 = probe(args.check_url, cookie_jar=cookie_jar)
        if is_online(status2, body2):
            print("结果: 认证成功（接口: %s）" % name)
            return 0

        # 服务器在业务层明确拒绝：换写法也没用，立刻停手
        if message and is_final_error(message):
            print("结果: 认证被拒绝（%s）" % message)
            if is_service_error(message):
                print("提示: 多半是 service 填错了，下面列出门户支持的服务：")
                show_services(host, portal_url, query_string)
            return 1

        # 应答是规范的 JSON，而且不属于"参数不对"这类问题 -> 接口已找对，不必再换写法
        if '"result"' in body and not is_protocol_error(message):
            print("结果: 认证失败（%s）" % message)
            return 1

    print("\n结果: 三种接口写法都失败了%s"
          % ("（服务器最后的消息: %s）" % last_message if last_message else ""))
    print("提示: 若服务器要求验证码，或提示密码需要加密，请把上面的原始返回贴出来再调整。")
    return 1


def read_conf(path):
    """读取和路由器同一个格式的配置文件（key=value，允许 # 注释）。"""
    conf = {}
    try:
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                conf[key.strip()] = value.strip()
    except OSError as exc:
        print("读取配置文件失败: %s" % exc)
        sys.exit(2)
    return conf


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="锐捷 ePortal 认证调试/登录工具（仅标准库）")
    parser.add_argument("--user", help="校园网账号")
    parser.add_argument("--password", help="校园网密码")
    parser.add_argument("--service", default="", help="服务名/运营商，多数学校留空")
    parser.add_argument("--conf", help="配置文件路径（key=value 格式）")
    parser.add_argument("--check-url", default=DEFAULT_CHECK_URL,
                        help="用于判断是否已认证的探测地址，默认 %s" % DEFAULT_CHECK_URL)
    parser.add_argument("--portal", default=DEFAULT_PORTAL,
                        help="认证页服务器，默认 %s（解析不到跳转地址时使用）" % DEFAULT_PORTAL)
    parser.add_argument("--scheme", default="http", help="回退时使用的协议，默认 http")
    parser.add_argument("--check", action="store_true", help="只检测是否已认证")
    parser.add_argument("--services", action="store_true",
                        help="列出门户支持的服务代码（service 该填什么）")
    parser.add_argument("--debug", action="store_true", help="打印每一步的原始响应")
    args = parser.parse_args(argv)

    if args.conf:
        conf = read_conf(args.conf)
        args.user = args.user or conf.get("username")
        args.password = args.password or conf.get("pwd")
        args.service = args.service or conf.get("service", "")
        args.check_url = conf.get("check_url", args.check_url) or args.check_url
        args.portal = conf.get("portal_host", args.portal) or args.portal
        args.scheme = conf.get("portal_scheme", args.scheme) or args.scheme

    return run(args)


if __name__ == "__main__":
    sys.exit(main())
