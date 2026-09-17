# 技术路线调研：academic-workbench（学术工作台）

> 调研对象：<https://github.com/wujing855/academic-workbench>　许可：MIT（`LICENSE` 原文 `Copyright (c) 2026 芬奇先生 (Finch)`）
> 调研人：Alice（产品）　日期：2026-09-17　源码快照：`main` 分支 tarball，落盘 `/tmp/aw/academic-workbench-main`（只读，未改动任何代码）
> 事实标注约定：**【README】**= 对方 README 原文；**【代码】**= 我实际读到的源码；**【外部核实】**= 我从官方站点另抓的；**【推测】**= 我的推断。抓不到的写「未能核实」。

---

## 1. TL;DR

**值得抄的三件事**：① **MinerU 把 PDF 变成结构化 Markdown**（版面阅读顺序 / 公式 LaTeX / 表格 HTML / 图片独立成文件）——这是 Lumen 今天用 PDFKit 文字层 + Vision OCR 完全拿不到的一层，且它能**纯本地离线跑**，与「零依赖单机 App」的冲突面可以控制在「一个可选的外部 helper 进程」；② **逐段对照翻译 + 分块并发 + 译文缓存 + 归档成库**——它不是「翻译一个选区」，而是「把一篇英文献变成可逐段对照的中文长文并留档」，这正是质性研究者读英文文献的真实工作流；③ **AI 服务商接阿里云百炼的 OpenAI 兼容端点**——Lumen 的「通义千问」预设已经写对了 base URL，只差把**免费档模型名**补进去，改动代价近乎为零。

**不值得抄的三件事**：① **14 面板重客户端 + 纯 Web 前端**（Lumen 是原生 macOS 三栏阅读器，定位完全不同，抄了会毁掉信息架构）；② **和风天气 / 番茄钟 / 待办 / 毕业进度条**（与「读懂一篇文献」无关，且各自都要引入一个新的第三方 Key 与配额）；③ **密钥明文放 `data/*.json`**——对方是「自己本机一个人用」的取舍，Lumen 的 Keychain 是更高一档的安全基线，绝不能为了对齐而退回去。

**最危险的一件事**：MinerU 云端引擎会把**用户的 PDF 原文上传到第三方服务器**。对方 README 明说「云端 Precision 转写」，而质性研究的访谈转录稿、田野笔记恰恰是最不能外传的材料。这一条必须当成隐私边界处理，不是性能选项。

---

## 2. 对方技术路线拆解

### 2.1 总体形态

| 项 | 事实 | 出处 |
|---|---|---|
| 形态 | 本地 Web 工作台：Python 后端 + 浏览器前端，**非桌面原生应用** | 【README】【代码】 |
| 进程 1 | `server.py`，`ThreadingHTTPServer(("127.0.0.1", 8765))`，**只绑回环** | 【代码】`server.py:39`、`:1031` |
| 进程 2 | `pdf_worker/worker.py`，`PORT = 8766`、`HOST = "127.0.0.1"` | 【代码】`pdf_worker/worker.py:PORT/HOST` |
| 依赖 | 主服务**纯标准库**；PDF 转写另起独立 venv，需 `pip install -U mineru`（torch 生态）或云端 SDK | 【README】【代码】`SKILL/SKILL.md:63-67` |
| 前后端分工 | 后端只做数据与媒体代理，**不做页面渲染**；前端 `web/app.js` 5955 行承担分块、并发、进度、缓存判定 | 【代码】`wc -l web/app.js` |
| 启动 | 双击 `start.command`：探测 8766 健康检查（`curl --noproxy '*'`），缺失 venv **静默跳过不阻断**主工作台 | 【代码】`start.command` |
| 数据 | 全部落 `data/`；真实配置被 `.gitignore` 排除，只留 `*.example.json` 模板 | 【代码】`.gitignore` |

**主服务与 worker 的关系**：`server.py` 的 `_proxy_worker()` 把 `/api/pdf/*` **原样反向代理**给 8766（`timeout=600`），并**强制 `urllib.request.ProxyHandler({})` 绕过系统代理**——注释写明「本地回环必须绕过系统代理」。worker 没起时返回 503 + 人话错误「PDF 转写引擎未启动（pdf_worker 8766 未运行）」。这是一个很干净的分工：**浏览器只跟 8765 说话，8766 是纯内部实现细节**。

### 2.2 AI 接入方式

