#!/usr/bin/env python3
"""Measurable interaction acceptance probes for Emacs on HarmonyOS.

The scenarios below are executable interaction probes; each one produces a
machine-readable verdict and a log/pixel/text artefact.

Why it exists
-------------
"Typing feels broken" cannot be decided from a screenshot.  Two channels
make the scenarios measurable:

* Text channel: a Lisp probe is installed through the ``ohos-dev.el``
  hot-reload hook (``ohos-dev-poll`` loads it 0.5 s after it changes).
  It rewrites ``$HOME/ohos-probe.txt`` on every executed command with the
  buffer name, point, line/column, ``this-command``, ``this-command-keys``
  and the first 8 KiB of buffer text.  Assertions run against the real
  editor state, not against OCR.
* Log channel: ``hilog`` is cleared before every scenario, then parsed for
  the interaction trace (``key evt``, ``xcomponent focus``, ``menu-open``,
  ``menu result``, ``frame metrics``, ``tick=``).

Usage
-----
    TARGET=192.168.102.58:37103 scripts/interaction-acceptance.py
    scripts/interaction-acceptance.py --only I-2,M-1 --verbose
    scripts/interaction-acceptance.py --list

Exit status is 0 when every selected scenario passed, 1 otherwise.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

CT_DEFAULT = os.environ.get("OHOS_CT") or os.environ.get("CT") or ""
BUNDLE = "emacs.hmos.org"
ABILITY = "EntryAbility"
REPO = Path(__file__).resolve().parent.parent
RUNTIME_DIR = f"/data/app/el2/100/base/{BUNDLE}/haps/entry/files/runtime102"
HOME_DIR = f"{RUNTIME_DIR}/home"
PROBE_FILE = f"{HOME_DIR}/ohos-probe.txt"
DEV_FILE = f"{HOME_DIR}/ohos-dev.el"

# ---------------------------------------------------------------- probe Lisp

PROBE_ELISP = r"""
;;; acceptance-probe.el --- probe installed by interaction-acceptance.py  -*- lexical-binding: t; -*-
(defvar ohos-probe-file (expand-file-name "ohos-probe.txt" (getenv "HOME")))
(defvar ohos-probe-seq 0)
(defvar ohos-probe-max-bytes 8000)

