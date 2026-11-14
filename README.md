# codex-max-context

一键把 **OpenAI Codex** 的上下文窗口调到 Codex 允许的最大值。支持 Windows、macOS、Linux、WSL，改之前自动备份，一条命令就能还原。

官网：**https://codex.pddshop.cc** · [English](#english)

**最简单的用法**：把这句话发给 Codex 或 Claude Code，它会自己装好 Skill 并完成设置。

> 请阅读 https://codex.pddshop.cc/install.md ，按里面的步骤帮我安装 codex-max-context 这个 skill，然后用它把我的 Codex 上下文调到最大。

想自己动手，也可以直接运行一行命令：

```powershell
# Windows（PowerShell）
& ([scriptblock]::Create((irm https://codex.pddshop.cc/set-context.ps1)))
```

```bash
# macOS / Linux / WSL
curl -fsSL https://codex.pddshop.cc/set-context.sh | bash
```

---

## 它解决什么问题

GPT-6.1 Sol 在 API 里的上下文是 1M，但 Codex 默认只给 500K，界面上再扣掉 5% 的预留，你看到的就是 **"共 475k"** 左右。

这个工具会在 `~/.codex/config.toml` 里写上 `model_context_window = 1000000`。Codex 会把它限制在这个模型自己的最大值以内，以 2026 年 11 月为例，Sol 是 872K，所以重启后显示 **"共 828k"** 左右，差不多翻倍。

> 真正的上限由 OpenAI 下发到你电脑上的 `models_cache.json` 决定。脚本每次都现读这个文件，并告诉你实际能拿到多少。以后 OpenAI 提高上限，不用改脚本，重新运行就行。

**只对 Codex 有效**（桌面 App、CLI、IDE 插件）。ChatGPT 网页版和手机 App 没有本地设置可以改。

---

## 使用方法

### 方式 A：作为 Skill，交给 AI 助手去做（推荐）

把整个 `codex-max-context` 文件夹放到对应目录：

| 平台 | 放到哪里 |
|---|---|
| Codex | `~/.codex/skills/codex-max-context/` |
| Claude Code | `~/.claude/skills/codex-max-context/` |
| Claude.ai / Claude 桌面版 | 在设置的 Skills 页面上传 [codex-max-context.zip](https://github.com/billowssun/codex-max-context/releases/latest/download/codex-max-context.zip) |
| 其他支持 `SKILL.md` 的 Agent | 放进它的 skills 目录 |

然后直接对它说：

> 帮我把 Codex 的上下文调到最大

它会先告诉你现在的设置，再修改，最后告诉你重启后能拿到多少。

> 在 Codex 里运行时，如果沙盒拦住了对 `~/.codex` 的写入，点同意即可，或者改用方式 B 自己跑。

### 方式 B：自己运行脚本（不需要任何 AI）

先下载或解压这个文件夹，然后在文件夹里打开终端。

**Windows**（PowerShell）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\set-context.ps1
```

**macOS / Linux / WSL**（终端）：

```bash
bash ./scripts/set-context.sh
```

运行后会看到类似这样的输出：

```
Model               : gpt-6.1-sol
model_context_window: not set
Cached limits       : default 500000 (~500K), max 872000 (~872K), usable 95%
Usable right now    : 475000 (~475K)

Done: model_context_window = 1000000
Backup              : C:\Users\you\.codex\config.toml.ctxbak-20261114-135225
Usable after restart: 828400 (~828K)
```

### 改完之后必须做的两件事

1. **完全退出 Codex**：不是关掉窗口，而是从托盘或 Dock 里退出，或者直接重启电脑。
2. 重新打开 Codex，**开一个新对话**。旧对话会保持原来的大小。

把鼠标放到上下文用量的圆圈上，应该能看到 "共 828k" 左右。

---

## 其他选项

| 想做什么 | Windows | macOS / Linux |
|---|---|---|
| 只看现状，不改 | `-Status` | `--status` |
| 预览会改什么 | `-DryRun` | `--dry-run` |
| 自定义数值 | `-Value 600000` | `--value 600000` |
| 指定模型 | `-Model gpt-6.1-sol` | `--model gpt-6.1-sol` |
| **还原上一次修改** | `-Restore` | `--restore` |

例：`bash ./scripts/set-context.sh --restore`

---

## 常见问题

**为什么不是满 1M？**
Codex 会把这个值限制在模型的最大值以内（目前 Sol 是 872K），界面上再扣掉约 5% 的预留。想用满 1M 只能直接走 API。

**会多花钱或多耗额度吗？**
会。上下文越长，每次请求发送的 token 越多，消耗的额度也越多。走 API 的话，输入超过 272K 后单价更高。

**会不会把我的配置改坏？**
脚本只改 `config.toml` 最顶层的 `model_context_window` 这一行，其他内容原样保留。每次改之前都会备份成 `config.toml.ctxbak-时间戳`，用 `--restore` 就能还原。`models_cache.json` 只读不写。

**重启后没变化？**
确认 Codex 真的完全退出了，并且是在新对话里看的。再检查一下有没有用 `-c model_context_window=...` 或某个 profile 覆盖了这个值。

**提示 "Cached limits: not found"？**
说明还没打开过 Codex，或者模型名对不上。先打开一次 Codex，或者加上 `--model gpt-6.1-sol`。设置照样会写进去，只是脚本没法预估实际大小。

**我设置了 `CODEX_HOME`？**
脚本会自动使用它，没设置的话就用 `~/.codex`。

---

## English

Raise the **OpenAI Codex** context window to the largest size Codex allows. Works on Windows, macOS, Linux and WSL, backs up your config before every change, and can be undone with one command.

GPT-6.1 Sol has a 1M context in the API, but Codex defaults to 500K and shows about 95% of that (~475K). This tool writes `model_context_window = 1000000` to `~/.codex/config.toml`. Codex clamps that to the model's own maximum (872K for Sol as of November 2026), so after a restart you get about **828K usable**. The real cap comes from `models_cache.json` on your machine. The script reads it every time, so you can rerun it if OpenAI raises the cap. ChatGPT web and mobile can't be changed this way.

Website: **https://codex.pddshop.cc**. Easiest way: send this to Codex or Claude Code.

> Read https://codex.pddshop.cc/install.md, install the codex-max-context skill as it describes, then use it to max out my Codex context window.

Or run it yourself:

```powershell
# Windows (PowerShell)
& ([scriptblock]::Create((irm https://codex.pddshop.cc/set-context.ps1)))
```

```bash
# macOS / Linux / WSL
curl -fsSL https://codex.pddshop.cc/set-context.sh | bash
```

**As a skill:** copy the folder to `~/.codex/skills/` (Codex) or `~/.claude/skills/` (Claude Code), or upload the zip (Claude.ai), then ask your assistant to "max out my Codex context window".

**By hand:**

```powershell
# Windows
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\set-context.ps1
```

```bash
# macOS / Linux / WSL
bash ./scripts/set-context.sh
```

Options: `--status`, `--dry-run`, `--value N`, `--model SLUG`, `--restore` (PowerShell: `-Status`, `-DryRun`, `-Value`, `-Model`, `-Restore`).

Afterwards, **quit Codex completely**, reopen it and **start a new conversation**. A longer context uses more quota per request.

## License

MIT, see [LICENSE](LICENSE).