| 项 | 事实 | 出处 |
|---|---|---|
| 端点 | `https://dashscope.aliyuncs.com/compatible-mode/v1`（阿里云百炼 OpenAI 兼容模式） | 【代码】`data/llm_config.example.json`、`worker.py:1890` |
| 请求 | `POST {base_url}/chat/completions`，`Authorization: Bearer <key>`，body `{model, messages, max_tokens, temperature, response_format?, enable_thinking?}` | 【代码】`worker.py:1895-1913` |
| 默认模型 | `default_model: "qwen3.8-flash"` | 【代码】`data/llm_config.example.json` |
| **按任务分模型** | 读 `llm_config.json` 的 `models` 字段，任务名 `summarize` / `translation` / `annotate` / `title_translation`，缺省回落 `default_model` | 【代码】`worker.py:1849-1875` |
| 推理模型兼容 | `_NO_TEMPERATURE_PREFIXES = ("kimi", "deepseek-r1")`——命中则不传 `temperature`（注释：传了会报 400） | 【代码】`worker.py:1846-1898` |
| 提速开关 | `no_thinking=True` 时对 `qwen*` 传 `enable_thinking=false`，注释「翻译不需要推理」 | 【代码】`worker.py:1899-1901` |
| JSON 输出 | `response_format={"type":"json_object"}` | 【代码】`worker.py:1902-1903` |
| SSL/代理 | 显式 `ProxyHandler({})` + `ssl.create_default_context(cafile=certifi.where())`；注释说明不挂 CA 会 `CERTIFICATE_VERIFY_FAILED`，而标题翻译是「失败静默返回原文」，**症状是标题悄悄不翻译** | 【代码】`fetchers.py:387-398` |
| 多 LLM 兜底 | 「让 AI Agent 帮忙搭」一节把 WorkBuddy / TRAE / 豆包 也列为可用模型来源 | 【README】 |

**免费额度（务必现场核对）**：
- 【README】原文两种写法并存——「每天有免费 tokens，推荐 `qwen3.8-flash`」，以及 Q&A「AI 功能报 `HTTP 403 FreeTierOnly`？免费额度**当天**用完了……或**次日**再用」。`SKILL.md` 写「各模型**每天**免费额度」。
- 【外部核实】我从阿里云开发者社区与官方 rate-limit 文档另查到：百炼对新用户是**每个模型输入/输出各 100 万 Token、开通后 90 天内有效**；`qwen3.8-flash` 确在模型列表中（rate-limit 页：`qwen3.8-flash Global 30,000 RPM / 5,000,000 TPM`）。
- **结论**：这两套口径不一致（「90 天 100 万/模型」 vs 「按日额度」），`403 FreeTierOnly` 这个报错码本身我没能在公开文档里核到。**具体额度数字属未能核实，不应直接写进 Lumen 的界面文案。** 真要用，落地时以用户自己控制台显示为准，界面只写「百炼提供免费额度，以后台为准」。

### 2.3 PDF → Markdown 解析（MinerU 的两种跑法）

**跑法 A：本地引擎**（`run_local`，`worker.py:290-331`）

```python
cmd = [MINERU_CLI, "-p", job["input"], "-o", out_dir,
       "-b", "pipeline", "-m", "auto", "-l", "ch",
       "-f", formula, "-t", table]
```

| 参数 | 含义（据代码注释） |
|---|---|
| `-b pipeline` | pipeline 后端，**纯 CPU、离线可用**（vs `vlm` 后端） |
| `-m auto` | 自动判型，必要时 OCR；注释称「与云端对齐」 |
| `-l ch` | 文档语言中文 |
| `-f true` / `-t true` | 公式识别 / 表格识别开关（默认开） |

配套的工程细节（都很值得抄）：
- **首跑要下模型权重**：进度映射里有 `("Fetching", "首次下载模型权重…", 10)`。
- **开跑前 `pkill -f <mineru-cli>` 清残留**：注释说 MinerU 3.x 会自启临时 API 子进程占端口/显存，症状是「卡在 3% 就退出」；失败**自动重试一次**。
- **必须设 `NO_PROXY=127.0.0.1,localhost,::1`**，否则 CLI 自启的本地临时 API 会被系统代理打断。
- 进度条靠 **stdout 关键字映射**（`MINERU_STAGE_MAP`：`DocAnalysis init` / `Layout Predict` / `OCR-det` / `OCR-rec` / `Table` / `Processing pages` / `Completed`）。
- 环境隔离：worker 用 `pdf_worker/.venv/bin/python` 启动，`MINERU_CLI = dirname(sys.executable)/mineru`。

**跑法 B：云端引擎**（`run_cloud`，`worker.py:337-405`）

```python
from mineru import MinerU          # 延迟导入：本地引擎不需要加载 torch/SDK
client = MinerU(token)
result = client.extract(job["input"], model="pipeline", ocr=True,
                        formula=..., table=..., language="ch", timeout=600)
markdown = result.markdown
result.save_all(cloud_out)
```

Token 来源：`data/pdf_config.json` 的 `cloud_token`，或环境变量 `MINERU_TOKEN`（SDK 默认读后者）。

