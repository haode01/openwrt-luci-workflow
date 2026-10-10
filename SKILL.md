---
name: arcwrt-luci-workflow
description: Arcadyan/Etisalat ArcWrt 路由器 LuCI 厂商 Web 管理界面改动的端到端工作流。当需求涉及修改路由器 Web GUI（页面字段、表格列、配置项、语言文件、按钮行为、"后台无配置需造虚拟假配置"等）时使用。所有环境常量来自静态配置文件 ~/.dsh/arcwrt-luci.conf（本地仓库、同步工具、编译树、编译容器、ipk 产物目录、包路径映射、路由器凭据），skill 不探测环境、只读配置，用 scripts/wf.sh 解析与自检。串起「浏览器实测 → 定位实现 → 改运行态验证 → 本地源码改动 → sync_file 同步编译树 → 单包编译验证 → 产物回灌设备实测 → 恢复现场 → AI review → 本地仓库 patch commit」全链路，内部分工编排 router-webui-debug 与 arcwrt-commit 两个基础 skill。
---

# ArcWrt LuCI 改动端到端工作流

把「在路由器上调试 Web 界面」到「把改动提交为固件 patch」串成一条带检查点的流水线。

## 适用范围

**只做 LuCI / 厂商 Web GUI**，即 `feeds_addon/package/arcadyan-utility/arc_luci/` 下的：

`luci-arcadyan` · `luci-arc-common` · `luci-app-wifi` · `luci-libs/lib-luci-*`

**不适用**：datamodel、tr69、内核、C 代码、板级配置。那些走各自流程，**不要硬套本工作流**。

## 配置（唯一事实来源）

**所有环境常量都来自一个静态配置文件。skill 不探测环境、不推断路径——只读配置。**

| | 路径 |
|---|---|
| 实例配置（**你自己维护**） | `~/.dsh/arcwrt-luci.conf` |
| 配置模板 | `~/.dsh/skills/arcwrt-luci-workflow/references/workflow.conf.template` |
| 覆盖路径 | `export ARCRWT_CONF=/别的路径.conf` |
| 解析工具 | `~/.dsh/skills/arcwrt-luci-workflow/scripts/wf.sh` |

### 第一次使用

若 `~/.dsh/arcwrt-luci.conf` 不存在，复制模板并改成你的值：

```bash
mkdir -p ~/.dsh
cp ~/.dsh/skills/arcwrt-luci-workflow/references/workflow.conf.template ~/.dsh/arcwrt-luci.conf
# 编辑 ~/.dsh/arcwrt-luci.conf 后自检
~/.dsh/skills/arcwrt-luci-workflow/scripts/wf.sh check
```

### 四个命令替代一切探测

```bash
wf.sh conf             # 打印解析后的全部参数 —— 开工参数卡
wf.sh check            # 本地自检 + 输出需在 build server 上跑的校验命令
wf.sh pkg <改动文件>    # 改动文件 → make target（含禁用包防呆）
wf.sh targets          # 打印包路径映射表
```

（`wf.sh` 全路径 `~/.dsh/skills/arcwrt-luci-workflow/scripts/wf.sh`）

### 配置里有什么

本地仓库与项目 / 同步工具与别名 / build server / **编译树 `OPENWRT_ROOT`** /
**编译容器 `CONTAINER`** / ipk 产物目录 / 路由器凭据与 Web 地址 /
`PACKAGE_MAP` 包路径映射 / `DENY_PACKAGES` 防呆名单 / 四个行为开关

> ⚠️ **两个最易漂移的键：`OPENWRT_ROOT` 与 `CONTAINER`。**
> 换编译树时**必须同时改这两个**，否则会命中陷阱 4 的静默错配——
> sync 把改动送进新树、容器却留在旧树，编译日志全绿但产物来自上一棵树。
> 改完用 `wf.sh conf` 复核。

> 配置是**唯一事实来源**：文档里出现的路径若与配置冲突，以配置为准。

## 与两个基础 skill 的分工

| 环节 | 谁负责 |
|---|---|
| 复现定位、改运行态实测、恢复现场 | `router-webui-debug`（细节看它） |
| patch commit 与 message 规范 | `arcwrt-commit`（细节看它） |
| **源码对账、包路径判定、编译验证** | **本工作流新增**——原两个 skill 都没覆盖，这是最容易出错的一段 |

