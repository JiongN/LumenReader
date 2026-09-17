#!/usr/bin/env python3
"""OpenAI 兼容协议的本地桩服务，用于端到端验证 Lumen 的 AI 链路。

存在理由：验证流式解析、Markdown 渲染、引用回跳这一整条链路，需要一台
"能按 SSE 逐字吐中文"的服务端。用真实服务商意味着要消耗真实密钥，
用桩服务则可以反复跑、可预期、且完全不碰用户的任何凭据。

每个请求的 messages 会追加写入转储文件（默认 /tmp/lumen-mock-requests.jsonl），
这样才能验证「提示词到底送出去了什么」——例如跨会话记忆有没有真的拼进系统提示。
要检查最近一次请求：

    tail -1 /tmp/lumen-mock-requests.jsonl | python3 -m json.tool

    python3 tools/mock_openai_server.py 8777

桩服务会按提示词**分流**：要求「只输出 JSON」的请求（AI 智能目录的第一步）
返回一段带围栏、带客套话、且夹着越界条目的 JSON——故意做成不干净的样子，
因为「解析器够不够宽容」正是这条链路最容易出问题的地方；
其余请求返回一段中文说明文。
"""
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DUMP_PATH = os.environ.get("LUMEN_MOCK_DUMP", "/tmp/lumen-mock-requests.jsonl")

REPLY = """这段文字讨论的是**注意力机制**替代循环结构的核心动机。

- 循环网络的隐状态必须逐步传递，因此无法在时间维度上并行，序列越长训练越慢。
- 注意力把任意两个位置之间的依赖距离压缩为常数，代价是 O(n²) 的计算量。
- 作者用「路径长度」作为论据：路径越短，梯度传播越稳定。

需要注意，原文并没有给出长序列下的实测对比，这一部分属于作者的推断。"""

# 智能目录第一步的桩响应。刻意做脏：
#   - 前面带一句客套话、外面裹 markdown 围栏（模型十次有八次这样）
#   - 夹一条 unit=9999 的越界条目（必须被丢掉）
#   - 夹一条与首条完全重复的条目（必须去重）
#   - 键名混用 unit / page（两种都要认）
# 如果解析器只处理「纯 JSON」，这份响应就会解析失败——那正是我们要暴露的。
OUTLINE_REPLY = """好的，以下是这份文档的目录：

```json
[
  {"title": "第一章 引言", "unit": 1, "depth": 0},
  {"title": "研究背景", "unit": 2, "depth": 1},
  {"title": "第二章 方法", "page": 4, "depth": 0},
  {"title": "数据来源", "unit": 6, "depth": 1},
  {"title": "第三章 结果与讨论", "unit": 8, "depth": 0},
  {"title": "不存在的条目", "unit": 9999, "depth": 0},
  {"title": "第一章 引言", "unit": 1, "depth": 0}
]
```

以上为根据摘录推断出的结构。"""


def pick_reply(payload: dict) -> str:
    """按最后一条用户消息里的指令分流。"""
    messages = payload.get("messages") or []
    for message in reversed(messages):
        if message.get("role") != "user":
            continue
        content = message.get("content") or ""
        if "只输出 JSON" in content or "只输出JSON" in content:
            return OUTLINE_REPLY
        break
    return REPLY


def dump_request(payload: dict) -> None:
    """把请求落盘。失败不影响响应——这是自检工具，不该成为故障点。"""
    try:
        record = {
            "time": time.strftime("%Y-%m-%d %H:%M:%S"),
            "model": payload.get("model"),
            "stream": payload.get("stream"),
            "messages": payload.get("messages", []),
        }
        with open(DUMP_PATH, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")
    except Exception as error:  # noqa: BLE001
        print(f"[mock] 转储失败: {error}", file=sys.stderr, flush=True)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _chunk(self, data: bytes) -> None:
        self.wfile.write(f"{len(data):X}\r\n".encode() + data + b"\r\n")
        self.wfile.flush()

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        payload = {}
        try:
            payload = json.loads(raw.decode("utf-8"))
            dump_request(payload)
        except Exception:  # noqa: BLE001
            pass

        reply = pick_reply(payload)

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        # 先吐一段推理内容，验证 reasoning_content 的折叠展示
        for piece in ["先看问题指向的是动机而不是实现。", "原文强调路径长度，这点要保留。"]:
            payload_chunk = {"choices": [{"delta": {"reasoning_content": piece}, "finish_reason": None}]}
            self._chunk(f"data: {json.dumps(payload_chunk, ensure_ascii=False)}\n\n".encode())
            time.sleep(0.06)

        # 再按字符吐正文，模拟逐字流式
        step = 4
        for i in range(0, len(reply), step):
            payload_chunk = {"choices": [{"delta": {"content": reply[i:i + step]}, "finish_reason": None}]}
            self._chunk(f"data: {json.dumps(payload_chunk, ensure_ascii=False)}\n\n".encode())
            time.sleep(0.02)

        self._chunk(b"data: [DONE]\n\n")
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()

    def do_GET(self) -> None:
        body = json.dumps({"data": [{"id": "mock-chat"}, {"id": "mock-reasoner"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args) -> None:
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8777
    print(f"mock openai server on http://127.0.0.1:{port}/v1", flush=True)
    print(f"请求转储：{DUMP_PATH}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
