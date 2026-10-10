# 静态事实（不可配置的部分）

> **常量不在这里。** 所有路径、凭据、编译树、容器名、包映射都在配置里：
> `~/.dsh/arcwrt-luci.conf`（模板：`references/workflow.conf.template`）。
> 用 `wf.sh conf` 打印解析结果。
>
> 本文件只保留**配置里没有的静态知识**：推导关系、软链结构、包结构、构建行为、
> 路由器持久性、以及实测踩过的坑。
> 实测时间 2026-09；若 `change-project.sh switch` 切了项目，**必须重新核对**。

## 一、连接与凭据

**值全部来自配置**，下表只说明每个键的用途与连接方式：

| 配置键 | 用途 | 连接方式 |
|---|---|---|
| `ROUTER_HOST` / `ROUTER_USER` / `ROUTER_PASS` | 路由器 SSH | openwrt MCP，**必须先 `connect_router`** |
| `ROUTER_WEB_URL` / `ROUTER_WEB_USER` / `ROUTER_WEB_PASS` | 路由器 Web GUI | chrome_devtools MCP；**`new_page` 新建专用 tab → `select_page` 绑定 pageId**，本会话所有浏览器操作都在该页做 |
| `BUILD_HOST` / `BUILD_USER` / `BUILD_PASS` / `BUILD_PORT` | build server | openwrt_build MCP `ssh_connect` |

> **build server 密码有两份，必须一致**：配置里的 `BUILD_PASS`（建 SSH 会话用）与
> `~/.sync_remote.conf` 的 `SFTP_PASSWORD`（传文件用）。`wf.sh check` 会自动比对，不一致报 WARN。
> `wf.sh conf` 打印时已脱敏（只露头尾）。
>
> 路由器密码改过会在重启后失效（`/etc/shadow` 在 tmpfs overlay 上），见「路由器持久性」。

**工作区主机与路由器、与 build server 均无直连**，一切操作走 MCP。
文件传输靠 `file_read` / `file_write` / `run_command`。

## 二、路径常量与派生关系

**不要在文档里抄路径——读配置。**

```bash
source ~/.dsh/arcwrt-luci.conf
```

### 配置里直接给的

`LOCAL_REPO` · `PROJECT` · `VERSION` · `PATCH_SUBDIR` · `SYNC_TOOL` · `SYNC_SERVER` ·
`BUILD_HOST` · `BUILD_USER` · `BUILD_PASS` · `BUILD_PORT` · `BUILD_BASE` · `OPENWRT_ROOT` · `CONTAINER` ·
`MAKE_JOBS` · `IPK_DIR` · `ROUTER_*` · `PACKAGE_MAP` · `DENY_PACKAGES` · 四个行为开关

### 由配置推导出来的

| 派生值 | 推导方式 |
|---|---|
| `LOCAL_PATCH` | `$LOCAL_REPO/$PROJECT/$VERSION/$PATCH_SUBDIR` |
| 编译真源（远程） | `$OPENWRT_ROOT/feeds/feeds_addon/package/arcadyan-utility/arc_luci/` |
| ipk 产物 | `$OPENWRT_ROOT/$IPK_DIR/<pkg>_<ver>_{all,aarch64}.ipk` |
| 全量固件产物 | `$OPENWRT_ROOT/bin/targets/arcadyan_brcm_6/generic/*squashfs_full_bl_update.pkgtb` |
| 容器入口（备选） | `$BUILD_BASE/sh-docker/docker_run-arcwrt` |

`wf.sh conf` 会把上面这些全部算好并打印。

### 静态事实（配置里没有）

| | |
|---|---|
| 本地 git | branch `fix/gui-bug`，origin `git@10.118.81.210:etisalat/project.git` |
| 容器镜像 | `10.118.81.197:9091/servers/ubuntu18.04:bcmbsp6.3` |
| 目标平台 | `arcadyan_brcm_6/generic`，aarch64 |

