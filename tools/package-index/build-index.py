#!/usr/bin/env python3
"""Merge on-device probe results into the package compatibility index."""

from __future__ import annotations

import csv
import json
from collections import OrderedDict
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
RESULTS_DIR = HERE / "results"
LIMITATIONS_FILE = HERE / "limitations.json"

CATEGORY_TITLES = OrderedDict([
    ("git", "Git 与版本控制"),
    ("completion", "补全、搜索与导航"),
    ("project", "项目与文件管理"),
    ("lsp", "LSP 与调试"),
    ("editing", "编辑增强"),
    ("lang", "语言模式与 IDE"),
    ("org", "Org、文档与阅读"),
    ("term", "终端"),
    ("workflow", "工作流、外观与杂项"),
])

# Probe results collected before the runner started reporting executables.
# The device was checked with `hdc shell 'command -v ...'` on 2026-10-27.
KNOWN_CAPABILITIES = {"threads": False, "modules": False}
SQLITE_PACKAGES = {"forge", "org-roam"}

KNOWN_EXECUTABLES = {
    "git": False, "rg": False, "python3": False, "node": False,
    "sqlite3": False, "pdflatex": False, "R": False, "java": False,
    "clang": False, "cmake": False, "make": False, "gcc": False,
    "lua": False, "go": False, "cargo": False, "php": False, "tsc": False,
}

STATUS_LABEL = {
    "ok": "✅",
    "warnings": "⚠️",
    "failed": "❌",
    "blocked": "❌",
    "partial": "⚠️",
    "missing": "⏳",
    "no-source": "—",
    "no-package-dir": "—",
}


