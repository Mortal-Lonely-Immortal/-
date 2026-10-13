#!/bin/sh
# 把本目录里的文件安装到 /，然后在路由器上执行：
#   sh /tmp/auto-eportal-openwrt/install.sh
set -e

SRC="$(cd "$(dirname "$0")" && pwd)"

mkdir -p /etc/init.d /usr/sbin

if [ -f /etc/auto-eportal.conf ]; then
	echo "保留已有配置 /etc/auto-eportal.conf"
else
	cp "$SRC/etc/auto-eportal.conf" /etc/auto-eportal.conf
	echo "已生成 /etc/auto-eportal.conf，请修改其中的账号密码"
fi

cp "$SRC/usr/sbin/auto-eportal.sh" /usr/sbin/auto-eportal.sh
cp "$SRC/etc/init.d/auto-eportal" /etc/init.d/auto-eportal
chmod 755 /usr/sbin/auto-eportal.sh /etc/init.d/auto-eportal

echo "安装完成。下一步："
echo "  1) vi /etc/auto-eportal.conf   # 填写账号密码"
echo "  2) auto-eportal.sh debug       # 确认接口能通（可选）"
echo "  3) /etc/init.d/auto-eportal start"
echo "  4) /etc/init.d/auto-eportal enable"