本文件只负责**顺序、检查点、以及这段新增链路**。需要基础 skill 的细节时用 `skill` 工具加载它们。

## 核心链路（原流程缺失的一段）

```
本机 LOCAL_REPO = /mnt/data/work/et/workspace/et/project        ← 真源就在本地
  PRV36BE349B-ET/bcm-mesh-6.3.0_arcwrt_aarch64/project_patch/
      feeds/feeds_addon/package/arcadyan-utility/arc_luci/<pkg>/
   ↑ 直接编辑这里（branch fix/gui-bug）
   │
   │  ① 在仓库根 git add <仅本次改动文件>
   │  ② sync_remote.sh 206    ← SFTP 只传「已暂存」的文件，自动剥掉 project_patch/ 前缀
   ▼
build server  <OPENWRT_ROOT>/feeds/feeds_addon/package/arcadyan-utility/arc_luci/<pkg>/
   ↑ 这是编译真源；openwrt/feeds/feeds_addon 是指向 $BASE/feeds_addon 的软链
   ↑ openwrt/package/feeds/feeds_addon/<pkg> 同样软链到此处
   │
   │  ③ make package/feeds/feeds_addon/<pkg>/{clean,compile}
   ▼
<pkg>.ipk
   │
   │  ④ 从 .ipk 解出本次改动文件 → scp 回路由器覆盖运行态 → 门 2.5 实测
   ▼
路由器运行态（此时设备上跑的，就是将来刷机会装进去的那份文件）
```

**本地一跳直达编译树**，不再经过服务器侧的 `project_patch` 中转。

## 四个必知陷阱

### 陷阱 1：同步工具只传 `git add` 过的文件

`sync_remote.sh`（以及备选的 `sync_to_openwrt.sh`）内部都是
`git status --porcelain | grep -E '^[MADRC]'`——**只看索引列**：

| git status 状态 | 是否被同步 |
|---|---|
| `M  file` 已 add | ✅ 同步 |
| ` M file` 改了没 add | ❌ **跳过** |
| `?? file` 未跟踪 | ❌ 跳过 |

**只改不 add ＝ 编译树没变 ＝ 白编译，还会误判成代码问题。**

反过来这条限制可以为我所用：**`git add` 的集合 ＝ 本次改动清单 ＝ 编译范围 ＝ commit 范围**，一个动作统一三处，天然消除"漏文件"和"带进无关文件"两类事故。

### 陷阱 2：改 `.htm` / `.js` / `.lua` 必须 `clean` 再 `compile`

- 页面本体靠 `Build/Prepare` 拷贝 + `Package/install` 打包，`compile` **不重拷**
- `.prepared_<hash>` stamp 只跟 PKG_VERSION/RELEASE 有关，**源文件内容变化不会让它失效**
- `Build/Compile` 实际只跑 `src/Makefile` 生成 `maxnum_define.js`

→ 不 `clean` 直接 `compile`，**编出来的还是旧页面**。永远用 `{clean,compile}` 连写。

### 陷阱 3：不要编 `arc_luci_lighttpd`

它名字最像，但 `Build/Compile` 是**空的**，只装 `server.pem` / `lighttpd.config` / init 脚本。改页面编它等于没编。

### 陷阱 4：在跑的容器 ≠ 你的编译树

配置里的 `OPENWRT_ROOT` 与 `CONTAINER` **必须指向同一棵树**。这两项最容易漂移，
换树时务必成对修改，改完 `wf.sh conf` 复核。

`docker ps` 里那几个 `openwrt_*` 容器，挂的很可能是**上一代编译树**。2026-09-14 实测到的漂移现场：

| 编译树 | 状态 | 运行中容器挂载 |
|---|---|---|
| `.../docker_build_ng/arcwrt/openwrt` | 已停用 | ✅ 两个容器挂的都是它 |
| `.../docker_build_ng/arcwrt0911/openwrt` | **当时活跃** | ❌ 没有容器挂它 |

而同步目标已切到新树。于是 sync 把改动送进新树、容器却留在旧树——
**直接 `docker_make` 就是白编译，且日志、退出码一切正常，极难发现。**

> 上表是**历史证据**，不是当前值。当前值一律看配置：`OPENWRT_ROOT` / `CONTAINER`。

