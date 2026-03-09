#!/usr/bin/env python3
import os
import subprocess
from pathlib import Path

base_path = Path("/Users/user/Documents/training-main")
kuzu_src = base_path / "hippocpp/upstream/kuzu/src"

print("=== Command 1: find . -path \"*/upstream/kuzu*\" -type d ===")
result = subprocess.run(
    ["find", ".", "-path", "*/upstream/kuzu*", "-type", "d"],
    cwd=base_path,
    capture_output=True,
    text=True
)
print("\n".join(result.stdout.strip().split("\n")[:10]))

print("\n=== Command 2: find . -name \"kuzu\" -type d ===")
result = subprocess.run(
    ["find", ".", "-name", "kuzu", "-type", "d"],
    cwd=base_path,
    capture_output=True,
    text=True
)
print("\n".join(result.stdout.strip().split("\n")[:10]))

print("\n=== Command 3: ls -la hippocpp/upstream/ ===")
result = subprocess.run(
    ["ls", "-la", "hippocpp/upstream/"],
    cwd=base_path,
    capture_output=True,
    text=True
)
print(result.stdout)

print("\n=== Command 4: find hippocpp/upstream/kuzu/src -type d | sort | head -40 ===")
result = subprocess.run(
    ["find", "hippocpp/upstream/kuzu/src", "-type", "d"],
    cwd=base_path,
    capture_output=True,
    text=True
)
dirs = sorted(result.stdout.strip().split("\n"))
print("\n".join(dirs[:40]))

print("\n=== Command 5: find hippocpp/upstream/kuzu/src -name \"*.cpp\" | wc -l ===")
result = subprocess.run(
    ["find", "hippocpp/upstream/kuzu/src", "-name", "*.cpp"],
    cwd=base_path,
    capture_output=True,
    text=True
)
cpp_count = len([l for l in result.stdout.strip().split("\n") if l])
print(cpp_count)

print("\n=== Command 6: find hippocpp/upstream/kuzu/src -name \"*.h\" -o -name \"*.hpp\" | wc -l ===")
result = subprocess.run(
    ["find", "hippocpp/upstream/kuzu/src", "-name", "*.h", "-o", "-name", "*.hpp"],
    cwd=base_path,
    capture_output=True,
    text=True
)
header_count = len([l for l in result.stdout.strip().split("\n") if l])
print(header_count)

print("\n=== Command 7: ls hippocpp/upstream/kuzu/src/ ===")
result = subprocess.run(
    ["ls", "hippocpp/upstream/kuzu/src/"],
    cwd=base_path,
    capture_output=True,
    text=True
)
print(result.stdout)

