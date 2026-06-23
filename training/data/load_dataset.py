# Copyright 2026 uingei@163.com.
"""Streaming dataset loader with 55/25/20 ratio enforcement."""
import json, os, random
from pathlib import Path
class StreamingDataset:
    def __init__(self, data_dir, max_len=2048):
        self.data_dir = Path(data_dir)
        self.max_len = max_len
        self.indices = self._build()
        self.seen = set()
    def _build(self):
        idx = {"code": [], "tools": [], "commonsense": []}
        for cat in idx:
            cat_dir = self.data_dir / cat
            for f in cat_dir.glob("*.jsonl"):
                for line_no in range(sum(1 for _ in open(f))):
                    idx[cat].append((str(f), line_no))
        return idx
    def __len__(self):
        return sum(len(v) for v in self.indices.values())
    def _read(self, fp, ln):
        with open(fp) as f:
            for i, line in enumerate(f):
                if i == ln:
                    return json.loads(line)
        return {}
    def __getitem__(self, idx):
        cat = random.choices(["code","tools","commonsense"], weights=[55,25,20], k=1)[0]
        fp, ln = random.choice(self.indices[cat])
        rec = self._read(fp, ln)
        text_hash = hash(rec.get("text", ""))
        if text_hash in self.seen:
            return self.__getitem__(idx)
        self.seen.add(text_hash)
        ml = self.max_len
        return {"input_ids": list(range(ml)), "labels": list(range(ml)), "attention_mask": [1]*ml, "category": cat}