一次自查就能排掉：

```bash
docker exec <container> md5sum \
  <OPENWRT_ROOT>/feeds/feeds_addon/package/arcadyan-utility/arc_luci/<pkg>/<改动文件>
# 与本地源码 md5 比对；不一致 = 树选错了，立刻停
```

> **好消息**：这些容器把整个 `/home/zilin_chen` 挂进去了（`/home/zilin_chen => /home/zilin_chen`），
> 所以**不必新起容器**——`docker_make` 的 `workDir` 直接指向配置里的 `OPENWRT_ROOT` 即可。
>
> 判断哪棵树是活的：看 `bin/targets/<target>/<subtarget>/*.pkgtb` 的时间戳，最新那棵才是。

## 路由器持久性（决定备份与恢复策略）

`192.168.1.1`（eLife Connect 5001，OpenWrt 23.05.3，`arcadyan_brcm_6/generic` aarch64）实测挂载：

| 挂载点 | 设备 / 类型 | 重启后 |
|---|---|---|
| `/rom` | `/dev/root`，squashfs **ro** | 固件本体，不可改 |
| `/`（含 `/www`、`/usr/lib/lua/luci`、`/etc/shadow`） | overlayfs，`upperdir=/tmp/root/root`，**tmpfs** | ⚠️ **改动丢失，还原出厂** |
| `/tmp` | tmpfs | 丢失 |
| `/etc/config`（UCI） | `/dev/loop0`，ext4 | ✅ **持久保留** |
| `/data` | `/dev/flash-data`，ext4 | ✅ 持久保留 |

**两个直接后果：**

1. **阶段 2 改的 LuCI 页面文件是"临时"的**——重启即还原出厂。运行态改动不会永久污染设备；
   但仍必须备份与恢复：同一会话内要反复对比改动前后，且恢复现场属于交付规范。
2. **UCI 改动是持久的**——`/etc/config` 挂在 loop0 ext4 上，**跨重启保留**。
   所以阶段 5 的 UCI 恢复**不是可选项**：漏恢复会让设备带着测试配置继续跑。

> 这也解释了为什么路由器 SSH 密码会"自己变回去"：`/etc/shadow` 在 `/`（tmpfs overlay）上，
> 改过的密码重启即失效，回到固件默认。**文档以固件默认值为准**（2026-09-11 实测）。

## 包路径映射（来自配置，不靠猜）

包路径由配置的 `PACKAGE_MAP` 决定。**不要手写、不要推断、不要翻目录**：

```bash
wf.sh pkg <改动文件路径>    # → make target
wf.sh targets              # 完整映射表
```

`pkg` 接受绝对路径、仓库相对路径、带 `project_patch/` 前缀的路径，自动归一化并**最长前缀匹配**。

配置里已含 `luci-arcadyan` / `luci-arc-common` / `luci-app-wifi` / `lib-luci-{arc,ip,jsonc,nixio}` / `base-files`。
新增包只需在配置的 `PACKAGE_MAP` 加一行。

`arc_luci_lighttpd` 列在 `DENY_PACKAGES` 里——命中会**直接报错**并说明它的 `Build/Compile` 是空的。

**阶段 4 仍要把 `wf.sh pkg` 的结果给用户确认后再编译，不要自作主张。**

---

# 流程（7 阶段 + AI review · 6 道门）

## 阶段 0 · 锚定（读配置 + 建连接）

**不探测环境——直接读配置。**

```bash
S=~/.dsh/skills/arcwrt-luci-workflow/scripts/wf.sh
$S conf      # 参数卡：后续所有命令都用这里的值
$S check     # 本地自检；末尾会输出需在 build server 上跑的校验命令
```

`check` 验证：必填项齐全 / 本地仓库是 git / 本地源码在 / 同步工具可执行 /
暂存区是否为空（由 `REQUIRE_CLEAN_INDEX` 控制）。**任一不过就地停下报告，不要往下跑。**

然后**并行**建立三条连接，参数全部取自配置：

- `mcp__openwrt__connect_router` ← `ROUTER_HOST` / `ROUTER_USER` / `ROUTER_PASS`
- 浏览器连路由器 GUI ← `ROUTER_WEB_URL` / `ROUTER_WEB_USER` / `ROUTER_WEB_PASS`（**必须先新建专用页面并绑定，见下**）
- `mcp__openwrt_build__ssh_connect` ← `BUILD_HOST` / `BUILD_USER` / `BUILD_PASS`

