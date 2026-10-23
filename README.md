# openwrt-campus-autologin

OpenWrt 校园网 Web 认证自动登录脚本。让软路由在开机、WAN 掉线、被认证系统踢下线时**全自动重新认证**，无需人工干预，全屋设备无感恢复上网。

适配示例环境（其他同类校园网门户亦可参考）：

| 项目 | 环境 |
|---|---|
| 路由器 | H3C Magic NX30 Pro（ARMv8 / mediatek filogic） |
| 固件 | OpenWrt 25.12.4 r32933 / LuCI |
| 认证系统 | "校园网实名认证系统"（bossWeb 门户，前端 Vue SPA） |
| BRAS | Huawei ME60（`wlanacname=SCITC-BRAS-ME60`） |

## 特性

- **全自动**：掉线后自动重新认证，开机自启 + WAN 口 up 时 hotplug 秒触发 + 看门狗周期兜底
- **免维护**：认证参数（`wlanuserip` / `wlanacname` / `mac` 等）从 BRAS 的 302 重定向中**动态提取**，WAN IP 变化无需改配置
- **轻量**：纯 POSIX shell + curl，无任何第三方依赖，资源占用极低（约 1.5MB 内存）
- **稳健**：登录连续失败自动指数退避（30s → 上限 300s），不会轰击认证服务器；进程崩溃由 procd 自动拉起
- **UCI 配置**：账号密码集中在 `/etc/config/campus-autologin`，可用 LuCI 的"系统-自定义命令"或 SSH 修改

## 工作原理

校园网 BRAS 对**未认证 IP 的 HTTP 流量**做 302 劫持，重定向到认证门户并附带本机的认证参数。本脚本利用这一点反向取参：

```
                  ┌────────────┐
   1. 探测 204    │  看门狗循环  │  每 30s: curl generate_204
   ──────────────>│  (procd)   │  返回 204 → 在线，继续睡
                  └─────┬──────┘  非 204/超时 → 判定离线
                        │
                  2. 再次访问探测地址，从 302 的 Location 中
                     提取 wlanuserip / wlanacname / mac / nasip / userlocation
                        │
                  3. POST http://<portal>/api/portal/webauth
                     Content-Type: application/x-www-form-urlencoded
                     wlanacname=...&wlanuserip=...&mac=...
                     &userId=<账号>&passwd=<密码>&loginMode=password
                        │
                  4. 解析 JSON 响应 {"success":true/false}
                     成功 → 复测 204 确认 → 写 syslog
```

### 认证接口说明（逆向自门户前端 JS）

门户页面是 Vue SPA，真实登录接口藏在前端 API 封装里：

- 前端所有请求统一走 `/api` 前缀 → 真实登录接口为 `POST /api/portal/webauth`
- 表单字段：`userId`（账号）、`passwd`（**明文密码**，前端无加密）、`loginMode=password`、加上 URL 查询串里的 BRAS 参数
- 响应为 JSON：`{"success":bool,"message":"...","result":{...}}`
- **重复认证会被拒绝**（已在线时 POST 返回 `code:500`、空 message）——因此脚本必须先检测在线再登录

> 以上为通用门户 bossWeb 的行为。如果你的学校用的是 Dr.COM、城市热点等其他系统，接口不同，此脚本不能直接使用。

## 安装

前提：OpenWrt 路由器可 SSH（默认 dropbear），LAN 内任一机器执行。

```sh
# 1. 上传整个目录到路由器 (dropbear 无 sftp-server, 需 -O 走传统 scp 协议)
scp -O -r campus-autologin root@192.168.1.1:/tmp/

# 2. 在路由器上执行一键安装
ssh root@192.168.1.1 "sh /tmp/campus-autologin/install.sh"
```

`install.sh` 会自动完成：