【外部核实】MinerU 官方 REST 形态（`mineru.net/doc/docs/`）：`POST https://mineru.net/api/v4/extract/task`，body `{url, is_ocr, enable_formula, enable_table, language, model_version}`；查询 `GET /api/v4/extract/task/{task_id}` → `data.state`（`pending`/`running`/`converting`/`done`/`failed`）、`data.full_zip_url`。官方文档写明：**单文件 ≤200MB、≤600 页**；**每账号每天 2000 页最高优先级额度，超过 2000 页的部分优先级降低**（不是停用）。对方 README 的「每天 2000 页」与官网一致；「Token 90 天有效」在官网文档里我**没找到明说**，只在对方 `pdf_config.example.json` 里作为 `token_validity_days: 90` 存在——**【未能核实】**。
另注：仓库里云端走的是 Python SDK（`from mineru import MinerU`），而报错文案写 `pip install mineru-open-sdk`。**同一个包名/两个安装名**这件事我未能核实清楚，落地时必须实测确认，否则会复刻一个「装不上就走不通」的路径。

**能力增量（相对纯文字层）**：版面阅读顺序、标题层级、公式 → LaTeX、表格 → 结构（官方称输出 CSV/HTML/Markdown）、图片独立成文件、扫描件自动 OCR（官网称 109 种语言）。**【README】+【外部核实】**

**产物落盘**（`data/pdf_jobs/<jobId>/`）：`input.pdf`、`result.md`、`translation.md`、`reading.md`、`images/`、`local_out|cloud_out/`、`mineru.log`、`metadata.json`、`ingest.json`。

**任务调度**：`JobManager` = **单队列 + 单工作线程 + 顺序执行**（源码注释原文：「不追求并发」）。`engine` 只接受 `"local"` / `"cloud"`，非法值直接抛 `ValueError`。

### 2.4 翻译与三级对照精读

| 环节 | 事实 | 出处 |
|---|---|---|
| 分块位置 | **在前端** `web/app.js`：`chunkPdfMarkdown(md)`，按 `\n\n` 攒段，`maxChars = 2500` | 【代码】`app.js:2080-2097` |
| 并发 | `PDF_TRANS_CONCURRENCY = 5`（翻译）/ `READING_CONCURRENCY = 4`（精读） | 【代码】`app.js:2047`、`worker.py:1560` |
| 图片保护 | 翻译/精读前把 `![alt](url)` 换成 `[[IMG:n]]` 占位符，提示词第 6 条「**极其重要**……绝对不要翻译、删除、修改或移动位置」，译后还原 | 【代码】`worker.py:1570-1588`、`app.js:2099-2120` |
| 参考文献 | 精读时切掉参考文献段（`READING_REF_RE`，且**只在起始位置 >2000 字符时才切**） | 【代码】`worker.py:1565-1600` |
| 译文缓存 | 结果写 `translation.md`；前端先查 `GET /api/pdf/translation?jobId=` 命中就直接展示（**按 job 级缓存，不是按块级**） | 【代码】`app.js:2050-2077`、`worker.py:2483` |
| 归档成库 | 「存入译文库」→ `data/translations/<id>.json`（`title` / `excerpt` / `chars` / `markdown`），可列表、检索、删除 | 【代码】`worker.py:1217-1365` |
| 术语表 | `data/literature/glossary.json`，**独立「文献工具」面板的搜索表**，字段 `term` / `full_name` / `zh` / `plain_explanation` / `url`，`count = 59` | 【代码】`data/literature/glossary.json` |
| ⚠ 术语表**没有**喂给翻译 | 翻译提示词里的术语是**硬编码**的：「科学哲学与AI领域常用译法：agency→能动性、affordance→可供性、paradigm→范式……」 | 【代码】`worker.py:1930-1933` |
| 三级对照输出格式 | 精读稿结构：`## <中文小标题>` → `> <原文段落，逐字保留>` → `<中文译文>` → `**解读** <关键概念/方法思路/隐含前提/术语译法，2-4 句>` | 【代码】`worker.py:1984-1988` |
| 失败降级 | 单块失败保留原文并内嵌 `> [这一段没生成成功，先保留原文]`；**全部失败必须报 error**，注释：「否则用户看到『已完成』、打开却全是没生成成功」 | 【代码】`worker.py:1723-1755` |
| 取消语义 | 取消立即置 `cancelled` 状态（不等在跑的 4 块跑完），后台线程每块开跑前查标记，**跑完也不再写盘**（避免旧线程覆盖新任务成果） | 【代码】`worker.py:1643-1717` |
| 费用防护 | 重复点击「生成精读」不重复烧钱，直接把当前进度回给界面 | 【代码】`worker.py:1670-1676` |

### 2.5 文献资讯聚合

