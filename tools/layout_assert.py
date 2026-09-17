#!/usr/bin/env python3
"""对 `--layout-report 1` 的输出做几何断言。

用法：
    python3 tools/layout_assert.py <日志目录或日志文件>...

为什么需要它：面板宽度算错 2px、控件被挤出可视区半个身位、三栏之间出现 1px 叠影——
这些情况下进程照样正常退出，截图也照样有内容。在**看不到图**的环境里，
「截图非空 + 没崩溃」是最容易骗过自己的两条断言。所以这里把每个探针的 frame
当数据验：包含关系、重叠关系、铺满关系。

预期不是靠文件名猜的，而是**从日志里的启动参数推导**——
日志第一行就记着 `--sidebar 0 --ai 1` 这类开关，拿它当预期比拿文件名当预期可靠得多。

退出码：全通过 0，有失败 1。
"""
import glob
import os
import re
import sys

PROBE = re.compile(
    r"\[Lumen\]\[layout\]\s+(\w+)\s+x=\s*([-\d.]+)\s+y=\s*([-\d.]+)\s+"
    r"w=\s*([-\d.]+)\s+h=\s*([-\d.]+)\s+maxX=\s*([-\d.]+)\s+maxY=\s*([-\d.]+)"
)
WINDOW = re.compile(r"窗口内容区\s+(\d+)x(\d+)，共上报\s+(\d+)\s+项")
ARGV = re.compile(r"启动参数：(.*)$")

TOL = 1.0  # 浮点与单像素取整的容差


def last_flag(args, flag):
    """从启动参数里取开关值，取最后一次出现。没传则返回 None。"""
    values = re.findall(rf"{re.escape(flag)}\s+(\S+)", args)
    return values[-1] if values else None


def check(path):
    name = os.path.basename(path)
    text = open(path, encoding="utf-8", errors="replace").read()
    fails = []

    m = WINDOW.search(text)
    if not m:
        return name, ["没有窗口内容区上报（布局探针没生效，或截图抢在 dump 之前退出了）"]

    win_w, win_h, claimed = int(m.group(1)), int(m.group(2)), int(m.group(3))
    probes = {
        p.group(1): {
            "x": float(p.group(2)), "y": float(p.group(3)),
            "w": float(p.group(4)), "h": float(p.group(5)),
            "maxX": float(p.group(6)), "maxY": float(p.group(7)),
        }
        for p in PROBE.finditer(text)
    }

    if len(probes) != claimed:
        fails.append(f"上报条数不符：声称 {claimed} 项，实际解析出 {len(probes)} 项")

    # ① 任何探针都不得越出窗口内容区，且 maxX/maxY 要与 x+w/y+h 自洽
    for key, f in probes.items():
        if f["x"] < -TOL or f["y"] < -TOL:
            fails.append(f"{key} 左上越界 x={f['x']} y={f['y']}")
        if f["maxX"] > win_w + TOL or f["maxY"] > win_h + TOL:
            fails.append(f"{key} 右下越界 maxX={f['maxX']} maxY={f['maxY']}（窗口 {win_w}x{win_h}）")
        if abs(f["maxX"] - (f["x"] + f["w"])) > TOL:
            fails.append(f"{key} maxX 与 x+w 不自洽：{f['maxX']} vs {f['x'] + f['w']}")
        if abs(f["maxY"] - (f["y"] + f["h"])) > TOL:
            fails.append(f"{key} maxY 与 y+h 不自洽：{f['maxY']} vs {f['y'] + f['h']}")

    # ② 三块面板横向不得重叠
    panels = [k for k in ("sidebar", "readerSurface", "aiPanel") if k in probes]
    ordered = sorted(panels, key=lambda k: probes[k]["x"])
    for left, right in zip(ordered, ordered[1:]):
        gap = probes[right]["x"] - probes[left]["maxX"]
        if gap < -TOL:
            fails.append(f"{left} 与 {right} 横向重叠 {abs(gap):.1f}px")

    # ③ 面板必须铺满宽度：最左贴 0，最右贴窗口宽
    if ordered:
        if probes[ordered[0]]["x"] > TOL:
            fails.append(f"最左面板 {ordered[0]} 左侧留白 {probes[ordered[0]]['x']:.1f}px")
        rightmost = probes[ordered[-1]]["maxX"]
        if abs(rightmost - win_w) > TOL:
            fails.append(f"最右面板右边缘 {rightmost:.1f} 未贴到窗口宽 {win_w}")

    # ④ 面板可见性：预期从日志里的启动参数推导。
    #    「收起」必须是探针消失，而不是宽度缩成 0 继续占位——
    #    后者在截图里看不出区别，却会让键盘焦点与快捷键落在看不见的控件上。
    argv = (ARGV.search(text).group(1) if ARGV.search(text) else "")
    expect = {"--sidebar": ("sidebar", "--sidebar"), "--ai": ("aiPanel", "--ai")}
    for flag, (probe, _) in expect.items():
        raw = last_flag(argv, flag)
        if raw is None:
            continue
        visible = raw.strip() not in ("0", "false", "no")
        present = probe in probes
        if visible and not present:
            fails.append(f"{flag} 要求显示，但没有 {probe} 探针")
        if not visible and present:
            fails.append(f"{flag} 要求收起，但 {probe} 探针仍在上报（疑似缩成 0 宽占位）")

    # ⑤ 状态条必须落在正文区水平范围内（跑到侧栏/AI 面板底下就是错位）
    if "statusChip" in probes and "readerSurface" in probes:
        chip, reader = probes["statusChip"], probes["readerSurface"]
        if chip["x"] < reader["x"] - TOL or chip["maxX"] > reader["maxX"] + TOL:
            fails.append(
                f"statusChip 超出正文区：chip[{chip['x']:.1f},{chip['maxX']:.1f}] "
                f"vs reader[{reader['x']:.1f},{reader['maxX']:.1f}]"
            )

    return name, fails


def expand(paths):
    out = []
    for p in paths:
        if os.path.isdir(p):
            out.extend(sorted(glob.glob(os.path.join(p, "*.log"))))
        else:
            out.extend(sorted(glob.glob(p)))
    return out


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2

    logs = expand(sys.argv[1:])
    if not logs:
        print("没有找到日志")
        return 2

    failed = 0
    for path in logs:
        name, fails = check(path)
        if fails:
            failed += 1
            print(f"FAIL {name}")
            for f in fails:
                print(f"       · {f}")
        else:
            print(f"PASS {name}")

    print("=" * 40)
    print(f"几何断言：{len(logs) - failed} / {len(logs)} 通过")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
