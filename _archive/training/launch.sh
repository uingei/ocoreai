#!/bin/bash
# Launch 3B pretraining on 8xA100 with DeepSpeed ZeRO-3 + BF16
set -e
N_GPUS=${N_GPUS:-8}
export NCCL_IB_DISABLE=1
export NCCL_DEBUG=WARN
export OMP_NUM_THREADS=1
echo "=== Preflight ==="
for d in code tools commonsense; do
  [ -d "/tmp/ocoreai/data/$d" ] || { echo "MISSING: data/$d"; exit 1; }
done
echo "Data OK. Starting..."
deepspeed --num_gpus=$N_GPUS /tmp/ocoreai/training/pretrain.py --ds_config /tmp/ocoreai/training/configs/deepspeed_z3.json
