#!/usr/bin/env python3
"""把 dsh 命令注册表/权限预设中用户可见的英文描述汉化(补丁,重装 dsh 后需重新执行)"""
import pathlib

BASE = pathlib.Path.home() / ".npm-global/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai"

REPLACEMENTS = [
    ("dsh-command-compact/lib/index.js", "Compact older conversation history", "压缩较早的对话历史"),
    ("dsh-command-goal/lib/index.js", "set or view the goal for a long-running task", "设置或查看长期任务的目标"),
    ("dsh-command-feedback/lib/index.js", "record feedback about this session", "记录关于本次会话的反馈"),
    ("dsh-plan-mode/lib/index.js", "Enter or leave plan mode", "进入或退出计划模式"),
    ("dsh-permission-presets/lib/index.js",
     "Switch the permission preset (sandbox mode + approval policy)",
     "切换权限预设（沙箱模式 + 审批策略）"),
    ("dsh-permission-presets/lib/index.js",
     "Write inside the workspace and permitted temporary directories; wider retries require approval.",
     "仅可写入工作区与允许的临时目录；更宽的写入需审批"),
    ("dsh-permission-presets/lib/index.js",
     "Full file access without approval prompts.",
     "完整文件访问，无需审批"),
    ("dsh-permission-presets/lib/index.js",
     "Current sandbox and approval settings do not match a preset.",
     "当前沙箱与审批设置不匹配任何预设"),
]

for rel, old, new in REPLACEMENTS:
    path = BASE / rel
    if not path.exists():
        print(f"skip (missing): {rel}")
        continue
    text = path.read_text(encoding="utf-8")
    if old not in text:
        print(f"skip (not found): {rel} :: {old[:40]}")
        continue
    path.write_text(text.replace(old, new), encoding="utf-8")
    print(f"patched: {rel} :: {old[:40]} -> {new}")