1. 复制脚本到 `/usr/bin/campus-autologin.sh`（755）
2. 安装 UCI 配置到 `/etc/config/campus-autologin`（600，**已存在则不覆盖**）
3. 注册 init.d 服务（procd 常驻看门狗）与 hotplug 触发器
4. 检查并安装 curl（兼容 apk / opkg 两种包管理器）
5. 启用开机自启、启动服务、立即试运行一次

装完先改账号密码：

```sh
vi /etc/config/campus-autologin    # 修改 username / password
/etc/init.d/campus-autologin restart
```

## 配置参考

`/etc/config/campus-autologin`：

| 选项 | 默认值 | 说明 |
|---|---|---|
| `username` | （必填） | 认证账号 |
| `password` | （必填） | 认证密码（明文存于路由器本地，文件权限 600） |
| `portal_host` | `10.2.1.27` | 认证服务器地址 |
| `check_url` | `http://connect.rom.miui.com/generate_204` | 在线探测地址，**必须为 HTTP**（HTTPS 无法被 302 劫持），返回 204 即视为在线 |
| `interval` | `30` | 看门狗检测间隔（秒），连续失败自动退避，上限 300 |
| `portal_url` | （空） | 可选兜底：探测地址拿不到重定向时使用的固定认证 URL（IP 变化需手动更新，一般留空） |

## 常用命令

```sh
logread | grep campus-autologin              # 查看登录日志
logread -f | grep campus-autologin           # 实时日志
/usr/bin/campus-autologin.sh --once          # 手动触发一次检测+登录
/etc/init.d/campus-autologin restart         # 重启服务
/etc/init.d/campus-autologin status          # 服务状态
```

正常在线时**不产生任何日志**；只有"离线 → 登录 → 恢复"事件才记录，例如路由器重启后：

```text
campus-autologin: 检测到离线, 尝试登录...
campus-autologin: 登录成功 (user=你的账号)
campus-autologin: 登录后网络已恢复
```

## 文件结构

```
campus-autologin/
├── campus-autologin.sh        # 主脚本: 在线检测 / 参数提取 / 登录 / 看门狗
├── campus-autologin.config    # UCI 配置样例 → /etc/config/campus-autologin
├── campus-autologin.init      # procd init 脚本 → /etc/init.d/campus-autologin
├── campus-autologin.hotplug   # hotplug 触发器 → /etc/hotplug.d/iface/99-campus-autologin
└── install.sh                 # 一键安装 (仅用 cp/chmod, 不依赖 coreutils install)
```

## 故障排查

| 现象 | 原因与处理 |
|---|---|
| 日志出现 `认证失败:` 且 message 为空 | 通常是**重复认证**（该 IP 已在线）被 BRAS 拒绝，脚本下一轮检测会自动确认在线状态，无需处理 |
| `登录失败: 用户名或密码错误` | 检查 `/etc/config/campus-autologin` 中的账号密码 |
| `未收到 portal 重定向` | 当前网络未触发劫持（如 BRAS 用 ICMP 判定在线），或探测地址被缓存；换 `check_url` 或设置 `portal_url` 兜底 |
| 安装时报 `can't open '/etc/rc.common\r'` | 文件带 Windows CRLF 行尾，在路由器执行 `sed -i 's/\r$//'` 修正所有已安装文件后重试（本仓库文件均为 LF） |
| `install: not found` | 固件无 coreutils install 命令，使用本仓库的 install.sh（已改用 cp+chmod） |

## 已验证场景

- ✅ 路由器重启 → 开机后 ~10 秒内自动完成认证（含看门狗与 hotplug 并发触发的重复认证保护）
- ✅ WAN IP 动态变化（每次登录前实时从 302 重定向取参）
- ✅ OpenWrt 25.12（apk 包管理器）安装；兼容旧版 opkg

## 免责声明

本项目仅用于**自动化登录本人已授权账号**的校园网认证，功能等价于在认证页面手动输入账号密码。请遵守所在学校/单位的网络使用规定，勿用于任何未授权场景。密码以明文形式存储在路由器本地（`/etc/config/campus-autologin`，权限 600），请妥善保管路由器 SSH 凭据。

## License

MIT