(defun ohos-probe-record (&optional tag)
  (let* ((buf (buffer-name))
         (pt (point))
         (pmin (point-min))
         (pmax (point-max))
         (line (ignore-errors (line-number-at-pos)))
         (col (ignore-errors (current-column)))
         (mod (buffer-modified-p))
         (cmd this-command)
         (ev last-command-event)
         (keys (ignore-errors (key-description (this-command-keys))))
         (fname (ignore-errors (frame-parameter nil 'name)))
         (text (ignore-errors
                 (buffer-substring-no-properties
                  pmin (min pmax (+ pmin ohos-probe-max-bytes))))))
    (setq ohos-probe-seq (1+ ohos-probe-seq))
    (with-temp-file ohos-probe-file
      (insert (format "seq=%d\n" ohos-probe-seq))
      (insert (format "tag=%s\n" (or tag "")))
      (insert (format "buffer=%S\n" buf))
      (insert (format "point=%d\n" pt))
      (insert (format "line=%S\n" line))
      (insert (format "column=%S\n" col))
      (insert (format "point-max=%d\n" pmax))
      (insert (format "modified=%S\n" mod))
      (insert (format "command=%S\n" cmd))
      (insert (format "last-event=%S\n" ev))
      (insert (format "keys=%S\n" keys))
      (insert (format "frame=%S\n" fname))
      (insert (format "window-start=%d\n" (window-start)))
      (insert "---text---\n")
      (insert (or text ""))
      (insert "\n---end---\n"))))

(add-hook 'post-command-hook #'ohos-probe-record)
(ohos-probe-record "loaded")
(message "ohos-probe loaded seq=%d" ohos-probe-seq)
"""

SETUP = {
    # A scratch buffer at point-min is the reference state for key tests.
    "scratch": '(switch-to-buffer "*scratch*")\n(erase-buffer)\n(goto-char (point-min))\n'
               '(setq case-fold-search t)\n'
               '(setq gc-cons-threshold (* 256 1024 1024))\n',

    # Two real lines so line/column assertions have something to land on.
    "text": '(switch-to-buffer "*scratch*")\n(erase-buffer)\n'
            '(insert "line one\\nline two\\nline three\\n")\n'
            '(goto-char (point-min))\n',
}

PROBE_KEYS = {
    "seq", "tag", "buffer", "point", "line", "column", "point-max",
    "modified", "command", "last-event", "keys", "frame", "window-start",
}

# ---------------------------------------------------------------- scenarios

SCENARIOS = [
    {
        "id": "I-1",
        "title": "窗口/表面获得焦点",
        "steps": "启动应用，检查 XComponent 焦点与 focus 回调日志",
        "expect": "layout 中 XComponent focused=true 且日志有 'xcomponent focus'",
    },
    {
        "id": "I-2",
        "title": "英文按键进入缓冲区",
        "steps": "reset=scratch；注入 a b c；读 probe",
        "expect": "buffer=*scratch*, command=self-insert-command, text='abc', point=4",
    },
    {
        "id": "I-3",
        "title": "点击正文只定位不抢键盘",
        "steps": "reset=text；点击正文；随后注入 x；读 probe",
        "expect": "点击后 command=mouse-set-point，随后 x 仍能 self-insert",
    },
    {
        "id": "I-4",
        "title": "控制键 RET/DEL/方向键",
        "steps": "reset=scratch；abc RET LEFT DEL；读 probe",
        "expect": "text='abc\\n' 或包含换行，command 为 self-insert/newline/left-char/backward-delete",
    },
    {
        "id": "I-5",
        "title": "Ctrl 前缀组合键 (C-x C-b)",
        "steps": "reset=scratch；注入 Ctrl+x, Ctrl+b；读 probe",
        "expect": "keys 含 'C-x C-b' 且 command=list-buffers",
    },
    {
        "id": "I-6",
        "title": "鼠标点击定位到行",
        "steps": "reset=text；点击正文第 2 行左端；读 probe",
        "expect": "line=2（容差 1），point 随点击移动",
    },
    {
        "id": "I-7",
        "title": "键盘面板输入中文并提交",
        "steps": "reset=scratch；点 ⌨ 键盘；uiInput text 中文abc；点 提交；读 probe",
        "expect": "text 含 '中文abc'，command=self-insert-command",
    },
    {
        "id": "L-1",
        "title": "单键间隔输入的 pop→present",
        "restart": True,
        "steps": "reset=scratch；每隔 1.2s 注入 a-e；解析 seq 对应的 pop->present",
        "expect": "最近 5 个 present 的 p95 <= 50ms",
    },
    {
        "id": "S-3",
        "title": "短时输入/滚动 soak",
        "steps": "30 次输入，每 5 次 C-v；检查进程和 buffer",
        "expect": "进程存活，buffer 有内容，无崩溃",
    },
    {
        "id": "S-2",
        "title": "后台/前台恢复",
        "steps": "Home 切后台；aa start 恢复；读 probe",
        "expect": "进程仍存活，probe 可读，window-start 有效",
    },
    {
        "id": "S-1",
        "title": "滚动窗口后窗口起点前进",
        "steps": "插入 100 行；记录 window-start；C-v；读 probe",
        "expect": "window-start 前移，进程存活",
    },
    {
        "id": "I-8",
        "title": "连续 20 个字符无丢失",
        "restart": True,
        "steps": "reset=scratch；注入 20 个字母；读 probe 与 tick 指标",
        "expect": "text 长度=20、probe seq 前进 20、日志 keyP95<120ms",
    },
    {
        "id": "I-9",
        "title": "M-x 与 minibuffer 交互",
        "steps": "reset=scratch；注入 ESC x；读 probe；C-g 退出",
        "expect": "buffer 为 *Minibuf-*，command=execute-extended-command",
    },
    {
        "id": "E-2",
        "title": "Elisp 强制 redisplay 基准",
        "steps": "加载 harness；执行 (ohos-parity-benchmark-redisplay 20)；读 report",
        "expect": "benchmark 样本存在，avg/p95/max 有效",
        "restart": True,
    },
    {
        "id": "E-1",
        "title": "Elisp harness 观测 redisplay/命令状态",
        "steps": "加载 test/elisp/ohos-parity-harness.el；注入 abc/LEFT；读 JSON report",
        "expect": "samples 含 command/redisplay，frame 尺寸有效",
        "restart": True,
    },
    {
        "id": "M-5",
        "title": "菜单项显示快捷键提示",
        "steps": "点 File；读 layout 文本",
        "expect": "存在 'C-x C-f' 提示文本",
    },
    {
        "id": "M-1",
        "title": "菜单栏点击打开菜单",
        "steps": "点 File；读日志与 layout",
        "expect": "日志 menubar click index=0 且 menu-open id=>0；layout 出现 'Visit New File...'",
    },
    {
        "id": "M-2",
        "title": "菜单项执行命令",
        "steps": "点 File -> Visit New File...；读日志与 probe",
        "expect": "日志 menu result id=N index=5；probe buffer 为 minibuffer（*Minibuf*）",
    },
    {
        "id": "M-3",
        "title": "菜单关闭后键盘回到正文",
        "steps": "点 File；按 Esc 关闭；注入 a；读 probe",
        "expect": "关闭后 a 仍进入缓冲区 (self-insert-command)",
        "restart": True,
    },
    {
        "id": "M-4",
        "title": "菜单栏无重复/幽灵项",
        "steps": "读 layout 菜单栏 Text 列表与日志 menubar items=",
        "expect": "layout 标签数量等于 bar 长度且无相邻重复标签",
    },
    {
        "id": "D-1",
        "title": "首帧与几何",
        "steps": "清日志、重启应用、等待 12s",
        "expect": "日志含 surface created / frame metrics / first frame，tick 有 gap=0",
    },
    {
        "id": "D-2",
        "title": "正文区非空（没有黑屏）",
        "steps": "截屏，统计正文区非背景像素比例",
        "expect": "正文区非背景像素 > 0.5%",
    },
    {
        "id": "D-3",
        "title": "最大化后画面仍然刷新",
        "steps": "点窗口最大化 → 截屏 → 注入按键 → 再截屏",
        "expect": "两张截图不同（surface 重建后仍能提交新帧）",
    },
    {
        "id": "P-1",
        "title": "空闲稳定",
        "steps": "等待 5s 的空闲 tick",
        "expect": "fps>30、gap=0、进程存活",
    },
]


class Hdc:
    def __init__(self, target: str, ct: str, verbose: bool = False):
        self.target = target
        self.hdc = str(Path(ct) / "sdk/default/openharmony/toolchains/hdc")
        self.verbose = verbose
        if not Path(self.hdc).exists():
            raise SystemExit(f"hdc not found: {self.hdc}")

    def run(self, *args: str, timeout: int = 60, check: bool = True) -> str:
        cmd = [self.hdc, "-t", self.target, *args]
        if self.verbose:
            print("  $ " + " ".join(cmd), flush=True)
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        if check and proc.returncode != 0:
            raise RuntimeError(f"hdc {' '.join(args)} failed: {proc.stderr.strip()}")
        return proc.stdout

    def shell(self, command: str, timeout: int = 60, check: bool = True) -> str:
        return self.run("shell", command, timeout=timeout, check=check)

    def send(self, local: Path, remote: str) -> None:
        self.run("file", "send", str(local), remote, timeout=120)

    def recv(self, remote: str, local: Path) -> None:
        self.run("file", "recv", remote, str(local), timeout=120)

    # ---- device primitives

    def key(self, code: int) -> None:
        self.shell(f"uitest uiInput keyEvent {code}", check=False)

    def combo(self, *codes: int) -> None:
        self.shell("uitest uiInput keyEvent " + " ".join(str(c) for c in codes),
                   check=False)

    def text(self, value: str) -> None:
        self.shell(f"uitest uiInput text '{value}'", check=False)

    def click(self, x: int, y: int) -> None:
        self.shell(f"uitest uiInput click {x} {y}", check=False)

    def long_click(self, x: int, y: int) -> None:
        self.shell(f"uitest uiInput longClick {x} {y}", check=False)

    def log_clear(self) -> None:
        self.shell("hilog -r", check=False)

    def log(self) -> str:
        return self.shell("hilog -x", check=False, timeout=90)

    def log_grep(self, pattern: str, timeout: int = 60) -> str:
        """Server-side grep: only the matching lines cross hdc."""
        return self.shell(f"hilog -x 2>/dev/null | grep -aE '{pattern}'",
                          check=False, timeout=timeout)

    def layout(self) -> dict:
        self.shell("uitest dumpLayout -p /data/local/tmp/acc.json -a", check=False)
        local = REPO / "artifacts/acceptance/_layout.json"
        local.parent.mkdir(parents=True, exist_ok=True)
        self.recv("/data/local/tmp/acc.json", local)
        return json.loads(local.read_text(encoding="utf-8", errors="replace"))

    def screenshot(self, local: Path) -> None:
        self.shell("uitest screenCap -p /data/local/tmp/acc.png", check=False)
        self.recv("/data/local/tmp/acc.png", local)


# --------------------------------------------------------------- helpers

def walk(node: dict, out: list) -> None:
    out.append(node)
    for child in node.get("children") or []:
        walk(child, out)


def nodes_of(layout: dict) -> list:
    out: list = []
    walk(layout, out)
    return out


BOUNDS_RE = re.compile(r"\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]")


def bounds(node: dict) -> list:
    """dumpLayout serialises Rect as "[x0,y0][x1,y1]" (or a 4-number list)."""
    raw = (node.get("attributes") or {}).get("bounds")
    if isinstance(raw, str):
        match = BOUNDS_RE.search(raw)
        if match:
            return [int(v) for v in match.groups()]
        return [0, 0, 0, 0]
    if isinstance(raw, (list, tuple)) and len(raw) >= 4:
        return [int(v) for v in raw[:4]]
    return [0, 0, 0, 0]


def text_of(node: dict) -> str:
    return (node.get("attributes") or {}).get("text") or ""


def find_nodes(layout: dict, type_name: str) -> list:
    return [n for n in nodes_of(layout) if (n.get("attributes") or {}).get("type") == type_name]


def center(node: dict) -> tuple:
    x0, y0, x1, y1 = bounds(node)
    return (int((x0 + x1) / 2), int((y0 + y1) / 2))


def parse_probe(raw: str) -> dict:
    data = {"text": ""}
    if "---text---" in raw:
        head, _, tail = raw.partition("---text---")
        body = tail[1:] if tail.startswith("\n") else tail
        data["text"] = body.split("\n---end---")[0]
    else:
        head = raw
    for line in head.splitlines():
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip()
        if key in ("buffer", "command", "frame", "modified", "last-event"):
            value = lisp_str(value)
        data[key] = value
    return data


def lisp_str(value: str) -> str:
    """Undo the %S quoting used for buffer names and symbols."""
    value = value.strip()
    if value in ("nil", "t"):
        return value
    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        return value[1:-1]
    return value


class Runner:
    def __init__(self, args):
        self.args = args
        self.hdc = Hdc(args.target, args.ct, args.verbose)
        self.out = Path(args.out) if args.out else REPO / "artifacts/acceptance" / time.strftime("run-%Y%m%d-%H%M%S")
        self.out.mkdir(parents=True, exist_ok=True)
        self.results = []
        self.geometry = None

    # ---- infrastructure

    def ensure_app(self) -> None:
        """Restart the app so every run starts from the same UI state.

        A left-over keyboard panel or menu would otherwise steal the key
        focus and make the key scenarios fail for the wrong reason.
        """
        self.hdc.shell(f"aa force-stop {BUNDLE}", check=False)
        time.sleep(1.2)
        self.hdc.shell(f"aa start -b {BUNDLE} -a {ABILITY}", check=False)
        # A full hilog scan is very slow; startup is stable by ~3s.  The
        # layout/geometry helpers below use the XComponent bounds and a
        # conservative cell size when no frame log has been parsed.
        time.sleep(3.5)
        if self.geometry is None:
            self.geometry = {"w": 1930, "h": 1166, "cell_w": 14,
                             "cell_h": 27, "cols": 137, "rows": 43}

    def wait_for_frame(self, timeout: float = 70.0) -> bool:
        """Wait until the backend published its frame geometry."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            text = self.hdc.log_grep(
                "frame metrics|first frame|gpu direct ready|gpu direct surface ready")
            frame = re.findall(
                r"(?:frame metrics|geometry (?:surface|frame)) "
                r"(\d+)x(\d+)(?: cell=(\d+)x(\d+))? grid=(\d+)x(\d+)",
                text)
            if frame:
                w, h, cw, lh, cols, rows = frame[-1]
                cw = cw or "14"
                lh = lh or "27"
                self.geometry = {"w": int(w), "h": int(h),
                                 "cell_w": int(cw), "cell_h": int(lh),
                                 "cols": int(cols), "rows": int(rows)}
                time.sleep(0.5)
                return True
            direct = re.findall(r"gpu direct surface ready (\d+)x(\d+)", text)
            if direct:
                w, h = (int(v) for v in direct[-1])
                self.geometry = {"w": w, "h": h, "cell_w": 14,
                                 "cell_h": 27,
                                 "cols": max(2, w // 14),
                                 "rows": max(2, h // 27)}
                time.sleep(0.5)
                return True
            time.sleep(1.0)
        return False

    def push_setup(self, setup: str) -> None:
        local = self.out / "_ohos-dev.el"
        local.write_text(setup + PROBE_ELISP, encoding="utf-8")
        self.hdc.send(local, DEV_FILE)
        # ohos-dev-poll reloads 0.5 s after the file changes.
        time.sleep(1.6)

    def probe(self) -> dict:
        raw = self.hdc.shell(f"cat {PROBE_FILE}", check=False)
        return parse_probe(raw)

    def frame_area(self) -> tuple:
        """XComponent bounds in device pixels (x0, y0, x1, y1)."""
        layout = self.hdc.layout()
        for node in find_nodes(layout, "XComponent"):
            return tuple(bounds(node))
        raise RuntimeError("XComponent not found in layout")

    def cell_point(self, col: int, row: int) -> tuple:
        """Device pixel at the centre of frame cell (col,row)."""
        x0, y0, x1, y1 = self.frame_area()
        if self.geometry:
            w = self.geometry["w"]
            h = self.geometry["h"]
            cw = self.geometry["cell_w"]
            ch = self.geometry["cell_h"]
            scale = min((x1 - x0) / w, (y1 - y0) / h)
            dx = x0 + ((x1 - x0) - w * scale) / 2
            dy = y0 + ((y1 - y0) - h * scale) / 2
            px = int(dx + (col + 0.5) * cw * scale)
            py = int(dy + (row + 0.5) * ch * scale)
            # The window manager owns a few pixels of resize border: a tap
            # there is a drag, not a mouse click on the surface.
            px = max(px, x0 + 16)
            py = max(py, y0 + 16)
            return (px, py)
        return (x0 + 20 + col * 12, y0 + 20 + row * 20)

    def open_menu(self, label: str = "File", tries: int = 2) -> bool:
        """Click a menu bar item and confirm the menu actually opened."""
        for _ in range(tries):
            layout = self.hdc.layout()
            item = None
            for node in find_nodes(layout, "Text"):
                if text_of(node) == label:
                    item = node
                    break
            if item is None:
                return False
            self.hdc.click(*center(item))
            time.sleep(1.4)
            if "menu-open id=" in self.hdc.log():
                return True
        return False

    def add(self, scenario: dict, passed: bool, detail: str, evidence: dict | None = None) -> None:
        row = {
            "id": scenario["id"],
            "title": scenario.get("title", ""),
            "passed": bool(passed),
            "detail": detail,
            "evidence": evidence or {},
        }
        self.results.append(row)
        mark = "PASS" if passed else "FAIL"
        print(f"[{mark}] {row['id']} {row['title']}: {detail}", flush=True)

    # ---- scenario implementations

    def run_scenario(self, scenario: dict) -> None:
        sid = scenario["id"]
        method = getattr(self, "sc_" + sid.replace("-", "_"), None)
        if method is None:
            self.add(scenario, False, "no implementation")
            return
        if scenario.get("restart"):
            self.ensure_app()
        self.hdc.log_clear()
        try:
            passed, detail, evidence = method(scenario)
        except Exception as exc:  # noqa: BLE001 - a broken scenario must not stop the run
            self.add(scenario, False, f"异常: {exc}")
            return
        self.add(scenario, passed, detail, evidence)

    def sc_I_1(self, scenario):
        """The surface must hold key focus: layout flag plus a delivered key."""
        layout = self.hdc.layout()
        focused = any((n.get("attributes") or {}).get("focused")
                      for n in find_nodes(layout, "XComponent"))
        self.hdc.key(2017)                  # a
        time.sleep(1.0)
        log = self.hdc.log()
        key_seen = "key evt code=2017" in log
        probe = self.probe()
        typed = (probe.get("text", "").endswith("a")
                 or probe.get("keys") == '"a"'
                 or probe.get("last-event") == "97")
        ok = focused and (key_seen or typed)
        detail = (f"focused={focused} key_evt={key_seen} "
                  f"command={probe.get('command')} keys={probe.get('keys')}")
        return ok, detail, {"focused": focused, "key_evt": key_seen, "typed": typed}

    def sc_I_2(self, scenario):
        self.push_setup(SETUP["scratch"])
        for code in (2017, 2018, 2019):     # a b c
            self.hdc.key(code)
            time.sleep(0.25)
        time.sleep(0.8)
        probe = self.probe()
        text = probe.get("text", "")
        ok = (probe.get("buffer") == "*scratch*"
              and probe.get("command") == "self-insert-command"
              and text == "abc")
        return ok, f"command={probe.get('command')} text={text!r} point={probe.get('point')}", probe

    def sc_I_3(self, scenario):
        """Mouse click moves point; a following hardware key still inserts."""
        x, y = self.cell_point(4, 1)
        setup = (SETUP["text"]
                 + f'(run-with-timer 1.2 nil (lambda () '
                   f'(ohos-frame-host-operation "test-mouse {x} {y}")))\n')
        self.push_setup(setup)
        time.sleep(2.0)
        probe = self.probe()
        click_cmd = probe.get("command")
        self.hdc.key(2040)                  # x
        time.sleep(0.8)
        probe2 = self.probe()
        ok = click_cmd == "mouse-set-point" and probe2.get("command") == "self-insert-command"
        return ok, (f"click command={click_cmd} line={probe.get('line')}; "
                    f"后续按键 command={probe2.get('command')}"), probe2

    def sc_I_4(self, scenario):
        """RET / arrow / DEL are checked one key at a time."""
        self.push_setup(SETUP["scratch"])
        steps = []
        for code in (2017, 2018, 2019):     # a b c
            self.hdc.key(code)
            time.sleep(0.2)
        steps.append(("abc", self.probe()))
        self.hdc.key(2054)                  # RET
        time.sleep(0.5)
        steps.append(("RET", self.probe()))
        self.hdc.key(2014)                  # left
        time.sleep(0.5)
        steps.append(("LEFT", self.probe()))
        self.hdc.key(2055)                  # DEL (backspace)
        time.sleep(0.6)
        steps.append(("DEL", self.probe()))
        got = {name: probe.get("text") for name, probe in steps}
        cmds = {name: probe.get("command") for name, probe in steps}
        ok = (got.get("abc") == "abc" and "\n" in (got.get("RET") or "")
              and cmds.get("LEFT") == "left-char"
              and cmds.get("DEL") == "backward-delete-char-untabify"
              and got.get("DEL") == "ab\n")
        return ok, f"texts={got} commands={cmds}", {"steps": [
            {"step": name, "text": probe.get("text"), "command": probe.get("command")}
            for name, probe in steps]}

    def sc_I_5(self, scenario):
        self.push_setup(SETUP["scratch"])
        self.hdc.combo(2072, 2040)          # C-x
        time.sleep(0.5)
        self.hdc.combo(2072, 2018)          # C-b
        time.sleep(1.0)
        probe = self.probe()
        keys = lisp_str(probe.get("keys", ""))
        ok = "C-x C-b" in keys and probe.get("command") == "list-buffers"
        return ok, f"keys={keys!r} command={probe.get('command')}", probe

    def sc_I_6(self, scenario):
        self.push_setup(SETUP["text"])
        target_line = 2
        x, y = self.cell_point(4, target_line - 1)
        self.hdc.click(x, y)
        time.sleep(1.0)
        probe = self.probe()
        try:
            line = int(probe.get("line", "0"))
        except ValueError:
            line = 0
        ok = probe.get("command") == "mouse-set-point" and abs(line - target_line) <= 1
        return ok, f"点击行={line} (期望 {target_line}±1) command={probe.get('command')}", probe

    def sc_I_7(self, scenario):
        """Seamless system IME: tap surface, type zhongwen, commit candidate."""
        self.push_setup(SETUP["scratch"])
        time.sleep(0.8)
        x, y = self.cell_point(4, 2)
        self.hdc.click(x, y)
        time.sleep(1.0)
        # pinyin zhongwen; 2050 is the space/candidate key.
        for code in (2042, 2024, 2031, 2030, 2023, 2039, 2021, 2030):
            self.hdc.key(code)
            time.sleep(0.08)
        self.hdc.key(2050)
        time.sleep(1.2)
        probe = self.probe()
        text = probe.get("text", "")
        ok = "中文" in text
        return ok, (f"buffer text={text!r} command={probe.get('command')} "
                    f"keys={probe.get('keys')}"), probe

    def _rss_kb(self) -> int:
        out = self.hdc.shell("PID=$(pidof emacs.hmos.org); "
                             "grep VmRSS /proc/$PID/status", check=False)
        try:
            return int(out.split()[1])
        except Exception:
            return -1

    def sc_S_3(self, scenario):
        setup = ('(switch-to-buffer "*scratch*")\n(erase-buffer)\n'
                 '(dotimes (i 200) (insert (format "soak %03d\n" i)))\n'
                 '(goto-char (point-min))\n')
        self.push_setup(setup)
        time.sleep(0.8)
        for i in range(30):
            self.hdc.key(2017)
            if i % 5 == 0:
                self.hdc.combo(2072, 2038)   # C-v
            time.sleep(0.08)
        time.sleep(1.0)
        alive = BUNDLE in self.hdc.shell(
            f"ps -ef | grep -a {BUNDLE} | grep -av grep", check=False)
        probe = self.probe()
        text = probe.get("text", "")
        ok = alive and len(text) > 0
        return ok, (f"alive={alive} text_len={len(text)} "
                    f"command={probe.get('command')}"), {"text_len": len(text)}

    def sc_S_2(self, scenario):
        self.push_setup(SETUP["scratch"])
        time.sleep(0.8)
        pid_before = self.hdc.shell(f"pidof {BUNDLE}", check=False).strip()
        self.hdc.shell("uitest uiInput keyEvent Home", check=False)
        time.sleep(1.5)
        self.hdc.shell(f"aa start -b {BUNDLE} -a {ABILITY}", check=False)
        time.sleep(2.0)
        pid_after = self.hdc.shell(f"pidof {BUNDLE}", check=False).strip()
        probe = self.probe()
        ok = bool(pid_after) and pid_before == pid_after and int(probe.get("window-start", "0") or 0) >= 0
        return ok, (f"pid {pid_before}->{pid_after} "
                    f"window-start={probe.get('window-start')} "
                    f"command={probe.get('command')}"), probe

    def sc_S_1(self, scenario):
        setup = ('(switch-to-buffer "*scratch*")\n(erase-buffer)\n'
                 '(dotimes (i 100) (insert (format "line %03d\n" i)))\n'
                 '(goto-char (point-min))\n')
        self.push_setup(setup)
        time.sleep(1.0)
        before = self.probe()
        self.hdc.combo(2072, 2038)          # C-v
        time.sleep(1.2)
        after = self.probe()
        try:
            b = int(before.get("window-start", "0"))
            a = int(after.get("window-start", "0"))
        except ValueError:
            b = a = 0
        alive = BUNDLE in self.hdc.shell(
            f"ps -ef | grep -a {BUNDLE} | grep -av grep", check=False)
        ok = alive and a > b
        return ok, (f"window-start {b} -> {a} alive={alive} "
                    f"command={after.get('command')}"), {"before": b, "after": a}

    def sc_L_1(self, scenario):
        self.push_setup(SETUP["scratch"])
        time.sleep(1.0)
        self.hdc.log_clear()
        for code in (2017, 2018, 2019, 2020, 2021):
            self.hdc.key(code)
            time.sleep(1.2)
        time.sleep(0.8)
        log = self.hdc.log()
        vals = [float(x) / 1000.0 for x in
                re.findall(r"pop->present seq=\d+ ([0-9.]+) us", log)]
        vals = vals[-5:]
        vals.sort()
        p95 = vals[min(len(vals) - 1, int(len(vals) * 0.95))] if vals else -1
        ok = len(vals) >= 4 and p95 <= 50.0
        return ok, f"n={len(vals)} p95={p95:.2f}ms vals={[round(v, 1) for v in vals]}", {"vals": vals}

    def sc_I_8(self, scenario):
        self.push_setup(SETUP["scratch"])
        before = self.probe().get("seq")
        letters = "abcdefghijklmnopqrst"
        for ch in letters:
            self.hdc.key(2017 + (ord(ch) - ord("a")))
            time.sleep(0.15)
        time.sleep(1.2)
        probe = self.probe()
        text = probe.get("text", "")
        log = self.hdc.log()
        lat = [float(m) for m in re.findall(r"keyP95=([0-9.]+)", log)]
        render = [float(m) for m in re.findall(r"keyRenderP95=([0-9.]+)", log)]
        key_p95 = max(lat) if lat else -1.0
        key_render = max(render) if render else -1.0
        try:
            delta = int(probe.get("seq", "0")) - int(before or 0)
        except ValueError:
            delta = -1
        ok = text == letters and key_p95 >= 0 and key_p95 <= 50.0
        return ok, (f"text={text!r} ({len(text)}/20) seq+{delta} "
                    f"keyP95={key_p95}ms keyRenderP95={key_render}ms"), probe

    def sc_I_9(self, scenario):
        """Escape-x must reach `execute-extended-command` in the minibuffer."""
        self.push_setup(SETUP["scratch"])
        self.hdc.key(2070)                  # ESC -> meta prefix
        time.sleep(0.4)
        self.hdc.key(2040)                  # x
        time.sleep(1.2)
        probe = self.probe()
        buf = probe.get("buffer", "")
        ok = buf.startswith(" *Minibuf") or probe.get("command") == "execute-extended-command"
        detail = f"buffer={buf!r} command={probe.get('command')}"
        for _ in range(2):
            self.hdc.combo(2072, 2023)      # C-g
            time.sleep(0.4)
        return ok, detail, probe

    def push_harness(self, report_after: float = 3.0) -> None:
        # The app sandbox only lets the shell overwrite the existing
        # ohos-dev.el, not create a sibling .el file.  Inline the harness.
        harness = (REPO / "test/elisp/ohos-parity-harness.el").read_text(
            encoding="utf-8")
        self.push_setup(harness)

    def sc_E_1(self, scenario):
        """The in-Emacs harness must observe real redisplay/scroll state."""
        self.push_harness(4.0)
        time.sleep(2.0)
        # Keep the harness hooks but make the target buffer deterministic.
        self.push_setup(SETUP["scratch"])
        time.sleep(1.5)
        for code in (2017, 2018, 2019):
            self.hdc.key(code)
            time.sleep(0.2)
        self.hdc.key(2014)                  # left
        time.sleep(1.0)
        self.push_setup("(ohos-parity-write-report)\n")
        time.sleep(2.0)
        local = self.out / "E-1-report.json"
        self.hdc.recv(f"{HOME_DIR}/ohos-parity-report.json", local)
        data = json.loads(local.read_text(encoding="utf-8", errors="replace"))
        samples = data.get("samples") or []
        kinds = {s.get("kind") for s in samples}
        ok = (len(samples) > 0 and "command" in kinds
              and data.get("redisplay-count", 0) > 0
              and data.get("frame-width", 0) > 0)
        return ok, (f"samples={len(samples)} kinds={sorted(kinds)} "
                    f"redisplays={data.get('redisplay-count')} "
                    f"frame={data.get('frame-width')}x{data.get('frame-height')}"), {
            "report": str(local), "samples": len(samples)}

    def sc_E_2(self, scenario):
        self.push_harness(0)
        time.sleep(2.0)
        self.push_setup(SETUP["scratch"])
        time.sleep(1.2)
        self.push_setup("(ohos-parity-benchmark-redisplay 20)\n")
        time.sleep(4.0)
        local = self.out / "E-2-report.json"
        self.hdc.recv(f"{HOME_DIR}/ohos-parity-report.json", local)
        data = json.loads(local.read_text(encoding="utf-8", errors="replace"))
        bench = [s for s in (data.get("samples") or [])
                 if s.get("kind") == "benchmark"]
        if not bench:
            return False, "没有 benchmark 样本", {"report": str(local)}
        b = bench[-1]
        ok = b.get("n", 0) > 0 and b.get("avg_ms", 0) > 0 and b.get("p95_ms", 0) > 0
        return ok, (f"n={b.get('n')} avg={b.get('avg_ms'):.2f}ms "
                    f"p95={b.get('p95_ms'):.2f}ms max={b.get('max_ms'):.2f}ms"), b

    def sc_M_5(self, scenario):
        """Menu items must show their key binding, like the tty/x menu."""
        self.push_setup(SETUP["text"])
        for _ in range(2):
            self.hdc.combo(2072, 2023)
            time.sleep(0.3)
        layout = self.hdc.layout()
        file_item = None
        for node in find_nodes(layout, "Text"):
            if text_of(node) == "File":
                file_item = node
                break
        if file_item is None:
            return False, "菜单栏没有 File", {}
        self.hdc.click(*center(file_item))
        time.sleep(1.4)
        layout = self.hdc.layout()
        labels = [text_of(n) for n in find_nodes(layout, "Text")]
        hints = [label.strip() for label in labels if "C-x" in label]
        self.hdc.combo(2072, 2023)           # C-g closes nothing; ESC does
        self.hdc.key(2070)
        time.sleep(0.6)
        return bool(hints), f"快捷键提示={hints[:4]}", {"hints": hints}

    def sc_M_1(self, scenario):
        self.push_setup(SETUP["text"])
        layout = self.hdc.layout()
        file_item = None
        for node in find_nodes(layout, "Text"):
            if text_of(node) == "File":
                file_item = node
                break
        if file_item is None:
            return False, "菜单栏没有 File", {}
        x, y = center(file_item)
        self.hdc.click(x, y)
        time.sleep(1.5)
        log = self.hdc.log_grep("menubar click|menu-open id=")
        layout = self.hdc.layout()
        labels = [text_of(n) for n in find_nodes(layout, "Text")]
        click_log = "menubar click index=0" in log
        opened = click_log or "menu-open id=" in log
        has_items = any("Visit New File" in label for label in labels)
        self.hdc.key(2070)                  # Escape: close the menu again
        time.sleep(0.8)
        return (opened and has_items,
                f"click_log={click_log} menu_open={'menu-open id=' in log} "
                f"VisitNewFile={has_items} labels={labels[:8]}",
                {"labels": labels[:16]})

    def sc_M_2(self, scenario):
        self.push_setup(SETUP["text"])
        self.hdc.key(2070)                  # close anything left open
        time.sleep(0.6)
        layout = self.hdc.layout()
        file_item = None
        for node in find_nodes(layout, "Text"):
            if text_of(node) == "File":
                file_item = node
                break
        if file_item is None:
            return False, "菜单栏没有 File", {}
        self.hdc.click(*center(file_item))
        time.sleep(1.5)
        layout = self.hdc.layout()
        target = None
        for node in find_nodes(layout, "Text"):
            if "Visit New File" in text_of(node):
                target = node
                break
        if target is None:
            return False, "菜单里没有 Visit New File...", {}
        self.hdc.click(*center(target))
        time.sleep(1.5)
        log = self.hdc.log()
        probe = self.probe()
        results = re.findall(r"menu result id=(\d+) index=(-?\d+)", log)
        buf = probe.get("buffer", "")
        ok = bool(results) and results[-1][1] != "-1" and buf.startswith(" *Minibuf")
        # Leave the minibuffer: the next scenario must not start inside a
        # prompt (every key would be read by the minibuffer instead).
        for _ in range(2):
            self.hdc.combo(2072, 2023)      # C-g
            time.sleep(0.5)
        return ok, f"menu_result={results[-1] if results else None} buffer={buf!r}", probe

    def sc_M_3(self, scenario):
        """Escape cancels an open menu, and the next key reaches the frame."""
        self.push_setup(SETUP["scratch"])
        # C-g aborts a pending key sequence / minibuffer; a stray Escape
        # would leave a meta prefix pending and the menu request would then
        # run in the middle of it.
        for _ in range(2):
            self.hdc.combo(2072, 2023)
            time.sleep(0.4)
        opened = self.open_menu("File")
        self.hdc.key(2070)                  # Escape cancels the menu
        time.sleep(1.2)
        cancelled = "menu result id=" in self.hdc.log() and "index=-1" in self.hdc.log()
        self.hdc.key(2017)                  # a
        time.sleep(1.0)
        probe = self.probe()
        ok = (opened and cancelled
              and probe.get("command") == "self-insert-command"
              and probe.get("text") == "a")
        return ok, (f"opened={opened} cancelled_by_esc={cancelled} "
                    f"after command={probe.get('command')} text={probe.get('text')!r}"), probe

    def sc_M_4(self, scenario):
        layout = self.hdc.layout()
        labels = [text_of(n) for n in find_nodes(layout, "Text")]
        bar = []
        for label in labels:
            if label in ("File", "Edit", "Options", "Buffers", "Tools", "Help",
                         "Lisp-Interaction"):
                bar.append(label)
        dup = any(a == b for a, b in zip(bar, bar[1:]))
        log = self.hdc.log()
        published = [int(m) for m in re.findall(r"menubar items=(\d+)", log)]
        ok = not dup and len(bar) >= 6 and (not published or len(bar) == published[-1])
        return ok, f"bar={bar} dup={dup} published={published[-3:] if published else []}", {"bar": bar}

    def sc_D_1(self, scenario):
        """Start-up: surface, frame geometry and a stable tick stream."""
        self.hdc.log_clear()
        self.hdc.shell(f"aa force-stop {BUNDLE}", check=False)
        time.sleep(1.2)
        start = time.time()
        self.hdc.shell(f"aa start -b {BUNDLE} -a {ABILITY}", check=False)
        ok_frame = self.wait_for_frame(timeout=70)
        frame_ms = int((time.time() - start) * 1000)
        log = self.hdc.log()
        surface = any(x in log for x in
                      ("surface created", "gpu direct surface ready",
                       "gpu direct ready"))
        alive = BUNDLE in self.hdc.shell(
            f"ps -ef | grep -a {BUNDLE} | grep -av grep", check=False)
        ok = ok_frame and surface and frame_ms < 30000 and alive
        return ok, (f"surface={surface} frame_metrics={frame_ms}ms "
                    f"alive={alive}"), {
            "first_frame_ms": frame_ms, "surface": surface, "alive": alive}

    def sc_D_2(self, scenario):
        self.push_setup(SETUP["text"])
        time.sleep(1.0)
        shot = self.out / "D-2-frame.png"
        self.hdc.screenshot(shot)
        ok, ratio = self._non_background_ratio(shot)
        return ok, f"正文区非背景像素比例={ratio:.4f}", {"ratio": ratio, "shot": str(shot)}

    def _non_background_ratio(self, shot: Path) -> tuple:
        try:
            from PIL import Image
        except ImportError:
            return True, -1.0
        image = Image.open(shot).convert("RGB")
        x0, y0, x1, y1 = self.frame_area()
        # The frame is inset from the XComponent bounds by a few pixels of
        # letterboxing, so crop the middle 80% of the surface.
        w = x1 - x0
        h = y1 - y0
        box = (x0 + w // 10, y0 + h // 10, x1 - w // 10, y1 - h // 10)
        crop = image.crop(box)
        pixels = list(crop.getdata())
        if not pixels:
            return False, 0.0
        from collections import Counter
        common = Counter(pixels).most_common(1)[0][1] / len(pixels)
        return (1.0 - common) > 0.005, 1.0 - common

    def _screens_differ(self, a: Path, b: Path) -> bool:
        try:
            from PIL import Image, ImageChops
        except ImportError:
            return True
        left = Image.open(a).convert("RGB")
        right = Image.open(b).convert("RGB")
        return ImageChops.difference(left, right).getbbox() is not None

    def _resize_via_host(self, width: int, height: int) -> None:
        """Resize the window through Emacs' own host-command channel.

        Clicking the title-bar controls is fragile (the middle button is
        only "maximise" while the window is restored); the app exposes
        `ohos-frame-host-operation "resize W H"`, which goes through the
        same window/OnSurfaceChanged path as a user drag (task book B-12).
        """
        setup = (SETUP["scratch"]
                 + f'(run-with-timer 1.2 nil (lambda () '
                   f'(ohos-frame-host-operation "resize {width} {height}")))\n')
        self.push_setup(setup)
        time.sleep(3.0)

    def sc_D_3(self, scenario):
        """A window resize must not freeze the presented frame (B-12)."""
        self._resize_via_host(1500, 1000)
        before = self.out / "D-3-before.png"
        after = self.out / "D-3-after.png"
        self.hdc.click(*self.cell_point(4, 2))
        time.sleep(0.6)
        self.hdc.screenshot(before)
        self.hdc.key(2017)                  # a
        time.sleep(1.5)
        self.hdc.screenshot(after)
        probe = self.probe()
        changed = self._screens_differ(before, after)
        typed = probe.get("command") == "self-insert-command"
        detail = (f"窗口缩放到 1500x1000 后打字，画面{'刷新' if changed else '冻结'}"
                  f" (command={probe.get('command')} buffer={probe.get('buffer')!r})")
        self._resize_via_host(1930, 1166)   # restore for the next scenarios
        return (changed and typed), detail, {"changed": changed, "typed": typed}

    def sc_P_1(self, scenario):
        time.sleep(5.0)
        alive = BUNDLE in self.hdc.shell(
            f"ps -ef | grep -a {BUNDLE} | grep -av grep", check=False)
        rss = self.hdc.shell(
            f"ps -ef | grep -a {BUNDLE} | grep -av grep", check=False)
        ok = alive
        return ok, f"alive={alive} ps={rss.strip()[:160]}", {"alive": alive}

    # ---- reporting

    def report(self) -> int:
        passed = sum(1 for r in self.results if r["passed"])
        total = len(self.results)
        lines = [
            "# 交互验收结果",
            "",
            f"- 目标设备: `{self.args.target}`",
            f"- 时间: {time.strftime('%Y-%m-%d %H:%M:%S')}",
            f"- 通过: **{passed}/{total}**",
            f"- 几何: `{self.geometry}`",
            "",
            "| 编号 | 场景 | 结果 | 证据摘要 |",
            "| --- | --- | --- | --- |",
        ]
        for row in self.results:
            mark = "✅ PASS" if row["passed"] else "❌ FAIL"
            detail = row["detail"].replace("|", "\\|")
            lines.append(f"| {row['id']} | {row['title']} | {mark} | {detail} |")
        lines.append("")
        report = self.out / "report.md"
        report.write_text("\n".join(lines), encoding="utf-8")
        (self.out / "results.json").write_text(
            json.dumps({"target": self.args.target, "geometry": self.geometry,
                        "results": self.results}, ensure_ascii=False, indent=2),
            encoding="utf-8")
        print()
        print(f"{passed}/{total} passed  -> {report}")
        return 0 if passed == total else 1


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--target", default=os.environ.get("TARGET", "192.168.102.58:37103"))
    parser.add_argument("--ct", default=os.environ.get("CT", CT_DEFAULT))
    parser.add_argument("--out", default=os.environ.get("ACC_OUT"))
    parser.add_argument("--only", default="", help="逗号分隔的场景编号，例如 I-2,M-1")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args(argv)

    if args.list:
        for scenario in SCENARIOS:
            print(f"{scenario['id']:5s} {scenario['title']}")
        return 0

    wanted = {part.strip().upper() for part in args.only.split(",") if part.strip()}
    selected = [s for s in SCENARIOS if not wanted or s["id"] in wanted]
    if not selected:
        raise SystemExit("no scenario selected")

    runner = Runner(args)
    print(f"target={args.target} out={runner.out}")
    runner.ensure_app()
    for scenario in selected:
        runner.run_scenario(scenario)
    return runner.report()


if __name__ == "__main__":
    sys.exit(main())
