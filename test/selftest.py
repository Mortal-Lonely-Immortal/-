#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
selftest.py —— 用本地假门户验证 tools/eportal_login.py 的协议逻辑。

运行：python test/selftest.py
"""

import argparse
import io
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, HERE)

import eportal_login as ep          # noqa: E402
from mock_eportal import start      # noqa: E402

FAILURES = []


def check(name, condition, detail=""):
    if condition:
        print("  PASS  %s" % name)
    else:
        print("  FAIL  %s  %s" % (name, detail))
        FAILURES.append(name)


def make_args(base, user="2021000000", password="123456", check=False, debug=False,
              services=False):
    return argparse.Namespace(
        user=user, password=password, service="", conf=None,
        check_url=base + "/generate_204", portal="127.0.0.1", scheme="http",
        check=check, services=services, debug=debug)


def case_parse():
    print("\n[1] 探测 / 解析跳转地址")
    server, base = start()
    try:
        status, headers, body = ep.probe(base + "/generate_204")
        check("未认证时探测返回 302", status == 302, "got %s" % status)
        url = ep.extract_portal_url(status, headers, body)
        check("从 Location 解析出认证页", "/eportal/index.jsp" in url, url)
        host, qs = ep.split_portal_url(url, "127.0.0.1")
        check("host 解析正确", host == base, host)
        check("queryString 含 wlanuserip", "wlanuserip=" in qs)
        check("queryString 含 t=wireless-v2", "t=wireless-v2" in qs)
        check("queryString 保留 & 分隔的多段", qs.count("&") >= 10,
              "%d 段" % qs.count("&"))
        check("已认证判定为 False", not ep.is_online(status, body))
    finally:
        server.shutdown()


def case_wrong_password():
    print("\n[2] 密码错误时应快速失败并给出服务器消息")
    server, base = start()
    try:
        code = ep.run(make_args(base, password="wrong-password"))
        check("返回码为 1", code == 1, "got %s" % code)
        status, _, body = ep.probe(base + "/generate_204")
        check("仍未认证", status == 302, "got %s" % status)
    finally:
        server.shutdown()


def case_success():
    print("\n[3] 正确账号密码 + queryString 在表单（主流程）")
    server, base = start()
    try:
        code = ep.run(make_args(base))
        check("返回码为 0", code == 0, "got %s" % code)
        status, _, body = ep.probe(base + "/generate_204")
        check("探测变为 204", status == 204, "got %s" % status)
        check("is_online 判定为 True", ep.is_online(status, body))
    finally:
        server.shutdown()


def case_passthrough_query_string():
    print("\n[4] 门户把 & 原样还原：queryString 必须完整传给服务器")
    server, base = start()
    try:
        # 假门户要求 form 里的 queryString 含有 wlanuserip、并且是完整未截断的一段
        status, headers, body = ep.probe(base + "/generate_204")
        url = ep.extract_portal_url(status, headers, body)
        host, qs = ep.split_portal_url(url, "127.0.0.1")
        import urllib.parse
        encoded = urllib.parse.urlencode({"queryString": qs})
        check("urlencode 后 & 被编码为 %26", "%26" in encoded, encoded[:80])
        check("编码后没有裸露的 & 截断参数",
              encoded.count("&") == 0, encoded[:80])
    finally:
        server.shutdown()


def case_qs_in_url_variant():
    print("\n[5] 少数门户要求 queryString 放在 URL 上（应回退成功）")
    server, base = start(require_qs_in_url=True)
    try:
        code = ep.run(make_args(base))
        check("返回码为 0", code == 0, "got %s" % code)
        status, _, _ = ep.probe(base + "/generate_204")
        check("探测变为 204", status == 204, "got %s" % status)
    finally:
        server.shutdown()


def case_check_only():
    print("\n[6] --check 只探测不认证")
    server, base = start()
    try:
        code = ep.run(make_args(base, check=True))
        check("返回码为 0", code == 0, "got %s" % code)
        status, _, _ = ep.probe(base + "/generate_204")
        check("没有发生认证", status == 302, "got %s" % status)
    finally:
        server.shutdown()


def case_service_error():
    print("\n[7] 服务代码填错（用户不允许使用本服务）时应立刻停手")
    server, base = start(reject_service=True)
    try:
        code = ep.run(make_args(base))
        check("返回码为 1", code == 1, "got %s" % code)
        _, _, body = ep.http_request(base + "/_state")
        state = json.loads(body)
        check("只发了 1 次登录请求（不会连试 3 种写法）",
              state["login_count"] == 1, "实际 %s" % state["login_count"])
        check("仍未认证", state["authed"] is False)
    finally:
        server.shutdown()


def case_list_services():
    print("\n[8] --services 能列出门户支持的服务代码")
    server, base = start()
    try:
        buffer = io.StringIO()
        stdout = sys.stdout
        sys.stdout = buffer
        try:
            code = ep.run(make_args(base, services=True))
        finally:
            sys.stdout = stdout
        output = buffer.getvalue()
        check("返回码为 0", code == 0, "got %s" % code)
        check("列出 internet", "service=internet" in output, output[-300:])
        check("列出 local", "service=local" in output, output[-300:])
        check("带上界面显示名", "互联网" in output, output[-300:])
    finally:
        server.shutdown()


def main():
    for case in (case_parse, case_wrong_password, case_success,
                 case_passthrough_query_string, case_qs_in_url_variant,
                 case_check_only, case_service_error, case_list_services):
        case()
    print("\n==== 结果: %d 项失败 ====" % len(FAILURES))
    for name in FAILURES:
        print("  - %s" % name)
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
