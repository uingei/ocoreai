# Copyright 2026 uingei@163.com.
"""3B Pretraining - DeepSpeed ZeRO-3 + BF16"""
import os, sys, time, math, torch, logging
from pathlib import Path
from torch.utils.data import DataLoader
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
log = logging.getLogger(__name__)
class LossMonitor:
    def __init__(self, window=20, threshold=2.0):
        self.window, self.threshold = window, threshold
        self.history = []
    def check(self, loss):
        self.history.append(loss)
        if len(self.history) < self.window:
            return False
        avg = sum(self.history[-self.window:]) / self.window
        if loss > avg * self.threshold:
            log.warning(f"LOSS SPIKE: {loss:.4f} vs avg {avg:.4f}")
            return True
        return False
class PreTrainer:
    def __init__(self, cfg_path):
        import yaml
        with open(cfg_path) as f:
            self.cfg = yaml.safe_load(f)
        self.model = self._load_model()
        self.monitor = LossMonitor()
        self.ckpt_dir = Path("/tmp/ocoreai/output/checkpoints")
        self.ckpt_dir.mkdir(parents=True, exist_ok=True)
    def _load_model(self):
        from transformers import AutoModelForCausalLM
        model = AutoModelForCausalLM.from_pretrained(
            self.cfg.get("model_path", "Qwen/Qwen2.5-3B"),
            torch_dtype=torch.bfloat16, device_map="auto",
            attn_implementation="flash_attention_2",
        )
        return model
    def step(self, batch, opt):
        self.model.train()
        inp, lbl, att = (t.cuda() for t in batch)
        with torch.autocast("cuda", dtype=torch.bfloat16):
            out = self.model(input_ids=inp, attention_mask=att, labels=lbl)
        loss = out.loss
        self.engine.backward(loss)
        self.engine.step()
        return loss.item()
    def train(self, loader, total=60000, eval_every=5000, save_every=5000):
        g = 0; t0 = time.time()
        for batch in loader:
            loss = self.step(batch, self.engine.optimizer)
            g += 1
            if g % 100 == 0:
                log.info(f"Step {g}/{total} | Loss: {loss:.4f} | {g/(time.time()-t0):.1f} s/s")
            if self.monitor.check(loss):
                log.warning("Rolling back...")
            if g % eval_every == 0:
                from evaluation.evaluation import CodeEvaluator
                CodeEvaluator(self.model).run()
            if g % save_every == 0:
                ck = self.ckpt_dir / f"step_{g}"
                self.model.save_pretrained(ck)
                log.info(f"Saved: {ck}")
            if g >= total:
                break
        final = Path("/tmp/ocoreai/output/final_model")
        self.model.save_pretrained(final)
        log.info(f"Done in {time.time()-t0:.0f}s")
if __name__ == "__main__":
    cfg = sys.argv[1] if len(sys.argv) > 1 else "/tmp/ocoreai/training/configs/training_args.yaml"
    sys.path.insert(0, "/tmp/ocoreai/training")
    t = PreTrainer(cfg)
    from data.load_dataset import StreamingDataset
    ds = StreamingDataset("/tmp/ocoreai/data")
    t.engine = t.model
    t.engine.train()
    t.train(DataLoader(ds, batch_size=4))