| 项 | 事实 | 出处 |
|---|---|---|
| 源定义 | `fetchers.py` 顶部 `SOURCES` 数组，条目字段 `key` / `name` / `kind: "rss" \| "weekly"` / `url` / `limit` / `icon` | 【代码】`fetchers.py:26-102` |
| 实际源 | Nature 最新、Science 最新、Cell 最新、Nature Communications、bioRxiv(bioinformatics)、medRxiv、Hacker News、AI Hot·卡兹克、科技爱好者周刊（阮一峰） | 【代码】`fetchers.py:33-102` |
| 解析器 | 手写通用 RSS/Atom 解析（兼容 RSS 2.0 / 1.0 RDF / Atom，`{*}` 通配命名空间）——**标准库 `xml.etree` 实现** | 【代码】`fetchers.py:183-230` |
| 标题中译 | `_llm_translate_batch`，模型优先 `models.title_translation`，**本地缓存** `data/title_translations.json`，失败静默返回原文 | 【代码】`fetchers.py:365-410` |
| arXiv | 走 `https://export.arxiv.org/api/query`，`{search_query, start, max_results, sortBy: submittedDate, sortOrder: descending}`，缓存 30 分钟 | 【代码】`fetchers.py:158` |
| 缓存 | 资讯 `CACHE_TTL = 1h`、`CACHE_MAX_AGE = 7d`（超过 7 天即使断网也不展示） | 【代码】`server.py` |
| 期刊/检索式 | `data/literature/journals.json`（40 条，含 SJR/h 指数/分区/`when_to_read`）、`search_queries.json`（11 条**已验证过**的 PubMed 检索式，带 `returned_count` 与 `pubmed_url`） | 【代码】两份 JSON |
| 天气 | 和风天气，`data/weather_config.json` 需 `api_host` **与** `api_key` 两个值 + 坐标 + 城市名 | 【代码】`data/weather_config.example.json` |

注意：**对方没有跨库文献检索**（没有 Crossref / OpenAlex / PubMed 检索入口），只有「RSS 订阅 + arXiv 板块查询 + 人工维护的检索式清单」。这跟 Lumen 现有的检索是**互补**关系，不是替代。

### 2.6 数据与配置组织

```
data/
  llm_config.json      ★ 百炼 Key（.gitignore 排除）
  pdf_config.json      ★ MinerU Token（.gitignore 排除）
  weather_config.json  ★ 和风天气 Host/Key（.gitignore 排除）
  settings.json        ☆ 领域名/学制/毕业要求/工作区目录
  literature/          journals.json · glossary.json · search_queries.json
  summaries/ translations/ readings/ reviews/   各业务归档（自动生成）
  pdf_jobs/<jobId>/    input.pdf · result.md · translation.md · reading.md · images/
  frontier/ hotspots/ digests/  AI 生成的报告 HTML/MD
```

作者自己写下的约定（`SKILL/SKILL.md`「必须遵守的约定」）：**不动 `data/` 下业务 JSON 的 schema，只加数据不改结构**；模型名**只改配置不硬编码**（`SKILL.md:108`）。密钥明文落盘是刻意的取舍——面向「本机一个人用」，`*.example.json` + `.gitignore` 兜底。

### 2.7 摘要卡片 / 研究日志 / 综述（对扎根理论工作流最相关的一块）

- **摘要卡片 `llm_summarize`**：三档 `quick`（30 秒速览）/ `standard`（标准精读）/ `deep`（深度学术评价），`max_tokens` 分别是 1500 / 5000 / 8000，`response_format=json_object`。
  - `standard` 的 JSON 字段：`one_liner` / `abstract_zh` / `abstract_en` / `keywords` / `research_question` / `methodology` / `key_findings[]` / `strengths[]` / `limitations[]` / `implications`。
  - `deep` 追加：`theoretical_contribution` / `breakthroughs[]{title,description,importance,why}` / `questions[]{question,type,impact}` / `future_directions[]`。
  - 提示词里两条对研究者真正有用的约束：「区分事实与分析，分析性内容前缀『分析：』」、「拿不准的标注『待核实』，**不要编造**」。
  - 返回后做防御性清洗 `_safe_str` / `_safe_list`（LLM 字段类型飘了也不崩）。
- **综述草稿 `generate_review`**：勾选多张卡片 → 拼成带编号的材料块 → 生成带 `[1][2]` 引用标注的中文综述骨架，落 `data/reviews/*.md`。
- **研究日志**：纯本地 JSON CRUD（`journal.json`），`type` 分类（日常等），可与摘要卡互链。

---

## 3. 对 LumenReader 的对照分析

