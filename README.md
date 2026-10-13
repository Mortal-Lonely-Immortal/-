# auto-eportal —— 锐捷 ePortal 校园网自动认证（OpenWrt 版）

仿照 [7Ji/auto-whu](https://github.com/7Ji/auto-whu)（用于武大校园网的 openwrt 自动认证脚本）编写，
但适配的是**新版锐捷 ePortal 门户**，也就是形如：

```
http://211.87.158.84/eportal/index.jsp?wlanuserip=...&wlanacname=...&nasip=...&mac=...
    &t=wireless-v2&url=...&nasid=...&vid=...&port=...&nasportid=...
```

这种认证页（注意 `t=wireless-v2`）。它的登录接口是：

```
POST http://<认证页主机>/eportal/InterFace.do?method=login
Content-Type: application/x-www-form-urlencoded; charset=UTF-8

userId=<账号>&password=<密码>&service=<服务名>&queryString=<认证页 ? 后面的整串>
&operatorPwd=&operatorUserId=&validcode=&passwordEncrypt=false
```

而 auto-whu 用的是老门户的 `/eportal/userV2.do?method=login&param=true&<query>` 接口，
表单字段是 `username` / `pwd`，两者不通用。

本脚本以新接口为主，同时**自动回退**到旧接口，因此新旧门户都能覆盖。

## 和原项目的区别

| | auto-whu | auto-eportal（本项目） |
|---|---|---|
| 登录接口 | `userV2.do`，字段 `username/pwd` | `InterFace.do?method=login`，字段 `userId/password/queryString` |
| 认证页主机 | 写死在脚本里 | 从网关跳转地址**自动识别**（含端口） |
| 在线判断 | `ping baidu.com` | HTTP 探测（能识别"被劫持的 200"）+ ping 兜底 |
| 失败处理 | 连试 5 次 | 先判断服务器返回的消息，密码错就停手，避免把账号试锁 |
| 调试 | 无 | `auto-eportal.sh debug` 一键导出接口原文 |
| 语言 | 有 bash 语法（`[[ ]]`、`let`） | 纯 POSIX sh（OpenWrt 的 BusyBox ash 可直接跑） |

## 目录结构

```
auto-eportal-openwrt/
├── etc/
│   ├── auto-eportal.conf        # 配置：账号、密码、探测地址等
│   └── init.d/auto-eportal      # procd 开机自启脚本
├── usr/sbin/auto-eportal.sh     # 主脚本
├── install.sh                   # 一键安装到 /
├── tools/
│   └── eportal_login.py         # 电脑上用的调试/登录工具（只用 Python 标准库）
└── test/                        # 自测脚本（见文末"验证情况"）
```

## 路由器上的安装步骤

0. 确认网关有约 300KiB 空闲空间。本脚本依赖**完整版 curl 和 grep**（BusyBox 自带的 curl 不支持
   `--data-urlencode`，grep 也可能没有 `-o`）。

1. 让路由器先联网（例如用手机/电脑先认证一次），然后安装依赖：

   ```sh
   opkg update
   opkg install curl grep
   ```

2. **退出 SSH 重新登录**，让新的 curl/grep 生效（OpenWrt 默认是 BusyBox 版本）。

3. 把整个 `auto-eportal-openwrt` 目录上传到路由器 `/tmp`，然后：

   ```sh
   sh /tmp/auto-eportal-openwrt/install.sh
   vi /etc/auto-eportal.conf        # 填账号密码
   ```

4. 先手工试一次：

   ```sh
   auto-eportal.sh once             # 未认证就认证一次，然后退出
   auto-eportal.sh debug            # 出问题时看这个
   ```

5. 挂后台并开机自启：

   ```sh
   /etc/init.d/auto-eportal start
   /etc/init.d/auto-eportal enable
   tail -f /tmp/auto-eportal.log    # 看日志
   ```

## 配置项说明（/etc/auto-eportal.conf）

| 配置项 | 说明 |
|---|---|
| `username` / `pwd` | 校园网账号密码，**必填** |
| `portal_host` / `portal_scheme` | 认证页服务器，一般不用改；解析不到跳转地址时才用它 |
| `service` | **服务代码**，不是界面上显示的中文名。见下面「服务名到底填什么」 |
| `check_url` | 判断"是否已认证"的探测地址，必须是 **http**（网关才能劫持它） |
| `poll_interval` | 检测间隔（秒），默认 10 |
| `max_retry` | 一次认证失败后的额外重试次数，默认 5 |

## 命令

| 命令 | 作用 |
|---|---|
| `auto-eportal.sh` | 常驻循环（init.d 用这个） |
| `auto-eportal.sh once` | 检测一次，未认证则认证一次后退出 |
| `auto-eportal.sh login` | 跳过检测直接认证一次 |
| `auto-eportal.sh debug` | 打印探测响应、认证页地址、各接口返回原文 |
| `auto-eportal.sh services` | **列出门户支持的服务代码**（`service` 到底该填什么） |

日志在 `/tmp/auto-eportal.log`。

## 先在电脑上验证（推荐）

路由器上折腾之前，先在同一校园网内的电脑上跑 `tools/eportal_login.py`
（只用 Python 标准库，Windows 也能直接跑），它会打印服务器返回的原文：

```powershell
python tools\eportal_login.py --check                 # 只看当前是否已认证
python tools\eportal_login.py --user 学号 --password 密码 --debug
```

如果这里能成功，路由器上基本就没问题；如果失败，把 `--debug` 的输出贴出来就能定位。

> 本机测试时可以顺便起一个假门户来验证工具本身：
> `python test/mock_eportal.py --port 8080`，然后
> `python tools\eportal_login.py --user 2021000000 --password 123456 --check-url http://127.0.0.1:8080/generate_204`

## 服务名到底填什么

很多门户的 `service` 要填的是**服务代码**，不是页面上显示的中文。

| 你填的 | 门户的回答 | 原因 |
|---|---|---|
| 留空 | `ePortal上有多个服务,服务不能为空` | 门户有多个服务 |
| `互联网`（照抄下拉框文字） | `用户不允许使用本服务!` |
| `internet` | `result: success`  |

先问门户自己：

```sh
auto-eportal.sh services          # 路由器上
python tools/eportal_login.py --services   # 电脑上
```

输出形如：

```
门户支持的服务（service 要填代码，不是界面上显示的中文）：
  service=internet     （界面上叫：互联网）
  service=local        （界面上叫：内网（只能访问校内网络））
```

把 `service=` 后面那个值填进配置即可。原理是门户的 `InterFace.do?method=getServices`
接口返回的 `serviceName`（发给服务器的值）和 `serviceShowName`（给你看的文字）是两回事。

## 常见问题

**1. 返回"验证码错误 / 请输入验证码"**
门户开了图形验证码，纯脚本无法识别，需要在门户后台关闭验证码或改用打码方案，本脚本不处理。

**2. 返回密码相关错误，但密码确实没错**
部分学校的 ePortal 要求密码**加密后**提交（`passwordEncrypt=true`，用门户 JS 里的算法加密）。
本脚本目前按最常见的 `passwordEncrypt=false`（明文）提交。
用 `auto-eportal.sh debug` 或 `eportal_login.py --debug` 看接口原文，如果确实是这个问题，
把返回原文发出来即可补上对应的加密实现。

**3. 一直提示"未能解析出认证页地址"**
说明探测地址没有被网关劫持。确认 `check_url` 是 http 而不是 https，
或者直接看 `auto-eportal.sh debug` 第 1 段的原始响应，把它贴出来。

**4. 有多个服务（校园网/互联网/电信/联通/移动）**
见上面「服务名到底填什么」一节，用 `auto-eportal.sh services` 查代码再填。

**5. 门户是定制页面、GBK 编码，`method=page` 返回空**
正常现象。有的学校是定制模板，服务列表走的不是 `method=page` 而是
`InterFace.do?method=getServices`（本脚本两种都会试）。页面编码是不是 GBK
不影响本脚本——`service` 传的是代码（纯 ASCII），`queryString` 也是纯 ASCII，
中文不需要参与编码。

**6. 日志里出现"认证被拒绝（…服务…）"，脚本停手了**
这是有意设计：服务器在业务层明确拒绝时不再换写法重试，避免把账号试锁。
同时会提示你用 `services` 查服务代码。

## 验证情况

本脚本的开发过程中，已经在真实门户（`211.87.158.84`，锐捷 ePortal 定制模板、
`t=wireless-v2`、GBK 页面、服务代码为 `internet`/`local`）上**认证成功**，
服务器返回 `result: success`。

`test/` 下有四套自测，都不需要真的校园网：

| 测试 | 命令 | 覆盖内容 |
|---|---|---|
| `busybox_check.sh` | `sh test/busybox_check.sh` | BusyBox ash 下 `sh -n` 语法检查 + 用真实 URL 验证跳转解析、queryString 完整性、在线判定、应答解析、服务名提取 |
| `flow_check.sh` | `sh test/flow_check.sh` | 用假 curl 桩验证 `do_login` 控制流：一次成功、业务层拒绝时停手、参数错误回退、旧接口回退 |
| `selftest.py` | `python test/selftest.py` | Python 调试工具对着本地假门户端到端跑通 |
| `curl_check.ps1` | `powershell -File test/curl_check.ps1` | 用真实 curl.exe 验证脚本里每条 curl 命令的参数写法，确认 461 字节的 queryString 不被截断 |

以上四套在开发时全部通过。

## 免责声明

仅用于自己账号的自动登录，请勿用于他人账号或任何绕过计费/认证限制的用途。
