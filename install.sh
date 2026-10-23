#!/bin/sh
# install.sh - 在 OpenWrt 路由器上执行, 安装 campus-autologin
# 用法: 将整个目录传到路由器后, sh install.sh
#   scp -r campus-autologin root@<路由器IP>:/tmp/
#   ssh root@<路由器IP> "sh /tmp/campus-autologin/install.sh"

set -e

SRC="$(cd "$(dirname "$0")" && pwd)"

echo ">>> 安装文件..."
cp "$SRC/campus-autologin.sh" /usr/bin/campus-autologin.sh
chmod 755 /usr/bin/campus-autologin.sh
if [ -f /etc/config/campus-autologin ]; then
	echo "    已存在配置文件, 保留 /etc/config/campus-autologin 不覆盖"
else
	cp "$SRC/campus-autologin.config" /etc/config/campus-autologin
	chmod 600 /etc/config/campus-autologin
fi
cp "$SRC/campus-autologin.init" /etc/init.d/campus-autologin
chmod 755 /etc/init.d/campus-autologin
cp "$SRC/campus-autologin.hotplug" /etc/hotplug.d/iface/99-campus-autologin
chmod 755 /etc/hotplug.d/iface/99-campus-autologin

echo ">>> 检查 curl 依赖..."
if ! command -v curl >/dev/null 2>&1; then
	if command -v apk >/dev/null 2>&1; then
		apk add curl
	else
		opkg update
		opkg install curl
	fi
fi

echo ">>> 启用并启动服务..."
/etc/init.d/campus-autologin enable
/etc/init.d/campus-autologin restart

echo ">>> 立即验证一次..."
/usr/bin/campus-autologin.sh --once || true

echo
echo "安装完成。常用命令:"
echo "  查看日志:   logread | grep campus-autologin"
echo "  实时日志:   logread -f | grep campus-autologin"
echo "  手动登录:   /usr/bin/campus-autologin.sh --once"
echo "  重启服务:   /etc/init.d/campus-autologin restart"
echo "  修改配置:   vi /etc/config/campus-autologin"