| 能力 | 对方怎么做 | Lumen 现状 | 差距在哪 |
|---|---|---|---|
| **AI 服务商与免费额度** | 百炼 OpenAI 兼容端点；`llm_config.json` 的 `models` 字段**按任务分配模型**（summarize/translation/annotate/title_translation）；推理模型自动省略 `temperature`；`no_thinking` 对 qwen 关思考提速 | `Sources/LumenKit/Store/Settings.swift:231-269` 已有 6 个预设，其中「通义千问」`baseURL: https://dashscope.aliyuncs.com/compatible-mode/v1` **已经写对**，但 `models: ["qwen-plus","qwen-max","qwen-turbo"]` **全是付费档，没有 flash**；`AIProviderConfig` 是**单一 selectedModel，没有按用途分模型** | 差一个免费档型号 + 一层「任务→模型」映射。改动面极小、收益立竿见影 |
| **PDF 解析（电子版）** | MinerU → Markdown：版面阅读顺序、标题层级、公式→LaTeX、表格→结构、图片独立文件 | PDFKit 取文字层（`fullText()` 返回纯 String）；`extractFullText` 只产出文本+进度报告 | Lumen **拿不到结构**：双栏顺序靠文字流碰运气，公式是乱码字符，表格变散行，没有图 |
| **PDF 解析（扫描件）** | 同一套 MinerU 管线，`ocr=True` / `-m auto` 自行兜底 | `Sources/LumenKit/OCR/OCRService.swift`：`VNRecognizeTextRequest` + `.accurate`，**逐页**识别，注释明说「质量取决于源图质量」 | 都能认字，但对方多给「哪块是标题、哪块是表格、阅读顺序」；Lumen 只有行文本 + 启发式段落拼接 |
| **翻译** | 整篇分块（2500 字/块）× 5 路并行 → `translation.md` 按 job 缓存 → 归档进译文库 → 精读稿「原文/译文/解读」逐段对照 | 只有「选中内容 → 翻译」一次性请求（`PromptLibrary.swift:168-175`，指令是「只输出译文，不要加解释」）；**无缓存、无分块、无对照、无归档** | 差距最大的一项。对方把翻译做成了**产出物**，Lumen 还停在**一次动作** |
| **术语表** | `glossary.json` 独立可搜索面板（59 条，四件套体例） | 无。`PromptLibrary` 里只有「概念与术语抽取」模板（一次性抽取，不沉淀） | 对方的关键**教训**：它的术语表也**没接进翻译流程**（提示词里是硬编码的领域词表）——这是它自己没做完的地方，Lumen 要做就得真接进去 |
| **文献检索** | 无跨库检索；只有 RSS 订阅 + arXiv 板块 + 人工维护的检索式清单 | `WebLiteratureSearch.swift`：**Crossref + OpenAlex + arXiv 三源并发**，最多 3 次指数退避（0.8→1.6s，封顶 2.4s），只对 429/408/5xx/超时/断连重试，单源失败不影响其余且如实上报；Semantic Scholar 因共享配额 429 被实测淘汰 | Lumen 在「检索」这一维**领先**；差距在**「订阅」**——Lumen 每次都要用户主动提问才去查，没有「早上打开就看到新文献」 |
| **资讯订阅** | 9 个源（含期刊 RSS）自动抓取 + 顶刊标题自动中译 + 1h 缓存 | 无 RSS / 无订阅 / 无定时 | 教育学可加：**ERIC**（有公开 API）、期刊 RSS（如 *British Journal of Sociology of Education*、*Teaching and Teacher Education*）、以及教育学预印本源 |
| **摘要卡片与知识归档** | 按**篇**的结构化 JSON 卡片（三档深度）+ 标签建议 + 研究日志 + 多卡片合成综述 | 按**节**的摘要（`SmartOutline` 两步走：骨架一次请求 → 单节摘要按需生成并缓存进 `smart-outline.json`）；批注（PDF 写回原文件 / EPUB 存数据目录）；`memory.json` 跨会话记忆 | Lumen 有「书的骨架」，没有「文献的卡片层」；没有跨文档可检索的归档；也没有「多篇 → 一篇综述」的路径。**对扎根理论**：卡片 = 编码单元，日志 = 备忘录（memo），综述 = 理论饱和后的写作——对方这条流水线跟扎根理论的三级编码是**同构**的 |
| **隐私模型** | 密钥明文在 `data/*.json`；PDF 可选**上传到 MinerU 云端** | API Key 只进 Keychain（`AIKeychain.swift`），不落盘不进日志；无云端：BYOK 直连用户自己的端点 | Lumen 的信任模型更严。**引入 MinerU 云端会打破它**——详见第 5 节 |

---

## 4. 分级落地建议

> 每条给出：① 收益 ② 成本（改哪些模块 / 是否引入新依赖或新进程）③ 与「零依赖单机 App + BYOK」定位是否冲突 ④ 优先级。

### P0-1　百炼免费档进预设 + 「按任务分模型」

- **收益**：用户开箱即有一个「不用付费也能跑」的 AI 通道；翻译/摘要这类高频、低难度任务走小模型，省的是真金白银；`baseURL` 已经对了，属于「补齐最后一块」。
- **成本**：只动 `Sources/LumenKit/Store/Settings.swift` 的 `AIProviderConfig.presets`（加型号）+ `AIProviderConfig` 加一个可选的 `taskModels: [String: String]` 映射，以及在 `AIChatModel` 取模型时按 `PromptTask` 查一次。**不引入任何依赖**。
- **冲突**：不冲突，反而强化 BYOK——用户自带 Key，端点仍是百炼的 OpenAI 兼容口。
- **注意**：**不要把「每天 N 次免费」写进界面文案**，我没能核实到该口径（见 2.2）。文案写「百炼提供免费额度，以控制台为准」。
- **优先级**：**P0**（投入产出比最高）。