### 浏览器连接：每次必须新建专用页面并绑定

浏览器工具只作用于「当前选中页」。若直接复用已有 tab，后续操作会漂到旧/其它页面。
**每次阶段 0 都新建一个专用页面，并把本会话全部浏览器操作一直绑定到它（pageId）。**

1. `new_page(url = ROUTER_WEB_URL)` **新建专用 tab** → 立即记下返回的 `pageId`
2. `select_page(pageId)` 把它设为当前选中页 —— **这一步就是「绑定」的关键**
3. 登录：填 `ROUTER_WEB_USER` / `ROUTER_WEB_PASS` 提交，进入操作界面
4. **绑定贯穿整个会话**：之后每一次浏览器操作（导航 / `evaluate_script` 读 DOM /
   reload 强刷 / `take_screenshot` 等）都只做在这个 `pageId` 上；操作前若不确定当前选中页，
   先 `select_page(pageId)` 再操作。**绝不**让后续步骤发生在别的 tab 上。

（`list_pages` 可用来核对该 `pageId`，只读。）

最后在 build server 上跑 `check` 给出的三条命令。**重点是第三条**：

```
容器看到的树  ==  你同步的树 ?
```

（陷阱 4 的唯一防线，编译前必做。`VERIFY_CONTAINER_TREE=0` 可关，不建议。）

若暂存区**已有内容**：先报警并让用户决定是提交掉还是 `git reset` 清空，**绝不在脏暂存区上叠加本次改动**。

产出：**本次会话参数卡**（直接来自 `wf.sh conf`）。

## 阶段 1 · 复现与定位

加载 `router-webui-debug` 按其方法执行，要点：

1. 浏览器登录 → 导航到目标菜单 → **`evaluate_script` 读真实 DOM**（字段 disabled 状态、值、表格内容），**不要只信截图**
2. 定位实现链：`menu.lua`（`.htm` → template 映射）→ 前端 `.htm` → `cgi/*.js` 配置映射 → `arc_ssi.lua` / `arc_cgi.lua` 后端 → UCI 配置
3. 记录现状证据

产出：**文件链**（页面 → 模板 → CGI → 后端函数 → UCI 配置项）。

## 阶段 2 · 改运行态并实测

在路由器上直接改 `/usr/lib/lua/luci/view/admin/` 下对应文件。

**进入本阶段第一步固定是备份，不可跳过：**

```bash
cp <file> <file>.bak.$(date +%Y%m%d%H%M%S)
md5sum <file>
```

改动后浏览器强制刷新（`navigate_page reload` + `ignoreCache: true`）实测。

> 页面文件在 tmpfs overlay 上，**重启会还原出厂**——备份仍必须做，因为同一会话内要反复
> 对比改动前后。但 **UCI 改动是持久的**，收尾必须恢复（见「路由器持久性」一节）。

**逐文件登记改动台账**（收尾靠它销项）：

| 文件 | 原 md5 | 新 md5 | 路由器备份路径 | 同步的源码路径 |
|---|---|---|---|---|

## 🚪 门 1 · 效果确认

DOM 实测通过才继续。**不通过 → 回阶段 1**，不要带着未验证的改动去动源码。

## 阶段 3 · 源码改动与同步（原流程缺失环节）

**真源在本地，不在服务器。** `LOCAL_REPO` / `LOCAL_PATCH` 来自配置
（`wf.sh conf` 可直接打印），命令块统一先 `source` 配置：

1. 在**本地** `$LOCAL_PATCH` 下按对应位置改动（压缩版 ↔ 可读版，算法一致即可）
2. 在**本地仓库根** `git add` 本次改动的文件——绝不 `git add .` / `-A`
3. 预演同步，核对将要上传的清单：

```bash
CONF="${ARCRWT_CONF:-$HOME/.dsh/arcwrt-luci.conf}"; source "$CONF"
cd "$LOCAL_REPO"
"$SYNC_TOOL" "$SYNC_SERVER" --diff
```

4. 确认清单只含本次文件后执行同步：

```bash
CONF="${ARCRWT_CONF:-$HOME/.dsh/arcwrt-luci.conf}"; source "$CONF"
"$SYNC_TOOL" "$SYNC_SERVER"
```