> **备选同步路径**（仅本机无法直连 build server 时）：
> 服务器侧仓库 `$BUILD_BASE/project/$PROJECT/$VERSION/project_patch` +
> `~/tools/sync_to_openwrt.sh`，branch `GZ-projects`，origin `git://10.118.81.197/project.git`。
> **两条路径不要混用**，否则两份副本会不一致。

## 三、软链关系（关键）

```
openwrt/feeds/feeds_addon
        └─ symlink → $BASE/feeds_addon                    ← 编译真源

openwrt/package/feeds/feeds_addon/luci-arcadyan
        └─ symlink → ../../../feeds/feeds_addon/package/arcadyan-utility/arc_luci/luci-arcadyan
```

所以 **改了 `$BASE/feeds_addon/...` 就等于改了编译树**，不需要再往 `openwrt/package/` 里拷。

## 四、源码 ↔ 路由器路径映射

| 路由器位置 | PATCH_ROOT 下相对路径 |
|---|---|
| `/usr/lib/lua/luci/view/admin/<page>.htm` | `feeds/feeds_addon/package/arcadyan-utility/arc_luci/luci-arcadyan/luasrc/view/admin/<page>.htm` |
| `/usr/lib/lua/luci/view/admin/cgi/<page>.js` | `.../luci-arcadyan/luasrc/view/admin/cgi/<page>.js` |
| `/usr/lib/lua/luci/model/arc_ssi.lua` | `.../luci-arcadyan/luasrc/model/arc_ssi.lua` |
| `/usr/lib/lua/luci/model/arc_cgi.lua` | `.../luci-arcadyan/luasrc/model/arc_cgi.lua` |
| `/www/lang/en/*.js` | `.../luci-arcadyan/htdocs/lang/en/*.js` |
| `/etc/config/<name>` | `package/base-files/files/etc/uci-project/<name>` |
| `/etc/firewall.<name>` | `package/base-files/files/etc/firewall.<name>` |
| `/etc/hotplug.d/iface/<name>` | `package/base-files/files/etc/hotplug.d/iface/<name>` |

## 五、LuCI 包结构

`feeds_addon/package/arcadyan-utility/arc_luci/`

| 子目录 | 包名 | 说明 |
|---|---|---|
| `luci-arcadyan` | `luci-arcadyan` | **页面主体**：`luasrc/view/admin/*.htm`、`cgi/*.js`、`model/*.lua`、`htdocs/lang/` |
| `luci-arc-common` | `luci-arc-common` | LuCI 公共部分 |
| `luci-app-wifi` | `luci-app-wifi` | WiFi 页面 |
| `luci-libs/lib-luci-arc` | `lib-luci-arc` | Lua 库 |
| `luci-libs/lib-luci-ip` | `lib-luci-ip` | Lua 库 |
| `luci-libs/lib-luci-jsonc` | `lib-luci-jsonc` | Lua 库 |
| `luci-libs/lib-luci-nixio` | `lib-luci-nixio` | Lua 库 |
| `arc_luci_lighttpd` | ⚠️ | **`Build/Compile` 为空**，只装配置/证书/init，改页面别编它 |
| `arc_luci.mk` | — | 被上面各包的 Makefile `include`，定义 install/diet/min 逻辑 |

### `luci-arcadyan` 的构建行为

- `Build/Prepare`：把 `luasrc` `htdocs` `root` `src` 拷进 `$(PKG_BUILD_DIR)`
- `Build/Compile`：`src/Makefile` 存在 → 跑 `create_js_maxnum.sh`，从 `luasrc/model/vendor_define.lua` 抽 `maxNum` 常量生成 `maxnum_define.js`（仅当 `CONFIG_VendorLua_MaxNum_Define_JS=y`）
- `Package/install`：把 `luasrc` → `/usr/lib/luci`、`htdocs` → `/www`、`root` → `/`，按需 `luasrcdiet` / `webjsmin` / `jsmin` / `csstidy`

→ **页面本体不经过编译**，全靠 Prepare 拷贝。所以源文件变了必须 `clean` 才能重拷。

## 六、编译

### 首选：已有容器内直接 make

常驻容器（image `10.118.81.197:9091/servers/ubuntu18.04:bcmbsp6.3`）已把**整个 `$HOME` 和 `OPENWRT_ROOT` 挂载到容器内同路径**：

