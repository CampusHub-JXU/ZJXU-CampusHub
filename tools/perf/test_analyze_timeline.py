import sys
import unittest
import json
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from analyze_timeline import compare, summarize


class TimelineAnalyzerTests(unittest.TestCase):
    def setUp(self):
        self.trace = {
            "scenario": "settings/baseline",
            "duration_us": 20_000,
            "events": [
                {"name": "BUILD", "ph": "X", "dur": 2_000, "args": {"text": "must not escape"}},
                {"name": "LAYOUT", "ph": "B", "ts": 1_000, "tid": 7},
                {"name": "LAYOUT", "ph": "E", "ts": 4_000, "tid": 7},
                {"name": "PAINT", "ph": "X", "dur": 500},
                {"name": "GPURasterizer::Draw", "ph": "X", "dur": 8_000},
                {"name": "Animator::BeginFrame", "ph": "B", "ts": 5_000, "tid": 6},
                {"ph": "E", "ts": 21_000, "tid": 6},
                {"name": "Build", "ph": "B", "ts": 10_000, "tid": 8},
                {"name": "unmatched", "ph": "E", "ts": 12_000, "tid": 9},
                {"name": "incomplete", "ph": "B", "ts": 13_000, "tid": 8},
                {"name": "No duration", "ph": "X"},
            ],
        }

    def test_summarizes_complete_trace_event_forms(self):
        result = summarize(self.trace)
        self.assertEqual(result["duration_ms"], 20)
        self.assertEqual(result["groups"]["build"]["median_ms"], 2)
        self.assertEqual(result["groups"]["layout"]["median_ms"], 3)
        self.assertEqual(result["groups"]["paint"]["median_ms"], 0.5)
        self.assertEqual(result["groups"]["raster"]["p95_ms"], 8)
        self.assertEqual(result["groups"]["frame"]["max_ms"], 16)
        self.assertEqual(result["completed_duration_events"], 5)

    def test_summary_drops_event_args_and_sanitizes_user_label(self):
        result = summarize(self.trace)
        rendered = str(result)
        self.assertNotIn("must not escape", rendered)
        self.assertNotIn("/", result["scenario"])

    def test_nested_begin_end_pairs_ignore_end_name_and_survive_chunk_order(self):
        result = summarize({"events": [
            {"name": "Animator::BeginFrame", "ph": "B", "ts": 10_000, "pid": 1, "tid": 2},
            {"name": "Nested", "ph": "B", "ts": 10_100, "pid": 1, "tid": 2},
            {"ph": "E", "ts": 10_400, "pid": 1, "tid": 2},
            {"ph": "E", "ts": 11_000, "pid": 1, "tid": 2},
        ]})
        self.assertEqual(result["groups"]["frame"]["count"], 1)
        self.assertEqual(result["groups"]["frame"]["max_ms"], 1)
        self.assertNotIn("/", result["scenario"])

    def test_named_end_mismatch_and_incomplete_pairs_are_reported(self):
        result = summarize({"events": [
            {"name": "GPURasterizer::Draw", "ph": "B", "ts": 1_000, "pid": 1, "tid": 3},
            {"name": "WrongSpan", "ph": "E", "ts": 2_000, "pid": 1, "tid": 3},
            {"ph": "E", "ts": 3_000, "pid": 1, "tid": 4},
            {"name": "incomplete", "ph": "B", "ts": 4_000, "pid": 1, "tid": 3},
        ]})
        self.assertEqual(result["groups"]["raster"]["count"], 0)
        self.assertEqual(result["pairing_diagnostics"], {
            "unmatched_end": 1, "unmatched_begin": 2, "named_end_mismatch": 1,
            "target_unmatched_end": 0, "target_unmatched_begin": 1,
            "target_named_end_mismatch": 0,
        })

    def test_unrelated_named_end_does_not_implicate_pending_target_span(self):
        result = summarize({"events": [
            {"name": "LAYOUT", "ph": "B", "ts": 1_000, "pid": 1, "tid": 3},
            {"name": "Dart_StringToUTF8", "cat": "API", "ph": "E",
             "ts": 2_000, "pid": 1, "tid": 3},
        ]})
        self.assertEqual(result["pairing_diagnostics"]["named_end_mismatch"], 1)
        self.assertEqual(result["pairing_diagnostics"]["target_named_end_mismatch"], 0)
        self.assertEqual(result["pairing_diagnostics"]["target_unmatched_begin"], 1)

    def test_startup_window_anchors_to_first_frame_not_capture_start(self):
        from analyze_timeline import _selected_summary

        trace = {"capture_start_us": 100, "events": [
            {"name": "Startup work", "ph": "X", "ts": 200, "dur": 100},
            {"name": "Animator::BeginFrame", "ph": "B", "ts": 10_000, "tid": 4},
            {"name": "Animator::BeginFrame", "ph": "E", "ts": 11_000, "tid": 4},
            {"name": "Animator::BeginFrame", "ph": "B", "ts": 3_010_000, "tid": 4},
            {"name": "Animator::BeginFrame", "ph": "E", "ts": 3_011_000, "tid": 4},
        ]}
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", encoding="utf-8", delete=False) as file:
            json.dump(trace, file)
            path = file.name
        try:
            result = _selected_summary(path, None, None, None, True)
        finally:
            Path(path).unlink()
        self.assertEqual(result["window_anchor"], "first-Animator::BeginFrame")
        self.assertEqual(result["groups"]["frame"]["count"], 1)
        self.assertEqual(result["groups"]["frame"]["interval_ms"]["count"], 0)

    def test_named_overlapping_spans_on_same_thread_pair_by_name(self):
        result = summarize({"events": [
            {"name": "Animator::BeginFrame", "ph": "B", "ts": 1_000, "pid": 1, "tid": 3},
            {"name": "GPURasterizer::Draw", "ph": "B", "ts": 1_100, "pid": 1, "tid": 3},
            {"name": "Animator::BeginFrame", "ph": "E", "ts": 2_000, "pid": 1, "tid": 3},
            {"name": "GPURasterizer::Draw", "ph": "E", "ts": 3_000, "pid": 1, "tid": 3},
        ]})
        self.assertEqual(result["groups"]["frame"]["max_ms"], 1)
        self.assertEqual(result["groups"]["raster"]["max_ms"], 1.9)
        self.assertEqual(result["pairing_diagnostics"], {
            "unmatched_end": 0, "unmatched_begin": 0, "named_end_mismatch": 0,
            "target_unmatched_end": 0, "target_unmatched_begin": 0,
            "target_named_end_mismatch": 0,
        })

    def test_cpu_profile_summary_is_windowed_and_omits_source_urls(self):
        from analyze_timeline import summarize

        result = summarize({"events": [], "cpu_profile": {
            "samplePeriod": 1000,
            "functions": [
                {"function": {"name": "HomePage.build"}, "resolvedUrl": "file:///private/source.dart"},
                {"function": {"name": "SettingsPage.build"}, "resolvedUrl": "file:///private/other.dart"},
                {"function": {"name": "[Native] /data/app/private/install/lib.so"}},
            ],
            "samples": [
                {"timestamp": 1000, "stack": [0]},
                {"timestamp": 1500, "stack": [1, 0]},
                {"timestamp": 3000, "stack": [0]},
                {"timestamp": 1500, "stack": [2]},
            ],
        }}, 1000, 2000)
        self.assertEqual(result["cpu_profile"]["sample_count"], 3)
        rendered = str(result["cpu_profile"])
        self.assertIn("SettingsPage.build", rendered)
        self.assertNotIn("file:///", rendered)
        self.assertNotIn("private/source.dart", rendered)
        self.assertNotIn("/data/app/private", rendered)
        self.assertIn("native-code", rendered)

    def test_comparison_reports_positive_slowdown_and_missing_data(self):
        baseline = summarize(self.trace)
        candidate = summarize({**self.trace, "scenario": "candidate", "events": [
            {"name": "BUILD", "ph": "X", "dur": 3_000},
            {"name": "GPURasterizer::Draw", "ph": "X", "dur": 4_000},
        ]})
        result = compare(baseline, candidate)
        self.assertEqual(result["groups"]["build"]["median_ms"]["delta_ms"], 1)
        self.assertEqual(result["groups"]["build"]["median_ms"]["change_pct"], 50)
        self.assertIsNone(result["groups"]["layout"]["median_ms"]["candidate"])


if __name__ == "__main__":
    unittest.main()