工具行为：剥掉路径中的 `project_patch/` 前缀 → SFTP 上传到 `<OPENWRT_ROOT>/<相对路径>`；
**上传前自动把远程原文件拉回本地** `.sync_remote/<alias>/backups/<session>/` 作为备份。

> - `sync_remote.sh` **不在 PATH**，必须用全路径调用
> - 配置读 `~/.sync_remote.conf`，别名 `206` 已指向本项目编译树
> - 环境预检可先跑一次 `--diff`（只读）确认连接与目标路径正常

**备选方案（build server 侧）**：若本机无法直连 build server，可退回到服务器侧仓库
`<PATCH_ROOT>` + `~/tools/sync_to_openwrt.sh`（传参有坑，见 `references/paths.md` 第七节）。
**两条路径不要混用**，否则两份副本会不一致。

产出：已同步到编译树的文件清单。

## 阶段 4 · 编译验证（原流程缺失环节）

**先把包路径候选表给用户，确认实际 target 后再编译。**

优先用已在运行的容器（`$HOME` 与编译树都已挂载）：

```
mcp__openwrt_build__docker_make(
  container = "<在跑的 openwrt_* 容器>",
  workDir   = "<OPENWRT_ROOT>",
  target    = "package/feeds/feeds_addon/<pkg>/clean package/feeds/feeds_addon/<pkg>/compile",
  jobs      = 16,
  verbose   = true
)
```

容器不可用时的等价方式（build server 上执行）：

```bash
cd <BASE>
fix_seq=1 ./sh-docker/docker_run-arcwrt --notty \
  'cd openwrt && make package/feeds/feeds_addon/<pkg>/clean package/feeds/feeds_addon/<pkg>/compile V=s'
```

只改 Lua / htm / js 时**只编这一个包**（分钟级），不要无脑跑 `./perform.sh all -j16`（几十分钟）。

判据：命令退出码 0，且日志无 `Error` / `ERROR`。

## 🚪 门 2 · 编译通过

编译通过才算改动成立。**失败 → 回阶段 3**，不要带着编不过的源码去 commit。

## 阶段 4.5 · 产物回灌设备验证（原流程缺失环节）

编译过 ≠ 装到设备上是对的。**把改动文件从 `.ipk` 里取出来、scp 回路由器覆盖运行态**，
让设备上跑的变成"将来刷机会真正装进去的那份文件"。这一步同时挡住三类事故：

1. **编的不是这棵树的包**（陷阱 4）—— 产物里还是旧内容，md5 一比就露馅
2. **打包期被后处理改过** —— `webjsmin` / `csstidy` / `SrcDiet` / `SubstituteVersion`
   （`CONFIG_LUCI_CSSTIDY=y` 时 css 会被 csstidy 重排；本树实测 not set，css 原样通过）
3. **安装路径与运行态路径不一致**

### ① 从 .ipk 取出改动文件（build server 上）

`.ipk` 是**外层 tar.gz**，里面再套一层 `data.tar.gz` —— **要解两层**，只解一层会找不到文件：

```bash
R=<OPENWRT_ROOT>
IPK=$R/bin/packages/<arch>/feeds_addon/<pkg>_<ver>_all.ipk
OUT=/home/zilin_chen/verify-css
rm -rf $OUT; mkdir -p $OUT; cd $OUT
tar xzf $IPK          # 外层 → control.tar.gz / data.tar.gz / debian-binary
tar xzf data.tar.gz   # 内层 → 真正的文件树 ./www/...
find $OUT -name '<改动文件名>' -print
md5sum $OUT/<ipk内路径>          # 必须 == 本地源码 md5
```

### ② scp 回路由器

用 `mcp__openwrt_build__scp_to_router`（本机中转：build server → local → router）：

```
scp_to_router(
  srcFiles       = ["/home/zilin_chen/verify-css/<改动文件>"],
  dest           = "/tmp/",              # 注意 dest 是目录
  routerHost     = "192.168.1.1",
  routerUser     = "root",
  routerPassword = "<固件默认密码>"       # 见「路由器持久性」：密码会随重启回退
)
```

### ③ 覆盖运行态并校验