### P0-2　逐段对照翻译 + 译文缓存 + 术语表

- **收益**：这是「英文献能不能读下去」的分水岭。质性研究者读英文文献的痛点不是「某个词不认识」，而是「整段读不顺、读完不知道这段在论证什么」。逐段对照 + 解读，等于把精读过程本身变成产物。
- **成本**：
  - `PromptLibrary.swift` 加 `case translatedReading(span:)` 与对照体提示词（原文逐字 → 译文 → 解读，三层）；
  - 新增 `Sources/LumenKit/AI/TranslationStore.swift`（按 `文档哈希 + 段落区间` 缓存，落 `docs/<hash>/translation.json`，与现有 `ReaderBridge` 的 `slicesProvider` / `sectionTextProvider` 复用分块口径）；
  - 新增术语表存储 `glossary.json`（沿用对方四件套字段 `term/full_name/zh/explanation`），**并且真的要注入提示词**（对方没做到）；
  - UI：阅读区加「对照」显示模式（PDF 用 `PDFKit` 的分页切片，EPUB 用 `WKWebView` 注入）。
- **冲突**：不冲突。全部本地，全部走用户自己的 Key。成本是**界面工作量**（三栏布局要再挤一个对照模式），不是依赖。
- **优先级**：**P0**（与 Lumen「帮人读懂一篇文献」的定位同频）。

### P1-3　MinerU 作为**可选**本地解析后端（只走本地 HTTP，App 内不引 Python）

- **收益**：拿到 Lumen 现在完全没有的四样东西——**公式 LaTeX**、**表格结构**、**双栏阅读顺序**、**版面层级**。教育社会学文献表格与统计结果多，双栏排版普遍，这三样直接决定「AI 读到的正文是不是人类读到的那篇」。
- **成本**：
  - 新增 `Sources/LumenKit/Document/MarkdownParserClient.swift`：**只做 HTTP 客户端**，请求 `http://127.0.0.1:8766`（沿用对方端口便于用户复用现成 worker）；
  - 配套一个 `tools/mineru_worker/` 的启动脚本 + 说明文档，**不进 App bundle、不 link 任何东西**；
  - 探测逻辑：启动/打开文档时 `GET /api/health`，2 秒超时；不可达就**静默降级为现有 Vision OCR**（对方 `start.command` 的「缺失 venv 静默跳过」就是这个模式，验证过可行）；
  - 产物落到 Lumen 的 `docs/<hash>/` 而不是 `pdf_jobs/`。
- **冲突**：**有冲突面，但可控**。冲突在于「用户要多装一个 Python 环境 + torch + 首次下模型权重（数 GB）」。缓解办法：① 它是**可选增强**，不装一切照旧；② App 本身仍然零依赖——依赖落在**用户自己的 helper 进程**里，跟 Lumen 的 build 完全解耦；③ 界面上如实写清「本地引擎需要额外安装 MinerU，首次运行会下载模型」。遵守 README 硬约束第 5 条：「给用户看的设置项若只是部分生效，属于欺骗性设计」。
- **明确不做的**：**不接 MinerU 云端引擎**（第 5 节单独说）。
- **优先级**：**P1**（价值高，但排在 P0 之后——先把「读」做顺，再升级「解析质量」）。

### P1-4　PDF 结构化摘要卡片 / 研究日志

- **收益**：现在的「AI 智能目录」是**书的骨架**；补齐**文献的卡片层**（按篇的结构化摘要 + 标签 + 可检索归档）才让 1296 本 PDF 从「一堆文件」变成「可回溯的知识库」。对扎根理论尤其对味：卡片 ≈ 编码单元，日志 ≈ 备忘录。
- **成本**：复用 `SmartOutline` 已有的「两步走 + 落盘缓存」范式，新增 `SummaryCardStore`（`docs/<hash>/card.json`）+ 一个侧栏页签 + 一个卡片列表视图。**不改依赖**。
- **冲突**：不冲突。注意不要照抄对方「14 面板」的组织方式——Lumen 的侧栏页签顺序即快捷键编号（`⌘1`–`⌘5`），新增页签是**对用户的可见变更**，需要同步交付说明。
- **优先级**：**P1**。
- **建议的最小字段集**（借对方的字段名，砍掉用不上的）：`one_liner` / `keywords` / `research_question` / `methodology` / `key_findings` / `limitations` / `implications`，**不要一上来做三档深度**——先做 `standard` 一档，确认有人用再加档。

### P1-5　期刊 RSS / 文献订阅

