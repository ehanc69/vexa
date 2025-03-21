#!/usr/bin/env python3
"""
Script to add Apache 2.0 license headers to source files.
"""
import os
import re

HEADER = """// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Vexa.ai Inc.
"""

def add_license_header(filepath, header):
    with open(filepath, 'r') as f:
        content = f.read()
    
    # Check if header already exists
    if content.startswith(header):
        return False
    
    with open(filepath, 'w') as f:
        f.write(header + content)
    return True

# File extensions to process
EXTENSIONS = ['.py', '.js', '.jsx', '.ts', '.tsx', '.java', '.go', '.c', '.cpp', '.h']

def process_directory(directory):
    count = 0
    # Walk through directories
    for root, dirs, files in os.walk(directory):
        if 'node_modules' in root or '.git' in root:
            continue
        for file in files:
            ext = os.path.splitext(file)[1]
            if ext in EXTENSIONS:
                filepath = os.path.join(root, file)
                if add_license_header(filepath, HEADER):
                    print(f"Added header to {filepath}")
                    count += 1
    return count

if __name__ == "__main__":
    import sys
    
    if len(sys.argv) > 1:
        directory = sys.argv[1]
    else:
        directory = "."
    
    count = process_directory(directory)
    print(f"Added license headers to {count} files.") 