```bash
cd <运行态目录>
cp <file> <file>.bak.$(date +%Y%m%d%H%M%S).predeploy
cp /tmp/<改动文件> <file>
md5sum <file>                                  # == ipk 内
curl -sk https://127.0.0.1/<url路径> | md5sum   # == ipk 内（确认 HTTP 真下发了新内容）
```

### ④ 五处 md5 必须完全相同

| 环节 | |
|---|---|
| 本地源码 `project_patch/…` | ✅ |
| 编译树 `<OPENWRT_ROOT>/feeds/…` | ✅ |
| **`.ipk` 内** | ✅ |
| 路由器运行态文件 | ✅ |
| 路由器 HTTP 取回 | ✅ |

五处齐平才算"改动真正成立"。任一处不一致 → 回阶段 3 或阶段 4 排查。

## 🚪 门 2.5 · 产物实测通过

用户强刷确认**设备上跑的是产物版本**、且视觉符合预期。
不通过 → 回阶段 4 / 阶段 3。**这一门之后才允许恢复现场与提交。**

> 走完 4.5 还有一个附带好处：门 1 是拿"手改的运行态"验收的，门 2.5 是拿"真实产物"验收的，
> 两者都过，说明"改的东西"和"编出来的东西"是同一个——中间没有悄悄丢改动。

## 阶段 5 · 收尾恢复现场

1. UCI 恢复原值并 `uci commit` —— **必做**，`/etc/config` 持久化，不会因重启消失
2. 删除测试用假数据（如 `/tmp/speedtest_result`）
3. 清理阶段 2 产生的临时文件
4. 校验实际生效范围：`uci get ...` + `grep dhcp-range /tmp/etc/dnsmasq.conf.*`
5. **按改动台账逐条销项**

## 🚪 门 3 · 现场干净

台账全部销项、无遗留 `.bak`、UCI 已回原值。

## 阶段 5.5 · Patch AI Review（新增关卡）

编译过了 ≠ 可以提交。**commit 之前对暂存区 diff 做一次缺陷优先的 AI review。**

### 用 subagent 评，不要自己评自己

用 `subagent` 工具派一个**全新上下文**的评审者，把 `git diff --cached` 全文喂给它。

**理由**：改动是本会话做的，自己审自己会天然为已有决策辩护、跳过"我当时为什么这么写"的疑点。
全新上下文没有这层包袱，更容易问出真问题。

评审者必须**只读**：不改文件、不 commit、不 push、不再往下委派。

### 输入

```bash
cd $LOCAL_REPO
git diff --cached --stat          # 规模概览，先看有没有夹带
git diff --cached                 # 全文，交给 reviewer
```

### 检查清单

见 `references/review-checklist.md`：
A 夹带 / B 调试残留 / **C 两端口径一致** / D 语言文件 / E 语法结构 / F 配置链路 / G 安全 / H 提交卫生。

其中 **C 两端口径一致性**是本工作流特有的高危项——对照阶段 2 的改动台账逐条核对，
确认没有"只改了路由器"或"只改了源码"的单边文件。

### 输出格式

按 `P0`~`P3` 分级，每条写成 `[P1] 祈使句标题 — path/to/file:line`，跟一段触发场景说明。
无合格问题就写 `No findings.`——**不要为了填满报告硬凑问题**。

## 🚪 门 4 · AI review 通过

| 评审结论 | 处置 |
|---|---|
| 有 `P0` / `P1` | **阻塞**：修复 → 回阶段 3（重新 add / sync / 编译）→ 重新 review |
| 有 `P2` | 逐条问用户，用户决定修还是接受；接受需在报告里明确记录 |
| 只有 `P3` | 记录在报告里，不阻塞 |
| `No findings.` | 过门 |

**不要在 review 有 P0/P1 未决时进入 commit。**

## 阶段 6 · Patch Commit（本地仓库）

> ⚠️ `arcwrt-commit` skill 里"在 build server 的 project_patch 上 commit"的描述**已过期**。
> 现在提交在**本地仓库**做。**commit message 格式以本节的模板为准**（自包含，不再依赖该 skill）。

### Commit message 模板（必须严格按此生成）

```
[产品][版本][模块] 英文简短描述
```

- **subject 单行**，不换行、不加 body，除非确有必要
- 三段固定：`[产品]` `[版本]` `[模块]` 从本次会话参数卡（`wf.sh conf`）取值
- 描述段**必须用英文**、简短、聚焦用户能识别的目的（如给某页/某字段/某按钮的实际效果），
  不要罗列多行、不要贴大段背景