- **收益**：把「检索」从「我想到了才去查」变成「每天有新的摆在面前」。这是 Lumen 相对对方的**唯一短板**。
- **成本**：新增 `Sources/LumenKit/Literature/FeedFetcher.swift`（`URLSession` + `XMLParser`，**同样零依赖**），源清单落 `settings.json`（教育学预置一批：ERIC API、目标期刊 RSS）；定时抓取用 `Timer`/`BGTaskScheduler` 或「打开 App 时若缓存超 1h 就刷新」（后者更简单、更符合单机 App 的形态）。
- **冲突**：不冲突。**但不要抄对方的「9 源大杂烩」**——Hacker News 与科技周刊对教育社会学研究者是噪音。源要**可删可加**，默认只留用户领域的。
- **优先级**：**P1**。

### P2-6　多卡片合成综述草稿

- **收益**：理论饱和之后写综述，是研究后半程最费时的环节；把已归档卡片勾选后合成带引用标注的骨架，能省下大量誊抄。
- **成本**：复用 P1-4 的卡片存储，新增一条「勾选 → 拼材料 → 生成」的提示词与视图。
- **冲突**：不冲突，但它**依赖 P1-4 先落地**（没有卡片层就没有材料）。另外必须防「模型编造材料之外的结论」——提示词要照抄对方那条「忠于给定材料，不要编造材料之外的结论」。
- **优先级**：**P2**。

### 明确**不建议抄**的部分

| 不抄 | 理由 |
|---|---|
| **和风天气** | 与「读懂文献」零关系，却要再引入一个第三方 Key + 每日配额 + `api_host`/`api_key` 双值配置。为一个天气卡片增加一条外部依赖链不值得 |
| **番茄钟 / 待办 / 毕业进度条** | 同上。这是「个人工作台」的功能，不是「阅读器」的功能。加了会把 Lumen 的信息架构往重客户端方向拖 |
| **14 面板式客户端** | Lumen 的三栏（侧栏 / 阅读区 / AI 面板）已经收敛；14 个平铺面板对原生 macOS App 是不可维护的 |
| **纯 Web 前端 + 双进程 proxy** | 对方是「浏览器 + 本地 HTTP 服务」，是被形态逼出来的架构。Lumen 是原生 App，不需要也不应该引入一层 8765 代理 |
| **前端做分块与并发** | 对方把 2500 字分块、5 路并发、进度计算全放在 `app.js` 里（`chunkPdfMarkdown` 与 Python 侧的 `_reading_chunks` **是两份实现**，作者自己在注释里也承认「口径只此一份」是后来才统一的）。Lumen 的 `LumenKit` 分层正是为了「业务逻辑能脱离界面被验证」——分块口径必须只有一份，放在 `LumenKit` |
| **密钥明文落 `data/*.json`** | Lumen 的 Keychain 是更高基线，退回去是净损失 |
| **单队列串行 worker + 内存态进度** | 对方进度存内存，worker 重启即丢、前端退回「未生成」。Lumen 的状态一律落盘（`state.json` / `smart-outline.json`），这条不能降级 |
| **靠 `pkill -f mineru` 清残留进程** | 对「用户开着别人的东西」的本机是危险动作。Lumen 侧若做 helper，只探健康检查、不杀进程 |

---

## 5. 风险与边界

1. **免费额度的时效性（高）**
   对方的额度数字是**它写作时的**状态。我已核到百炼「新用户每模型 100 万 Token / 90 天」这条公开口径，与对方 README 的「每天免费」**不一致**；MinerU 的「每天 2000 页」与官网一致，但「Token 90 天有效」**未能核实**。任何写进 Lumen 界面或文档的额度数字，都必须注明「以后台为准」，并在实现时用**运行时探测**（HTTP 403 / 429 的具体错误码）而不是硬编码数字来提示用户。

2. **MinerU 云端 = 研究材料外传（**最高**，单独强调）**
   对方的 `run_cloud` 用 SDK 把**本地 PDF 文件**提交到 MinerU 服务器解析。对「AI × 生物学」这类已发表论文，这是可接受的；但对**质性研究**，这意味着把**访谈转录稿、田野笔记、未发表的手稿、含受访者身份的转写件**送进第三方服务器。这与 Lumen 的核心承诺（「这些 AI 能力全部走**用户自己的**端点，不经过任何中间服务」）是**直接冲突**的。
   **结论**：MinerU 只能以**本地引擎**形式引入；若将来真要考虑云端，必须（a）默认关闭、（b）每次上传前弹出**逐文件**确认并列出将外传的文件名、（c）在设置页明确写出「材料会上传到第三方服务器」、（d）不与「零云端」的宣传语并存。**建议：不做云端，只做本地。**

3. **MIT 许可与署名义务（中）**
   `LICENSE` 为 MIT，`Copyright (c) 2026 芬奇先生 (Finch)`。**「随便用、随便改，保留版权声明即可」是对方 README 的原话，这条对代码和文档都成立。** 若 Lumen 直接搬运其**提示词文本**（如 `llm_translate` 的九条翻译规则、`llm_annotate` 的精读结构），那些文本也是受版权保护的作品——必须在 `docs/` 或源码注释里保留出处与许可声明，或自行重写。**建议：提示词自行重写（顺带把领域从「科学哲学 × AI」改成教育学），只在文档里承认思路来源。**

