#!/usr/bin/env python3
"""生成排版验证用的测试 EPUB。

为什么需要它：字号、行高、字距、对齐、字体这些设置**只对 EPUB 生效**（PDF 是固定版式），
要验证它们就必须有一本结构真实、且**故意带对抗性 CSS** 的电子书。

这份素材特意让书自带 CSS 去抢排版控制权：
  - `body { font-family: "Times New Roman" }`  → 测用户的字体设置能不能压过去
  - `p { text-align: justify; font-size: 15px; line-height: 1.3 }` → 测字号 / 行高 / 对齐
  - `p.centered { text-align: center }` → 测"作者显式指定的段落"是否被保留

用法：python3 tools/make_test_epub.py <输出目录>
"""

import pathlib
import sys
import zipfile

OUT_DIR = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp")
OUT_DIR.mkdir(parents=True, exist_ok=True)
TARGET = OUT_DIR / "typography.epub"

CONTAINER = """<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
"""

# 故意写得很霸道的书籍样式表，用来验证用户设置优先
BOOK_CSS = """
body { font-family: "Times New Roman", serif; font-size: 15px; line-height: 1.3; color: #111111; }
p { text-align: justify; font-size: 15px; line-height: 1.3; margin: 0 0 0.4em 0; }
p.centered { text-align: center; font-style: italic; }
blockquote { border-left: 2px solid #cccccc; padding-left: 0.8em; color: #555555; }
h1 { font-size: 1.4em; text-align: center; }
"""

OPF = """<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="bookid">lumen-typography-test</dc:identifier>
    <dc:title>排版验证样本</dc:title>
    <dc:creator>Lumen 自检</dc:creator>
    <dc:language>zh-Hans</dc:language>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="css" href="css/book.css" media-type="text/css"/>
    <item id="ch1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="ch1"/>
    <itemref idref="ch2"/>
  </spine>
</package>
"""

NAV = """<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>目录</title></head>
<body>
<nav epub:type="toc"><ol>
  <li><a href="text/ch1.xhtml">第一章 文化资本与学校</a></li>
  <li><a href="text/ch2.xhtml">第二章 家庭日常中的传递</a></li>
</ol></nav>
</body>
</html>
"""

CHAPTER_TEMPLATE = """<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="zh-Hans" lang="zh-Hans">
<head>
  <title>{title}</title>
  <link rel="stylesheet" type="text/css" href="../css/book.css"/>
</head>
<body>
<h1>{title}</h1>
{body}
</body>
</html>
"""

CH1_BODY = """
<p>在讨论教育公平的时候，我们习惯把注意力放在资源投入上：生均经费、师生比、校舍面积。这些指标当然重要，但它们解释不了一个反复出现的现象——同样的投入水平下，不同学校的学生在学业表现上的差距依然稳定存在。</p>

<p>布迪厄的文化资本理论提供了一条不同的解释路径。他指出，学校并不是一个价值中立的场域，它默认学生已经具备一套特定的语言习惯、审美趣味与行为方式，而这套东西在家庭中被无声地传递。</p>

<p class="centered">图 1-1　文化资本的代际传递路径（作者自绘）</p>

<p>Bourdieu argues that cultural capital is transmitted through everyday family practices rather than through any explicit instruction. The school, in turn, treats the resulting dispositions as natural talent.</p>

<div class="abstract-body">Many commercial EPUB files put an entire abstract paragraph directly inside a div instead of a semantic paragraph element. Lumen must translate this text as a separate block without translating its parent container twice.</div>

<blockquote>
<p>教育系统越是宣称自己中立，就越能有效地掩藏它对社会结构的再生产功能。</p>
</blockquote>

<p>这一判断对乡村学校的研究尤其有启发。当我们把目光从"缺什么"转向"默认有什么"，很多此前被归因于学生个体差异的现象，就显出结构性的一面。</p>
"""

CH2_BODY = """
<p>家庭日常中的传递很少以"教学"的形式出现。它更像是环境的一部分：书架上有什么、饭桌上聊什么、周末去哪里。孩子并不需要被专门告知什么是重要的，他只需要生活在这个环境里。</p>

<p>这正是文化资本难以被政策直接补偿的原因。经费可以拨付，校舍可以新建，但一套已经在家庭中运行了十几年的感知与表达方式，无法通过一次培训或一批设备移植过来。</p>

<p>如果这个判断成立，那么教育干预的着力点就不该只是"补资源"，而应当是让学校承认并接住那些与主流不同的文化表达方式——把它们当作资源而不是缺陷。</p>
"""


def build_chapter(title: str, body: str) -> str:
    return CHAPTER_TEMPLATE.format(title=title, body=body.strip())


def main() -> None:
    # mimetype 必须是第一个条目且不压缩，否则不是合法 EPUB
    with zipfile.ZipFile(TARGET, "w") as archive:
        archive.writestr(
            zipfile.ZipInfo("mimetype"),
            "application/epub+zip",
            compress_type=zipfile.ZIP_STORED,
        )
        archive.writestr("META-INF/container.xml", CONTAINER, compress_type=zipfile.ZIP_DEFLATED)
        archive.writestr("OEBPS/content.opf", OPF, compress_type=zipfile.ZIP_DEFLATED)
        archive.writestr("OEBPS/nav.xhtml", NAV, compress_type=zipfile.ZIP_DEFLATED)
        archive.writestr("OEBPS/css/book.css", BOOK_CSS, compress_type=zipfile.ZIP_DEFLATED)
        archive.writestr(
            "OEBPS/text/ch1.xhtml",
            build_chapter("第一章　文化资本与学校", CH1_BODY),
            compress_type=zipfile.ZIP_DEFLATED,
        )
        archive.writestr(
            "OEBPS/text/ch2.xhtml",
            build_chapter("第二章　家庭日常中的传递", CH2_BODY),
            compress_type=zipfile.ZIP_DEFLATED,
        )

    print(f"✅ 测试 EPUB：{TARGET}")
    print("   - 书自带 CSS 会抢字体/字号/行高/对齐，用来验证用户设置是否优先")
    print("   - 含一个 p.centered 段落，用来验证作者显式指定的对齐是否被保留")


if __name__ == "__main__":
    main()