def read_json(path: Path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return default


def load_manifest():
    data = read_json(HERE / "packages.json", [])
    if not isinstance(data, list):
        raise SystemExit("packages.json must contain a list")
    return data


def load_results():
    results = {}
    if not RESULTS_DIR.exists():
        return results
    for path in sorted(RESULTS_DIR.glob("*.json")):
        data = read_json(path, None)
        if isinstance(data, dict) and data.get("package"):
            results[data["package"]] = data
    return results


def load_limitations():
    data = read_json(LIMITATIONS_FILE, {})
    return data if isinstance(data, dict) else {}


def first_environment(results):
    preferred = ["magit", "avy"]
    for name in preferred:
        if name in results and isinstance(results[name].get("environment"), dict):
            return results[name]["environment"]
    for result in results.values():
        env = result.get("environment")
        if isinstance(env, dict):
            return env
    return {}


def as_list(value):
    if isinstance(value, list):
        return value
    if isinstance(value, tuple):
        return list(value)
    return []


def short(text, width=78):
    text = " ".join(str(text).split())
    if len(text) <= width:
        return text
    return text[: width - 1].rstrip() + "…"


def cell(text, width=78):
    return short(text, width).replace("|", "\\|")


def verdict_for(result):
    if not result:
        return "missing"
    if result.get("fatal_error"):
        return "blocked"
    install = result.get("install") or {}
    compile_ = result.get("byte_compile") or {}
    load = result.get("load") or {}
    if install.get("status") != "ok":
        return "blocked"
    if compile_.get("status") not in {"ok", "warnings", "builtin"}:
        return "partial"
    if load.get("status") != "ok":
        return "partial"
    return "ok"


def compile_label(result):
    if not result:
        return "—"
    c = result.get("byte_compile") or {}
    status = c.get("status", "missing")
    if status == "ok":
        return "✅"
    if status == "warnings":
        return f"⚠️ {c.get('warnings', 0)} 警告"
    if status == "failed":
        return f"❌ {len(as_list(c.get('errors')))} 错误"
    if status == "builtin":
        return "内置"
    return STATUS_LABEL.get(status, "—")


def install_label(result):
    if not result:
        return "—"
    if result.get("fatal_error"):
        return "❌"
    status = (result.get("install") or {}).get("status", "missing")
    return STATUS_LABEL.get(status, "—")


def load_label(result):
    if not result:
        return "—"
    status = (result.get("load") or {}).get("status", "missing")
    return STATUS_LABEL.get(status, "—")


def tool_availability(env):
    available = dict(KNOWN_EXECUTABLES)
    exes = env.get("executables") or {}
    if isinstance(exes, dict):
        for name, present in exes.items():
            available[str(name)] = bool(present)
    return available


def limitation_tags(entry, result, curated, env):
    """Compact tags for the main table."""
    name = entry["name"]
    note = (curated.get(name) or {}) if isinstance(curated, dict) else {}
    requires = as_list(note.get("requires"))
    auto = (result or {}).get("limitations") or {}
    tools = as_list(auto.get("external_tools"))
    availability = tool_availability(env)
    missing = [t for t in tools if availability.get(t) is False]
    tags = []
    for req in requires:
        tags.append(req)
    for tool in missing:
        if tool not in requires:
            tags.append("缺 " + tool)
    if as_list(auto.get("gui_features")):
        tags.append("GUI")
    hints = as_list(auto.get("capability_hints"))
    if ("sqlite" in hints and env.get("sqlite") is False
            and ("sqlite" in requires or name in SQLITE_PACKAGES)):
        tags.append("sqlite")
    deduped = []
    for tag in tags:
        if tag not in deduped:
            deduped.append(tag)
    if not deduped and note.get("note"):
        return "见详情"
    if len(deduped) > 4:
        return " / ".join(deduped[:4]) + " …"
    return " / ".join(deduped) if deduped else "—"


def limitation_text(entry, result, curated, env):
    """Full human-readable limitation note."""
    name = entry["name"]
    bits = []
    note = (curated.get(name) or {}) if isinstance(curated, dict) else {}
    note_text = note.get("note") or ""
    if note_text:
        bits.append(note_text)
    requires = as_list(note.get("requires"))
    missing_requires = [r for r in requires if r.lower() not in note_text.lower()]
    if missing_requires:
        bits.append("依赖：" + "、".join(missing_requires) + "。")

    auto = (result or {}).get("limitations") or {}
    tools = as_list(auto.get("external_tools"))
    if tools:
        availability = tool_availability(env)
        missing = [t for t in tools if availability.get(t) is False]
        if missing:
            bits.append("源码引用外部命令 " + "、".join(tools) + "；设备上未找到 " + "、".join(missing) + "。")
        else:
            bits.append("源码引用外部命令 " + "、".join(tools) + "。")

    gui = as_list(auto.get("gui_features"))
    if gui:
        bits.append("引用 GUI 能力（" + "、".join(gui) + "）；当前为 tty，相关交互不可用。")

    hints = as_list(auto.get("capability_hints"))
    if ("sqlite" in hints and env.get("sqlite") is False
            and "sqlite" not in requires and name not in SQLITE_PACKAGES):
        hints = [h for h in hints if h != "sqlite"]
    if hints:
        unavailable = []
        for hint in hints:
            if hint == "sqlite" and env.get("sqlite") is False:
                unavailable.append("sqlite")
            if hint == "libxml" and env.get("libxml") is False:
                unavailable.append("libxml")
        if unavailable:
            bits.append("需要构建期能力 " + "、".join(sorted(set(unavailable))) + "，当前构建未启用。")
        else:
            bits.append("源码涉及 " + "、".join(hints) + "。")

    deduped = []
    for bit in bits:
        if bit not in deduped:
            deduped.append(bit)
    return short(" ".join(deduped), 180) if deduped else "—"


def overall_label(verdict):
    return {
        "ok": "✅ 通过",
        "partial": "⚠️ 部分可用",
        "blocked": "❌ 不可用",
        "missing": "⏳ 未测试",
    }.get(verdict, "—")


def build():
    manifest = load_manifest()
    results = load_results()
    curated = load_limitations()
    env = first_environment(results)

    packages = []
    for entry in manifest:
        name = entry["name"]
        result = results.get(name)
        verdict = verdict_for(result)
        package = dict(entry)
        if result and result.get("source"):
            package["source"] = result["source"]
        package["verdict"] = verdict
        package["tested_at"] = (result or {}).get("tested_at")
        package["install"] = (result or {}).get("install")
        package["byte_compile"] = (result or {}).get("byte_compile")
        package["load"] = (result or {}).get("load")
        package["limitation_tags"] = limitation_tags(entry, result, curated, env)
        package["limitations_note"] = limitation_text(entry, result, curated, env)
        note = (curated.get(name) or {}) if isinstance(curated, dict) else {}
        auto = (result or {}).get("limitations") or {}
        availability = tool_availability(env)
        missing_tools = [t for t in as_list(auto.get("external_tools"))
                         if availability.get(t) is False]
        hard = bool(as_list(note.get("requires")) or missing_tools
                    or ("sqlite" in as_list(auto.get("capability_hints"))
                        and env.get("sqlite") is False))
        package["hard_limits"] = hard
        package["raw_result"] = f"results/{name}.json" if result else None
        packages.append(package)

    def count(pred):
        return sum(1 for p in packages if pred(p))

    installed = [p for p in packages if p["verdict"] != "missing" and (p.get("install") or {}).get("status") == "ok"]
    compiled = [p for p in packages
                if (p.get("byte_compile") or {}).get("status") in {"ok", "warnings", "builtin"}]
    loaded = [p for p in packages if (p.get("load") or {}).get("status") == "ok"]
    summary = {
        "total": len(packages),
        "tested": count(lambda p: p["verdict"] != "missing"),
        "installed": len(installed),
        "compiled": len(compiled),
        "loaded": len(loaded),
        "passed": count(lambda p: p["verdict"] == "ok"),
        "partial": count(lambda p: p["verdict"] == "partial"),
        "blocked": count(lambda p: p["verdict"] == "blocked"),
        "missing": count(lambda p: p["verdict"] == "missing"),
        "compile_warnings": count(lambda p: ((p.get("byte_compile") or {}).get("status") == "warnings")),
        "compile_errors": count(lambda p: ((p.get("byte_compile") or {}).get("status") == "failed")),
        "load_errors": count(lambda p: ((p.get("load") or {}).get("status") == "failed")),
    }

    selection = {
        "name": "emacs-hmos top 100 package index",
        "ranking_source": "MELPA download_counts.json",
        "ranking_url": "https://melpa.org/download_counts.json",
        "ranking_snapshot": "2026-10-27",
        "method": "从 MELPA 下载量排名出发，剔除纯依赖库/内置包/已废弃包，保留 100 个用户会直接调用的包；GNU ELPA 独有包按同类热度补入。",
        "caveat": "下载量不等于真实用户数；它受 CI、包管理器和依赖安装影响，只用作热度代理指标。",
    }

    generated_at = datetime.now(timezone.utc).astimezone().strftime("%Y-%m-%d %H:%M:%S %z")
    index = {
        "schema": 1,
        "generated_at": generated_at,
        "selection": selection,
        "environment": env,
        "summary": summary,
        "packages": packages,
    }
    (HERE / "index.json").write_text(json.dumps(index, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    with (HERE / "index.csv").open("w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        writer.writerow(["rank", "name", "category", "source", "version", "install", "byte_compile", "load", "warnings", "verdict", "limitations"])
        for p in packages:
            writer.writerow([
                p.get("melpa_rank") or "",
                p["name"],
                p["category"],
                p.get("source", ""),
                p.get("version", ""),
                install_label(p.get("install") and {"install": p["install"]}),
                compile_label(p.get("byte_compile") and {"byte_compile": p["byte_compile"]}),
                load_label(p.get("load") and {"load": p["load"]}),
                (p.get("byte_compile") or {}).get("warnings", ""),
                p["verdict"],
                p["limitations_note"],
            ])

    markdown = render_markdown(index, env)
    (HERE / "INDEX.md").write_text(markdown, encoding="utf-8")
    docs_dir = REPO / "docs"
    docs_dir.mkdir(parents=True, exist_ok=True)
    (docs_dir / "PACKAGE-INDEX.md").write_text(markdown, encoding="utf-8")
    print(f"wrote {HERE / 'INDEX.md'}")
    print(f"wrote {docs_dir / 'PACKAGE-INDEX.md'}")
    print(f"wrote {HERE / 'index.json'}")
    print(f"wrote {HERE / 'index.csv'}")
    print("summary:", json.dumps(summary, ensure_ascii=False))


def render_markdown(index, env):
    packages = index["packages"]
    summary = index["summary"]
    by_cat = OrderedDict((key, []) for key in CATEGORY_TITLES)
    for package in packages:
        by_cat.setdefault(package["category"], []).append(package)

    def pct(n, d):
        return f"{n}/{d}" if d else "0/0"

    lines = []
    lines.append("# 鸿蒙真机 Emacs 包兼容性索引（Top 100）")
    lines.append("")
    lines.append("> 用 `emacs-hmos` 在 HarmonyOS NEXT 真机上批量验证 100 个常用包：安装、字节编译、加载，以及已知限制。")
    lines.append("> 索引的目标不是给每个包打分，而是回答一个更实际的问题：**在鸿蒙上的 Emacs 里，哪些包能直接拿来用，哪些需要额外条件。**")
    lines.append("")
    lines.append(f"生成时间：{index['generated_at']}  ")
    lines.append(f"数据：`{len(packages)}` 个包，`{summary['tested']}` 个已跑完  ")
    lines.append("机器可读版本：[`index.json`](../tools/package-index/index.json) · [`index.csv`](../tools/package-index/index.csv)  ")
    lines.append("复现脚本：[`run-device.sh`](../tools/package-index/run-device.sh) · [`runner.el`](../tools/package-index/runner.el) · [`build-index.py`](../tools/package-index/build-index.py)")
    lines.append("")
    lines.append("## 测试环境")
    lines.append("")
    lines.append("| 项目 | 值 |")
    lines.append("| --- | --- |")
    lines.append("| 设备 | HM740-061（HarmonyOS NEXT，API 24，Kirin X90，2880×1920） |")
    lines.append("| Emacs | `32.0.50`，`aarch64-unknown-linux-ohos` |")
    lines.append("| 前端 | 应用内 tty（xterm.js + pty），`window-system=nil`，无 GUI frame |")
    threads = env.get("threads")
    if threads is None:
        threads = KNOWN_CAPABILITIES["threads"]
    modules = env.get("modules")
    if modules is None:
        modules = KNOWN_CAPABILITIES["modules"]
    lines.append("| 构建能力 | gnutls ✅ · json ✅ · sqlite ❌ · native-comp ❌ · threads " + ("✅" if threads else "❌") + " · modules " + ("✅" if modules else "❌") + " |")
    avail = tool_availability(env)
    tool_names = ["git", "rg", "python3", "node", "sqlite3", "make", "gcc", "cmake", "pdflatex", "R", "java"]
    tool_cell = " · ".join(f"{name} {'✅' if avail.get(name) else '❌'}" for name in tool_names)
    lines.append(f"| 外部命令 | {tool_cell} |")
    lines.append("")
    lines.append("## 结论速览")
    lines.append("")
    lines.append(f"- **安装成功**：{pct(summary['installed'], summary['total'])}")
    lines.append(f"- **字节编译无错误**：{pct(summary['compiled'], summary['total'])}（其中 {summary['compile_warnings']} 个有警告，{summary['compile_errors']} 个有错误）")
    lines.append(f"- **加载成功**：{pct(summary['loaded'], summary['total'])}")
    lines.append(f"- **三项全过**：{pct(summary['passed'], summary['total'])}；部分可用 {summary['partial']}；不可用/安装失败 {summary['blocked']}；未测试 {summary['missing']}")
    partials = [p for p in packages if p["verdict"] == "partial"]
    if partials:
        def reason(p):
            err = str((p.get("load") or {}).get("error") or "")
            if "git" in err:
                return "缺 git 二进制"
            if "make-mutex" in err:
                return "构建无线程支持"
            if "module support" in err:
                return "构建无 module 支持"
            return short(err or "load failed", 36)
        lines.append("- **加载未通过**：" + "；".join(
            f"`{p['name']}`（{reason(p)}）" for p in partials))
    lines.append("")
    lines.append("> “通过”只表示安装、字节编译、`load` 三步没有致命错误；不表示包的每个命令都在 tty 下可用。带外部依赖的包请看“限制”列。")
    local = [p for p in packages if p.get("source") == "local"]
    if local:
        names = "、".join(f"`{p['name']}`" for p in local)
        lines.append("")
        lines.append(f"> 数据说明：{names} 的归档包在设备网络上多次超时，最终使用同一版本的官方 tar 本地缓存安装；安装/编译/加载结果仍由真机上的 Emacs 产生。")
    lines.append("")

    # Highlights: prefer clean passes, then conditional passes.
    clean = []
    conditional = []
    for p in packages:
        if p["verdict"] != "ok":
            continue
        if p.get("hard_limits"):
            conditional.append(p)
        else:
            clean.append(p)
    clean.sort(key=lambda p: (p.get("melpa_rank") or 10**9))
    conditional.sort(key=lambda p: (p.get("melpa_rank") or 10**9))
    if clean:
        lines.append("**开箱即用的代表**：" + "、".join(f"`{p['name']}`" for p in clean[:14]))
        lines.append("")
    if conditional:
        lines.append("**能加载、但要注意限制的代表**：" + "、".join(f"`{p['name']}`" for p in conditional[:14]))
        lines.append("")

    lines.append("## 分类索引")
    lines.append("")
    for cat, title in CATEGORY_TITLES.items():
        group = by_cat.get(cat) or []
        if not group:
            continue
        lines.append(f"### {title}")
        lines.append("")
        lines.append("| 包 | 用途 | 结果 | 安装 | 字节编译 | 加载 | 限制 |")
        lines.append("| --- | --- | --- | --- | --- | --- | --- |")
        for p in group:
            install = install_label({"install": p.get("install")} if p.get("install") else None)
            compile_ = compile_label({"byte_compile": p.get("byte_compile")} if p.get("byte_compile") else None)
            load = load_label({"load": p.get("load")} if p.get("load") else None)
            note = p.get("limitation_tags") or "—"
            lines.append(
                f"| `{p['name']}` | {cell(p.get('summary') or '', 54)} | {overall_label(p['verdict'])} | {install} | {compile_} | {load} | {cell(note, 46)} |"
            )
        lines.append("")

    lines.append("### 限制详情")
    lines.append("")
    lines.append("下表是自动检测与人工说明合并后的完整限制；没有列出的包没有检测到外部命令/GUI/构建期能力依赖。")
    lines.append("")
    for p in packages:
        detail = p.get("limitations_note") or "—"
        if detail != "—":
            lines.append(f"- **`{p['name']}`**：{detail}")
    lines.append("")

    lines.append("## 已知限制怎么读")
    lines.append("")
    lines.append("- **外部命令**：包的源码里出现 `executable-find` 等调用；设备上没有对应二进制时，相关命令会失败或降级。")
    lines.append("- **GUI 能力**：包引用了 `display-graphic-p`、`gui-get-selection`、child-frame 等；当前是 tty，相关交互不可用或回退。")
    lines.append("- **构建期能力**：如 sqlite、libxml、native-comp；这一版 Emacs 构建没有启用时，依赖它们的包只能部分工作。")
    lines.append("- **`load` 成功 ≠ 功能完整**：很多包在 tty 下能加载，但菜单、图标、图片、PDF 渲染、语言服务器等仍需要额外条件。")
    lines.append("")

    lines.append("## 选择方法")
    lines.append("")
    lines.append("1. 以 MELPA 官方 `download_counts.json`（2026-10-27 快照）为热度基线。")
    lines.append("2. 从下载量排名出发，剔除纯依赖库（如 `dash`、`s`、`f`、`popup`）、已内置/已废弃的包，保留用户会直接调用的 100 个包。")
    lines.append("3. 对 GNU ELPA 独有且常用的包（如 `auctex`、`ef-themes`）按同类热度补入。")
    lines.append("4. 每个包单独启动一个 `emacs --batch -Q -l runner.el` 进程，避免包之间的全局状态污染；单包超时 300 秒。")
    lines.append("")
    lines.append("> 下载量不是用户数：CI、包管理器和依赖安装都会放大计数，所以这里只把它当作“热度代理指标”，不宣称严格排名。")
    lines.append("")

    lines.append("## 复现")
    lines.append("")
    lines.append("```bash")
    lines.append("# 1) 在已安装 emacs-hmos 的真机上跑 100 个包")
    lines.append("TARGET=192.168.102.170:39681 tools/package-index/run-device.sh")
    lines.append("")
    lines.append("# 2) 把设备结果拉回并生成索引")
    lines.append("python3 tools/package-index/build-index.py")
    lines.append("```")
    lines.append("")
    lines.append("测试脚本只把结果写到应用沙箱的 `runtime/package-index/`，不会修改 Emacs 运行时或用户配置。")
    lines.append("")
    lines.append("## 结果文件")
    lines.append("")
    lines.append("- [`index.json`](../tools/package-index/index.json)：合并后的机器可读索引（含每个包的安装/编译/加载结果和限制）。")
    lines.append("- [`index.csv`](../tools/package-index/index.csv)：表格软件可直接打开的扁平版本。")
    lines.append("- [`results/`](../tools/package-index/results/)：每个包一份原始 JSON 与日志，便于复查。")
    lines.append("")
    return "\n".join(lines)


if __name__ == "__main__":
    build()
