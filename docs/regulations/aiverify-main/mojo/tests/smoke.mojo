"""
AI Verify Mojo smoke checks.
"""


fn normalize_plugin_gid(text: String) -> String:
    var lowered = text.lower()
    var output = String()
    var previous_whitespace = False

    for i in range(len(lowered)):
        var ch = lowered[i]
        var is_whitespace = ch == " " or ch == "\n" or ch == "\t" or ch == "\r"
        if is_whitespace:
            if not previous_whitespace:
                output += " "
            previous_whitespace = True
        else:
            output += ch
            previous_whitespace = False

    var cleaned = output.strip()
    return String(cleaned)


fn parity_gap(reference: Float64, candidate: Float64) -> Float64:
    var delta = candidate - reference
    if delta < 0.0:
        delta = -delta
    return delta


fn float_close(actual: Float64, expected: Float64, tolerance: Float64) -> Bool:
    var delta = actual - expected
    if delta < 0.0:
        delta = -delta
    return delta <= tolerance


fn expect_true(name: String, condition: Bool) -> Bool:
    if condition:
        print("PASS: " + name)
        return True
    else:
        print("FAIL: " + name)
        return False


fn main():
    var passed = 0
    var failed = 0

    var gid = normalize_plugin_gid("AIVERIFY.Stock   Reports ")
    if expect_true("normalize_plugin_gid", gid == "aiverify.stock reports"):
        passed += 1
    else:
        failed += 1

    var gap_1 = parity_gap(0.88, 0.81)
    if expect_true("parity_gap_positive", float_close(gap_1, 0.07, 0.0000001)):
        passed += 1
    else:
        failed += 1

    var gap_2 = parity_gap(0.81, 0.88)
    if expect_true("parity_gap_symmetric", float_close(gap_2, 0.07, 0.0000001)):
        passed += 1
    else:
        failed += 1

    print("Results: " + String(passed) + " passed, " + String(failed) + " failed")