4. **对方代码是「给别人填空」的骨架（中）**
   `SKILL/SKILL.md` 第 0 步原话：「**不要直接改代码**。先向用户确认四件事」。它的资讯源关键词、前沿瞭望主题、检索式、示例数据**全部是留给用户改的占位**。照搬会得到一个写着别人研究领域的壳。**这一条反而是最有价值的借鉴**：Lumen 若要送教育学者用，也该有类似的「先问再配」的引导，而不是让人自己去翻设置。

5. **维护负担（中）**
   引入 MinerU 本地引擎 = 多一个 Python venv + torch 生态 + 数 GB 模型权重 + 一个跨版本的 CLI 参数契约（`-b pipeline -m auto -l ch -f -t`）+ 一个我**没能核实清楚**的包名问题（`mineru` vs `mineru-open-sdk`）。Lumen 现在是「纯 SwiftPM、无外部依赖、`build.sh` 一把梭」。这条边界一旦松动，后续每次 Swift 侧改动都要连带回归 Python 侧。**建议：把 helper 完全放在 `tools/` 下，App 侧只认 HTTP 契约与健康检查，把耦合压到「两个端点 URL」这么薄。**

6. **不要为了对齐而降低验证标准（中）**
   Lumen 的 README 与 `VERIFY.md` 建立了一套硬约束（断言必须可被证伪、产物必须外部可核对）。对方的代码里有若干「失败静默」路径（标题翻译失败返回原文、精读单块失败保留原文），这些在它的场景下是合理的降级，但在 Lumen 里必须**同时写进日志并让用户可见**——否则就会复刻硬约束第 5 条「欺骗性设计」和第 8 条「恒真断言」。

---

## 6. 参考来源（实际抓取的 URL）

**对方仓库（全部实际抓取，源码快照落盘 `/tmp/aw/academic-workbench-main`）**
- `https://github.com/wujing855/academic-workbench/blob/main/README.md`
- `https://raw.githubusercontent.com/wujing855/academic-workbench/main/server.py`
- `https://raw.githubusercontent.com/wujing855/academic-workbench/main/pdf_worker/worker.py`
- `https://raw.githubusercontent.com/wujing855/academic-workbench/main/pdf_worker/run_cloud.py`
- `https://raw.githubusercontent.com/wujing855/academic-workbench/main/data/llm_config.example.json`
- `https://api.github.com/repos/wujing855/academic-workbench/git/trees/main?recursive=1`（文件树）
- `https://codeload.github.com/wujing855/academic-workbench/tar.gz/refs/heads/main`（完整快照，用于逐文件核对 `fetchers.py` / `web/app.js` / `web/index.html` / `SKILL/SKILL.md` / `data/**` / `LICENSE` / `.gitignore` / `start.command`）

**外部核实**
- `https://mineru.net/doc/docs/`（官方 API 文档：`/api/v4/extract/task`、请求/响应字段、200MB/600 页、每天 2000 页最高优先级）
- `https://mineru.net/`（官方首页：表格/公式/OCR 能力宣称）
- `https://help.aliyun.com/en/model-studio/rate-limit`（百炼模型列表与限流：含 `qwen3.8-flash Global 30,000 RPM / 5,000,000 TPM`）
- `https://developer.aliyun.com/article/1760713`（百炼新人免费额度：每模型输入/输出各 100 万 Token、90 天有效、70+ 模型）

**LumenReader 侧只读核对（未改动）**
- `README.md`、`docs/ARCHITECTURE.md`
- `Sources/LumenKit/Store/Settings.swift`（`AIProviderConfig.presets`）
- `Sources/LumenKit/AI/PromptLibrary.swift`（`case translate`、精读/摘要提示词入口）
- `Sources/LumenKit/AI/WebLiteratureSearch.swift`（Crossref / OpenAlex / arXiv 端点）
- `Sources/LumenKit/OCR/OCRService.swift`
- `Sources/LumenKit/Document/DocumentModel.swift`、`Document/EPUB/EPUBDocument.swift`（`fullText()`）

**明确未能核实**
- 百炼「按日免费额度」的确切数值与 `HTTP 403 FreeTierOnly` 这一错误码的官方解释（对方 README 与 SKILL.md 的口径与公开文档不一致）。
- MinerU Token「90 天有效」的官方出处（仅见于对方 `pdf_config.example.json` 的 `token_validity_days: 90`）。
- 云端 SDK 的真实包名：代码里 `from mineru import MinerU`，但报错文案写 `pip install mineru-open-sdk`，两者是否同一发行包**未核实**，落地前必须实测。
- 对方仓库的 `data/pdf_worker.log` / 实际运行日志（未在仓库中）。