- 示例：`[Etisalat][6.3.0][luci-app-wifi] Fix WiFi password field disabled state`

**每次都按模板生成**，不允许自行改风格、加段、或照搬它处文案。

### 操作顺序（前两步做完才能碰 git commit）

1. **前置脏区审计**（在本地仓库根）：

   ```bash
   cd $LOCAL_REPO
   git status --porcelain            # 挑出 *.bak.* / 临时产物，确认不在暂存区
   git diff --cached --name-status   # 必须是且仅是本次改动
   ```

2. **按模板生成 message 草案 + 列出本次文件清单，一起展示给用户**，等审核。

3. **必须等用户「明确确认通过」此 message 后才能 commit**。不同意 → 按意见改，
   **重新展示、重新等确认**，绝不改完直接提交。精确提交：

   ```bash
   git commit -m "<审核通过的 message>" -- <本次文件>
   git log -1 --stat                 # 复核仅含预期文件
   ```

**禁止**：`git commit --amend`、`git commit -a`、以及任何"未经用户确认就 commit"。
误用则 `git reset --soft HEAD~1` 后重来。

## 🚪 门 5 · 用户审核 commit message（强制门）

**必须、必须、必须**等用户对"按模板生成的 message + 文件清单"**明确确认通过**后，
才允许执行 `git commit`。没有用户确认，任何提交都不算完成本阶段。

---

# 安全网清单

1. **暂存区起点检查** — 开工时暂存区必须为空，否则先清理
2. **`git add` 精确到文件** — 永远不用 `.` / `-A`
3. **改动台账** — 每个文件记 原/新 md5、备份路径、UCI 原值，收尾逐条销项
4. **编译树可回滚** — `sync_remote.sh 206 --list` / `--undo` / `--restore=<id>`
5. **UCI 快照对账** — 改前 `uci show`，收尾 diff
6. **编译前置** — 门 2 卡在 commit 前，杜绝"commit 了才发现编不过"
7. **环境预检** — 阶段 0 先验容器与脚本，避免跑到一半发现工具链是坏的
8. **commit 前 AI review** — 门 4；P0/P1 未决不得提交
9. **同步后校验** — `--diff` 复查一遍，确认远程与本地一致（防漏传）
10. **编译树匹配** — `docker exec md5sum` 确认容器看到的是本次改动（陷阱 4），再 `docker_make`
11. **产物回灌验证** — 阶段 4.5 + 门 2.5；五处 md5 齐平才允许提交

# 交付报告模板

```
## 根因定位
<现象 → 实现链 → 根因>

## 改动文件清单
| 路由器路径 | md5 | 源码路径 | 备份文件 |

## 测试证据
- 门 1（运行态）浏览器实测 DOM：<evaluate_script 关键输出>
- 编译验证：<包名 + 退出码>
- 门 2.5（产物）实测：<强刷确认内容>
- **五处 md5 一致性**：本地源码 / 编译树 / ipk 内 / 路由器运行态 / HTTP 取回 = `<md5>`

## 恢复情况
- UCI：<uci get 结果>
- 临时文件：<已清理清单>

## AI Review 结论
- 级别分布：P0 <n> / P1 <n> / P2 <n> / P3 <n>
- 处置：<已全部修复 | 用户接受 P2 第 n 条 | No findings>

## 回滚方式
- 路由器：cp <file>.bak.<ts> <file>
- 源码：git checkout -- <files>
- 编译树：sync_remote.sh 206 --undo
```

# 回滚手册

| 层 | 回滚方式 |
|---|---|
| 路由器运行态 | `cp <file>.bak.<ts> <file>` + 强刷浏览器 |
| 路由器 UCI | 按快照 `uci set` 回原值 + `uci commit` |
| 本地固件源码 | 本地仓库 `git checkout -- <files>`（注意：会丢弃未提交改动） |
| 编译树 | `sync_remote.sh 206 --list` → `--undo` 或 `--restore=<session_id>` |
| 编译树（备选路径） | 若走的是服务器侧同步：`sync_to_openwrt.sh --list` → `--undo` |
| 已提交 patch | `git revert <hash>`（**不要** amend 历史） |
