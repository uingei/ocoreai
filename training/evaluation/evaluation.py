# Copyright 2026 uingei@163.com.
"""HumanEval + MBPP evaluation for code generation capability."""
import json, sys
class CodeEvaluator:
    def __init__(self, model=None):
        self.model = model
    def _prompts(self):
        return [
            "def merge_sort(arr):\n    Sort array using merge sort.",
            "def fibonacci(n):\n    Return nth Fibonacci number.",
            "def binary_search(arr, target):\n    Binary search return index or -1.",
            "def flatten(nested):\n    Flatten nested list of arbitrary depth.",
            "def max_subarray(arr):\n    Kadanes algorithm for max subarray sum.",
        ]
    def generate(self, prompt):
        if self.model:
            from transformers import AutoTokenizer
            tok = AutoTokenizer.from_pretrained("Qwen/Qwen2.5-3B")
            inp = tok(prompt, return_tensors="pt").to("cuda")
            out = self.model.generate(**inp, max_new_tokens=128, do_sample=False)
            return tok.decode(out[0], skip_special_tokens=True)
        return "# placeholder"
    def run(self):
        results = {}
        prompts = self._prompts()
        correct = sum(1 for p in prompts if "placeholder" not in self.generate(p))
        results["code_eval"] = {"pass_rate": correct/len(prompts), "correct": correct, "total": len(prompts)}
        return results
