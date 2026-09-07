# ugreen-nas-leds

面向 **Debian 系宿主机** 的绿联 DX / DXP 前面板 LED 一键安装包。  
针对 **UGREEN DXP4800 + Proxmox VE 8（Debian 12）** 验证路径编写，也可用于同协议的其它 DX/DXP 机型。

这是一个**独立仓库**，不是 GitHub fork。协议、内核模块、CLI 和监控脚本源码来自 [miskcoo/ugreen_leds_controller](https://github.com/miskcoo/ugreen_leds_controller)（MIT），本仓库补上 Debian / PVE 的探测、DKMS 和 systemd 封装。

> 必须装在 **PVE / Debian 物理机** 上。装进虚拟机或 LXC 看不到 I2C 总线，灯不会亮。

## 支持什么

| 项目 | 说明 |
|------|------|
| 机型 | DXP4800 主目标；同协议机型（DX4600 Pro、DXP2800、DXP6800 Pro 等）一般也能用 |
| 系统 | Proxmox VE 8（Debian 12）、Debian 12/13、其它 Debian 系裸机 |
| 功能 | 电源灯、网口灯、硬盘位活动灯（颜色 / 闪烁 / 待机变色） |
| 安装方式 | 一条 `install.sh`：装依赖、编 DKMS、探测 `0x3a`、启用服务 |

官方 UGOS 换掉之后，DXP 系列会流水灯乱闪，DX 系列常常只剩电源灯。本驱动通过 SMBus I801 上的 `0x3a` MCU（Holtek HT32）接管这些灯。

## 一键安装（PVE 8 / Debian）

在 **宿主机** root shell 里：

```bash
apt-get update
apt-get install -y git
git clone https://github.com/Cunhe/ugreen-nas-leds.git
cd ugreen-nas-leds
sudo bash install.sh
```

脚本会：

1. 拒绝容器 / 非 root
2. 安装 `dkms`、编译工具、`i2c-tools`、`smartmontools`
3. 按发行版装内核头文件  
   - PVE：`proxmox-headers-$(uname -r)`  
   - Debian：`linux-headers-$(uname -r)`
4. 确认 I801 总线上存在 `0x3a`，没有就停，避免装一套空模块
5. DKMS 安装 `led-ugreen`
6. 编译 `ugreen_leds_cli` 和可选的磁盘辅助程序
7. 写入 `/etc/ugreen-leds.conf`、modules-load、systemd
8. 探测并启用 `ugreen-probe-leds` / `ugreen-diskiomon` / `ugreen-power-led` / `ugreen-netdevmon@NIC`

常用覆盖：

```bash
sudo NETIF=enp2s0 bash install.sh
sudo MAPPING_METHOD=serial bash install.sh
sudo bash install.sh --status
sudo bash uninstall.sh
```

## 装完检查

```bash
ugreen-leds-status
ls /sys/class/leds
ugreen-detect-disks ata
journalctl -u ugreen-probe-leds -u ugreen-diskiomon -u 'ugreen-netdevmon@*' -f
```

手动点灯（**先停服务，并卸载模块**，否则和 CLI 抢 I2C）：

```bash
systemctl stop ugreen-diskiomon ugreen-power-led 'ugreen-netdevmon@*'
modprobe -r led-ugreen
ugreen_leds_cli all -status
ugreen_leds_cli power -color 0 0 255 -on
```

日常使用走 sysfs + systemd，不要和 CLI 同时开。

## 盘位对不上

`/dev/sdX` 重启会变，不要用它当映射。`/etc/ugreen-leds.conf` 里：

```bash
MAPPING_METHOD=ata      # 默认，接近 UGOS
# MAPPING_METHOD=hctl   # USB 盘插着时容易乱
# MAPPING_METHOD=serial # 最稳，按槽位填序列号
# DISK_SERIAL="SN_BAY1 SN_BAY2 SN_BAY3 SN_BAY4"
```

DXP4800 是 4 盘位。改完：

```bash
systemctl restart ugreen-diskiomon
```

对照方法：对某一颗盘打流量，看哪一盏灯闪。

```bash
dd if=/dev/sdX of=/dev/null bs=1M count=200 status=progress
```

## PVE 8 注意

- 装在 **NODE** 上，不要装在 VM 里。
- 内核头文件包名是 `proxmox-headers-$(uname -r)`。若 apt 找不到，先在节点上启用 `pve-no-subscription` 源。
- PVE 网桥 `vmbr0` 下面才是物理网卡。安装脚本默认绑 **处于 up 的物理网卡**，不是桥。可用 `NETIF=` 指定。
- 内核升级后 DKMS 应自动重编。若灯灭了：`dkms status`，再 `sudo bash install.sh`。
- ZFS 盘故障变色：把 `/etc/ugreen-leds.conf` 里 `CHECK_ZPOOL=true`。

## 目录

```
install.sh / uninstall.sh   一键安装与卸载
kmod/                       led-ugreen 内核模块 + dkms.conf
cli/                        ugreen_leds_cli
scripts/                    监控脚本、默认配置、systemd
```

## 协议摘要

- 总线：SMBus I801
- 地址：`0x3a`
- LED：`0=power` `1=netdev` `2+=diskN`
- 读：`0x81+id` 11 字节；写：12 字节块，成功位在 `0x80`

细节见上游 README 与 [这篇中文博客](https://blog.miskcoo.com/2024/05/ugreen-dx4600-pro-led-controller)。

DXP4800 GT / iDX6011 部分机器需要 SMBus block-write 变体，本仓库当前跟踪的是上游 master 的传统协议。这些实验机型请先看上游 `v0.4-beta`。

## 许可

MIT。上游版权归 Yuhao Zhou。本仓库只做 Debian/PVE 封装与安装器。见 `LICENSE` 与 `NOTICE`。
