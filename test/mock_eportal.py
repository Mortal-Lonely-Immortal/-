#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
mock_eportal.py —— 本地假 ePortal 服务器，用来在没有校园网环境时验证
tools/eportal_login.py（以及路由器脚本）的协议逻辑。

它模仿真实锐捷 ePortal 的行为：
  * 未认证时，任何对 /generate_204 的访问都被 302 到
        /eportal/index.jsp?wlanuserip=...&mac=...&t=wireless-v2&url=...
  * GET  /eportal/index.jsp            -> 200，下发 JSESSIONID
  * GET  /eportal/InterFace.do?method=page -> 返回门户配置 JSON
  * POST /eportal/InterFace.do?method=login -> 校验 userId/password/queryString
  * POST /eportal/userV2.do?method=login    -> 旧版接口
  * 认证成功后，/generate_204 返回 204

用法：python mock_eportal.py [--port 0] [--user 2021000000] [--password 123456]
      加 --require-qs-in-url 可模拟"queryString 必须放在 URL 里"的门户。
"""

import argparse
import json
import re
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = {"authed": False, "user": "", "password": "",
         "require_qs_in_url": False,
         "reject_service": False,
         # 便于测试断言用：记录服务器最后一次实际收到的内容
         "last_query_string": "", "last_path": "", "last_form": {},
         "login_count": 0}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):        # 保持测试输出干净
        pass

    # ---------------------------------------------------------------- helpers
    def _send(self, code, body=b"", ctype="text/plain; charset=utf-8", extra=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _send_json(self, obj):
        self._send(200, json.dumps(obj, ensure_ascii=False),
                   "application/json; charset=utf-8")

    def _portal_url(self):
        host = self.headers.get("Host", "127.0.0.1")
        qs = ("wlanuserip=0123456789abcdef0123456789abcdef"
              "&wlanacname=aabbccddeeff00112233445566778899&ssid="
              "&nasip=00112233445566778899aabbccddeeff&snmpagentip="
              "&mac=deadbeefdeadbeefdeadbeefdeadbeef&t=wireless-v2"
              "&url=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
              "&apmac=&nasid=aabbccddeeff00112233445566778899&vid=0011223344556677"
              "&port=8899aabbccddeeff&nasportid=fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210")
        return "http://%s/eportal/index.jsp?%s" % (host, qs)

    # ------------------------------------------------------------------- GET
    def do_GET(self):
        parsed = urllib.parse.urlsplit(self.path)

        if parsed.path == "/_state":
            self._send_json(STATE)
            return

        if parsed.path == "/generate_204":
            if STATE["authed"]:
                self._send(204)
            else:
                self._send(302, "", extra={"Location": self._portal_url()})
            return

        if parsed.path == "/eportal/index.jsp":
            html = ("<html><script>var qs=window.location.search.substring(1);"
                    "/* 真实门户会在这里提交表单到 InterFace.do?method=login */</script></html>")
            self._send(200, html, "text/html; charset=utf-8",
                       extra={"Set-Cookie": "JSESSIONID=MOCK123; Path=/"})
            return

        if parsed.path == "/eportal/InterFace.do":
            params = urllib.parse.parse_qs(parsed.query)
            if params.get("method", [""])[0] == "page":
                self._send_json({
                    "service": ["校园网"],
                    "serviceJson": ('[{"aceNotShow":"false","serviceName":"internet",'
                                    '"serviceShowName":"互联网"},'
                                    '{"aceNotShow":"false","serviceName":"local",'
                                    '"serviceShowName":"内网（只能访问校内网络）"}]'),
                    "validCodeUrl": "",
                    "passwordEncrypt": False,
                })
                return
            if params.get("method", [""])[0] == "logout":
                STATE["authed"] = False
                self._send_json({"result": "success"})
                return
            self._send(404, "not found")
            return

        self._send(404, "not found")

    # ------------------------------------------------------------------ POST
    def do_POST(self):
        parsed = urllib.parse.urlsplit(self.path)
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode("utf-8", "replace")
        form = {k: v[0] for k, v in
                urllib.parse.parse_qs(raw, keep_blank_values=True).items()}
        url_params = {k: v[0] for k, v in
                      urllib.parse.parse_qs(parsed.query, keep_blank_values=True).items()}

        if parsed.path == "/eportal/InterFace.do" and url_params.get("method") == "login":
            query_string = form.get("queryString", "")
            if STATE["require_qs_in_url"]:
                query_string = parsed.query
            STATE["last_query_string"] = query_string
            STATE["last_form"] = form
            STATE["last_path"] = self.path
            STATE["login_count"] += 1
            # 真实门户在参数不全时给的是"参数错误"，而不是"密码错误"
            if "wlanuserip=" not in query_string:
                self._send_json({"result": "fail", "message": "参数错误",
                                 "userIndex": ""})
                return
            if STATE["reject_service"]:
                self._send_json({"result": "fail", "message": "用户不允许使用本服务!",
                                 "userIndex": ""})
                return
            ok = (form.get("userId") == STATE["user"]
                  and form.get("password") == STATE["password"])
            if ok:
                STATE["authed"] = True
                self._send_json({"userIndex": "1234567890", "result": "success",
                                 "message": "", "keepaliveInterval": 60})
            else:
                self._send_json({"result": "fail", "message": "用户名或密码错误",
                                 "userIndex": ""})
            return

        if parsed.path == "/eportal/userV2.do" and url_params.get("method") == "login":
            if "wlanuserip=" not in parsed.query:
                self._send_json({"result": "fail", "msg": "参数错误"})
                return
            ok = (form.get("username") == STATE["user"]
                  and form.get("pwd") == STATE["password"])
            if ok:
                STATE["authed"] = True
                self._send_json({"result": "success", "msg": "认证成功"})
            else:
                self._send_json({"result": "fail", "msg": "账号或密码错误"})
            return

        self._send(404, "not found")


def start(port=0, user="2021000000", password="123456", require_qs_in_url=False,
          reject_service=False):
    """启动假门户，返回 (server, base_url)。port=0 表示随机端口。"""
    STATE["authed"] = False
    STATE["user"] = user
    STATE["password"] = password
    STATE["require_qs_in_url"] = require_qs_in_url
    STATE["reject_service"] = reject_service
    STATE["last_query_string"] = ""
    STATE["last_path"] = ""
    STATE["last_form"] = {}
    STATE["login_count"] = 0
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, "http://127.0.0.1:%d" % server.server_address[1]


def main():
    parser = argparse.ArgumentParser(description="本地假 ePortal 服务器")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--user", default="2021000000")
    parser.add_argument("--password", default="123456")
    parser.add_argument("--require-qs-in-url", action="store_true")
    args = parser.parse_args()

    server, base = start(args.port, args.user, args.password, args.require_qs_in_url)
    print("假 ePortal 已启动: %s" % base)
    print("  check_url : %s/generate_204" % base)
    print("  账号/密码 : %s / %s" % (args.user, args.password))
    print("按 Ctrl+C 退出")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