```
mcp__openwrt_build__docker_make(
  container = "<docker ps 里在跑的 openwrt_* 容器>",
  workDir   = "$OPENWRT_ROOT",
  target    = "package/feeds/feeds_addon/<pkg>/clean package/feeds/feeds_addon/<pkg>/compile",
  jobs      = 16,
  verbose   = true
)
```

### 备选：拉起新容器

```bash
cd $BASE
fix_seq=1 ./sh-docker/docker_run-arcwrt --notty \
  'cd openwrt && make package/feeds/feeds_addon/<pkg>/clean package/feeds/feeds_addon/<pkg>/compile V=s'
```

`fix_seq=1` 对应 `project/PRV36BE349B-ET/bcm-mesh-6.3.0_arcwrt_aarch64/.docker_image` 里的 `image_fix_seq=1`，**不加会卡在交互式选镜像**。

### 产物

`$OPENWRT_ROOT/bin/targets/arcadyan_brcm_6/generic/*.ipk`

### 全量编译（本工作流一般不用）

```bash
cd $BASE
fix_seq=1 ./sh-docker/docker_run-arcwrt --notty './perform.sh all -j16'
```

产物：`$OPENWRT_ROOT/bin/targets/arcadyan_brcm_6/generic/*squashfs_full_bl_update.pkgtb`（几十分钟，仅在动了 C / 内核 / UCI 默认值时才需要）

## 七、同步到编译树

### 主路径：本地 `sync_remote.sh`（SFTP 直传）

```bash
cd /mnt/data/work/et/workspace/et/project          # 必须在仓库根执行
S=/mnt/data/work/tools/sync_file/sync_remote.sh

$S 206 --diff      # 预演：只读，列出将要上传什么
$S 206             # 执行同步（只传已 git add 的文件）
$S 206 --backup    # 仅备份远程文件到本地，不上传
$S 206 --list      # 同步历史
$S 206 --undo      # 撤销最近一次（用本地备份还原远程）
$S 206 --undo=<SID>
$S 206 --restore=<SID>   # 从远程备份恢复到本地
```

**路径映射**：本地 `<LOCAL_REPO>/PRV36BE349B-ET/bcm-mesh-6.3.0_arcwrt_aarch64/project_patch/<相对路径>`
→ 远程 `<OPENWRT_ROOT>/<相对路径>`（自动剥掉 `project_patch/` 前缀）。

实测日志样例（radvd 那次）：

```
本地 /mnt/data/work/et/workspace/et/project/PRV36BE349B-ET/bcm-mesh-6.3.0_arcwrt_aarch64/project_patch/feeds/feeds_addon/package/opensource/radvd/Makefile
远程 $OPENWRT_ROOT/feeds/feeds_addon/package/opensource/radvd/Makefile
备份 /mnt/data/work/et/workspace/et/project/.sync_remote/default/backups/20260911_143632/feeds/feeds_addon/package/opensource/radvd/Makefile
```

**`--diff` 健康输出**（暂存区为空时）：

```
[INFO] Testing connection to zilin_chen@10.118.81.206:22 ...
CONNECTED: pwd
Remote working directory: /home/zilin_chen
========== Remote Diff ==========
Source (git) : /mnt/data/work/et/workspace/et/project
Target       : zilin_chen@10.118.81.206:<OPENWRT_ROOT>
==================================

========== DIFF SUMMARY ==========
Total tracked   : 0
...
```

**`Target` 行的路径必须等于配置里的 `OPENWRT_ROOT`。** 用 `wf.sh conf` 核对——
写死某个树名做判据是错的，树会换。

**注意**：
- 与 `sync_to_openwrt.sh` 一样，**只传已暂存文件**（`git status --porcelain | grep -E '^[MADRC]'`）
- 配置读 `~/.sync_remote.conf`；`SYNC_REMOTE_CONFIG` 可覆盖配置路径
- 依赖 `python3` + `pexpect`（已装 4.9.0）
- 会在仓库内建 `.sync_remote/` 历史目录，建议加进 `.gitignore`

