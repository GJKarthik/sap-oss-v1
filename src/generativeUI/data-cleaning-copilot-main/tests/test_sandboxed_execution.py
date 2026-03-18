# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
import unittest

import pandas as pd

from definition.base.executable_code import (
    CheckLogic,
    SandboxSecurityError,
    clear_sandbox_audit_log,
    execute_sandboxed_function,
    get_sandbox_audit_log,
)


class TestSandboxedExecution(unittest.TestCase):
    def setUp(self):
        clear_sandbox_audit_log()

    def test_allowed_validation_code_executes_in_sandbox(self):
        check = CheckLogic(
            function_name="null_value_check",
            description="Flags null values in the demo table",
            scope=[("demo", "value")],
            imports=["import pandas as pd"],
            parameters="tables",
            body_lines=[
                "violations = {}",
                "table = tables.get('demo', pd.DataFrame())",
                "if 'value' in table.columns:",
                "    invalid = table['value'].isna()",
                "    if invalid.any():",
                "        violations['demo.value'] = pd.Series(table.index[invalid].tolist())",
            ],
            return_statement="violations",
        )

        validation_fn = check.to_validation_function()
        result = validation_fn({"demo": pd.DataFrame({"value": [1, None, 3]})})

        self.assertIn("demo.value", result)
        self.assertEqual(result["demo.value"].tolist(), [1])
        self.assertEqual(get_sandbox_audit_log()[-1]["outcome"], "success")

    def test_disallowed_import_is_blocked(self):
        result, error = execute_sandboxed_function(
            func_code="import os\n\ndef malicious(tables):\n    return {}\n",
            func_name="malicious",
            args=({},),
        )

        self.assertIsNone(result)
        self.assertIsInstance(error, SandboxSecurityError)
        audit_entry = get_sandbox_audit_log()[-1]
        self.assertEqual(audit_entry["outcome"], "blocked")
        self.assertTrue(audit_entry["code_hash"])

    def test_malicious_import_function_call_is_blocked(self):
        result, error = execute_sandboxed_function(
            func_code=(
                "def malicious(tables):\n"
                "    return __import__('os').system('echo hacked')\n"
            ),
            func_name="malicious",
            args=({},),
        )

        self.assertIsNone(result)
        self.assertIsInstance(error, SandboxSecurityError)
        self.assertEqual(get_sandbox_audit_log()[-1]["outcome"], "blocked")

    def test_timeout_is_enforced(self):
        result, error = execute_sandboxed_function(
            func_code="def infinite_loop(tables):\n    while True:\n        pass\n",
            func_name="infinite_loop",
            args=({},),
            timeout=1,
        )

        self.assertIsNone(result)
        self.assertIsInstance(error, TimeoutError)
        self.assertEqual(get_sandbox_audit_log()[-1]["outcome"], "timeout")

    def test_memory_limit_blocks_large_allocations(self):
        result, error = execute_sandboxed_function(
            func_code=(
                "def memory_hog(tables):\n"
                "    payload = 'x' * (1024 * 1024 * 1024)\n"
                "    return {'size': len(payload)}\n"
            ),
            func_name="memory_hog",
            args=({},),
            timeout=5,
            memory_limit_mb=256,
        )

        self.assertIsNone(result)
        self.assertIsInstance(error, MemoryError)
        audit_entry = get_sandbox_audit_log()[-1]
        self.assertEqual(audit_entry["memory_limit_mb"], 256)
        self.assertEqual(audit_entry["outcome"], "memory_limit_exceeded")


if __name__ == "__main__":
    unittest.main()