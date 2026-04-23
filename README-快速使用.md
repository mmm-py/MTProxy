# MTProxy 快速使用

## 仓库与 GitHub

- 代码仓库: [https://github.com/mmm-py/MTProxy](https://github.com/mmm-py/MTProxy)

**首次在本机把代码推上去**（在仓库根目录、已 `git init` 且已 `commit` 时）:

```bash
git branch -M main
git remote add origin https://github.com/mmm-py/MTProxy.git
# 若已添加过 origin，可改用: git remote set-url origin https://github.com/mmm-py/MTProxy.git
git push -u origin main
```

需已登录 GitHub（HTTPS 会提示账号/令牌，或改用 SSH：`git@github.com:mmm-py/MTProxy.git`）。

**直链**（`main` 分支下安装脚本，用于服务器下载）:

`https://raw.githubusercontent.com/mmm-py/MTProxy/main/install_mtproxy.sh`

## 服务器上一键下载并运行

本脚本是**交互式**且**必须**在真实终端里跑，**不要**用 `curl ... | bash`（无 TTY 会报错退出）。

在 SSH 里执行（一行，下载 → 可执行 → root 跑安装）:

```bash
curl -fsSL 'https://raw.githubusercontent.com/mmm-py/MTProxy/main/install_mtproxy.sh' -o install_mtproxy.sh && chmod +x install_mtproxy.sh && sudo ./install_mtproxy.sh
```

首次建议先 `less install_mtproxy.sh` 看一遍再执行（任意远程脚本都建议如此）。

## 生成的文件

- `install_mtproxy.sh`: 交互式一键安装/更新并启动 MTProxy
- `uninstall_mtproxy.sh`: 一键卸载 MTProxy（默认服务名 `mtproxy`，若安装时改过服务名请手动调整）

## 安装步骤（服务器执行）

1. 在**真实终端**中执行（需要交互输入，不支持管道非 TTY）:

```bash
chmod +x install_mtproxy.sh uninstall_mtproxy.sh
sudo ./install_mtproxy.sh
```

2. 按提示操作。非交互阶段（`apt` / `git` / `make` / `curl` / `certbot` 等）**默认不在终端刷屏**，只显示 **百分比进度条**；详细输出写入 `/tmp/mtproxy_nbzai_install.log`，失败时会自动 `tail` 尾部日志。脚本会：

- 自动检测公网 IPv4（失败时可手填）
- 询问 **代理显示名称**（写入 `systemd` 的 `Description`，并在安装摘要里打印；回车则与 **systemd 服务名** 相同）
- 询问是否在导入链接里使用**绑定域名**（`server=` 字段）
- 若绑定域名且选择申请证书：使用 **certbot standalone** 为域名申请 Let's Encrypt（需本机 **80 端口空闲**；证书由 ACME 签发，**MTProxy 进程本身不加载该证书**，仅满足「域名 + 证书」需求或供同机 Nginx 等使用）
- `SECRET` / `TAG` 直接回车为**随机生成**（32 位 hex）
- 安装结束输出 `https://t.me/proxy` 与 `tg://proxy` 两种链接

## 验证运行状态

安装时若 systemd 服务名为 `mtproxy`：

```bash
sudo systemctl status mtproxy --no-pager -l
sudo journalctl -u mtproxy -f
```

若安装时自定义了服务名，将 `mtproxy` 换成你的服务名。

## 客户端导入链接格式

```text
https://t.me/proxy?server=<主机/IP>&port=<PORT>&secret=<SECRET>
tg://proxy?server=<主机/IP>&port=<PORT>&secret=<SECRET>
```

`MODE=tls` 时，脚本会自动生成 TLS secret（`ee + SECRET + 伪装域名 hex`），输出的链接可直接导入 Telegram。

## 抗封建议（TLS + 伪装域名）

- 推荐 `PORT=443`，`MODE=tls`
- `TLS_DOMAIN`（伪装）使用常见 HTTPS 站点域名
- 导入链接里的 `server=` 若用自有域名，请用 **DNS A 记录直连** 指向本机，不要套普通七层 CDN

## 已知兼容性说明

- 官方 MTProxy 在部分系统会因 PID 大于 `65535` 启动失败（`init_common_PID` 断言）
- 当前脚本会自动写入 `kernel.pid_max = 65535` 并尝试重置 `ns_last_pid`，用于规避该问题

## 卸载

```bash
sudo ./uninstall_mtproxy.sh
```