### 备选路径：服务器侧 `sync_to_openwrt.sh`

> 仅在**本机无法直连 build server** 时使用。**两条路径不要混用**，否则两份副本会不一致。

**编译树根必须作为位置参数传**（或走 `OPENWRT_ROOT_ENV`）：

```bash
cd <PATCH_ROOT>
R="$OPENWRT_ROOT"

~/tools/sync_to_openwrt.sh --diff $R    # 预演
~/tools/sync_to_openwrt.sh $R           # 执行
~/tools/sync_to_openwrt.sh --list $R
~/tools/sync_to_openwrt.sh --undo $R
~/tools/sync_to_openwrt.sh --restore=<session_id> $R
```

⚠️ **不能用 `OPENWRT_ROOT=<path>` 环境变量传！** 脚本**第 13 行**有 `OPENWRT_ROOT=""`，在参数解析
之前就**无条件清空**了同名环境变量，随后第 59 行才做 `${OPENWRT_ROOT:-${OPENWRT_ROOT_ENV:-<默认>}}`。
结果：`OPENWRT_ROOT=<path> ./sync_to_openwrt.sh --diff` → 回落到已失效的内置默认值
`~/extra-harddisk/workspace/arcwrt03132/openwrt` → 报 `Target directory does not exist`。
**正确写法**：位置参数 `./sync_to_openwrt.sh --diff <path>`，或 `OPENWRT_ROOT_ENV=<path>`。
（两种写法均已实测通过。）

历史目录：`<PATCH_ROOT>/.sync_openwrt/`（含 `backups/<session_id>/` 与 `sync_<session_id>.log`）

若 `--diff` 输出的 `Target` 显示成 `.../arcwrt03132/openwrt`，说明传参没生效。

## 八、已知的环境坑

| 坑 | 说明 |
|---|---|
| `sync_remote.sh` 不在 PATH | 必须用全路径 `/mnt/data/work/tools/sync_file/sync_remote.sh` 调用 |
| `openwrt_build` MCP 的 `workflow_*` 工具 | 默认 `scriptPath` 指向 `~/workspace/etisalat/docker-select-image/docker_build-select.sh`，**该路径不存在**（`~/workspace` 整个没有）。真实脚本在 `$BASE/../docker_build-select.sh`。**用这些工具必须显式传 `scriptPath`**，或直接用 `docker_make` |
| `sync_to_openwrt.sh` 默认 `OPENWRT_ROOT` | 内置默认已失效（指向不存在的 `arcwrt03132/openwrt`），必须显式传参。仅备选路径涉及 |
| `sync_to_openwrt.sh` **吞掉 `OPENWRT_ROOT` 环境变量** | 脚本第 13 行 `OPENWRT_ROOT=""` 无条件清空它，只有**位置参数**或 `OPENWRT_ROOT_ENV` 有效。见第七节 |
| 本地仓库无 `.gitignore` 覆盖 | `.sync_remote/` 与 `*.bak*` 会显示为未跟踪。建议把 `.sync_remote/` 加入忽略 |
| 服务器侧 `$PATCH_ROOT` 无 `.gitignore` | 会累积 `*.bak.2026*`、`*.bak.arc`、`combined.patch`、`context-jian`、`.sync_openwrt/` 等未跟踪垃圾 |
| `arcwrt-commit` skill 位置信息已过期 | 它仍写"在 build server 的 project_patch 上 commit"，现已在**本地仓库**提交。message 格式仍以它为准 |
| 路由器文件末尾换行 | 路由器文件可能无末尾换行符，本地重建后 `md5sum` 比对（差异常是换行） |
| 语言文件双份 | `/rom`（只读）与 `/www`（可写 overlay），改 `/www` 的生效 |
| `/tmp` 不跨命令持久 | 跨命令需用工作区路径；在路由器上建 sed 脚本用 `cat > /tmp/x.sed <<'EOF'` heredoc |
| 改网络配置会断连 | 改 LAN IP/掩码会重启网络，等 5~10 秒后 `connect_router` 重连 |
