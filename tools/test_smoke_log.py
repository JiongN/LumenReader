import unittest

from smoke_log import diagnostic_failures, failure_lines


class SmokeLogTests(unittest.TestCase):
    def test_structured_failure_cannot_pass_without_cross(self):
        lines = "[Lumen][epub] {\"pass\":false}\n[Lumen][panel] completed passed=17 failed=1"
        self.assertEqual(len(failure_lines(lines)), 2)

    def test_success_is_not_failure(self):
        self.assertEqual(failure_lines("pass=true\npassed=17 failed=0\n✅ done"), [])

    def test_prefix_and_skip_cannot_pass(self):
        self.assertIn("missing successful diagnostic receipt: annotate",
                      diagnostic_failures("[Lumen][annotate] 自检副本准备中\n", ["annotate"]))
        self.assertIn("missing successful diagnostic receipt: epub-layout",
                      diagnostic_failures('[Lumen][epub-layout] 跳过：已取得充分读数', ["epub-layout"]))

    def test_every_receipt_must_be_successful(self):
        log = "\n".join([
            "[Lumen][annotate] 自检：通过 27 项，失败 0 项 ✅",
            '[Lumen][epub-layout] {"pass":true,"insufficient":false}',
            "[Lumen][annotation-group] completed passed=8 failed=0",
            "[Lumen][lifecycle] pass=true",
            "[Lumen][layout] 窗口内容区 920x620，共上报 12 项",
        ])
        self.assertEqual(diagnostic_failures(log, ["annotate", "epub-layout", "annotation-group", "lifecycle", "layout"]), [])
        self.assertTrue(diagnostic_failures(log.replace("失败 0 项", "失败 1 项"), ["annotate"]))


if __name__ == "__main__":
    unittest.main()
