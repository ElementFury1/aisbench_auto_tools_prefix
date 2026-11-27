#!/usr/bin/env bash
# container_run.sh —— 一次压测 = 一个临时 benchmark 容器（跑完即删）
#
# 用法（在仓库根目录执行，或用绝对路径调用本脚本）：
#   bash container_run.sh --input_len 2048 --output_len 2048 --data_num 160 --concurrency 40 --request_rate 10
#   bash container_run.sh --dataset_type prefix_cache --repeat_rate 0.5 --prefix_test --dp 2 ...
#
# 参数原样透传给 aisbench_test.py。
# 路径（DATASET_PATH / OUTPUT_DIR / MODEL_PATH）全部由仓库根目录的 config.py 决定，
# 本脚本把它们按「宿主与容器同路径」挂进容器，所以 config.py 一个字都不用改。
#
# 可覆盖的环境变量：
#   IMAGE      镜像 tag（默认 v3.1-20261013 aarch64）
#   RUN_ROOT   本次运行目录的父目录（默认 $HOME/aisbench_runs）
#   OWNER      归属标记，用于容器 label 与目录（默认 whoami）
#   DRY_RUN=1  只打印将执行的 docker 命令，不真正跑
#   WORKDIR_ISOLATE=1
#              给本次压测一个独立的 aisbench 实验根目录（OUTPUT_DIR/<本次run>）。
#              同一个 OUTPUT_DIR 下并发跑两个压测时必须开，否则两个 run 可能撞进
#              同一个 <OUTPUT_DIR>/<秒级时间戳>/ 而互相读到对方的配置与任务记录。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"   # 脚本就放在仓库根目录

IMAGE="${IMAGE:-ghcr.io/aisbench/aisbench_benchmark:v3.1-20261013-master-ubuntu24.04-py312-aarch64}"
RUN_ROOT="${RUN_ROOT:-$HOME/aisbench_runs}"
OWNER="${OWNER:-$(whoami)}"

die() { echo "[container_run.sh] ERROR: $*" >&2; exit 1; }
info() { echo "[container_run.sh] $*"; }

[ -f "$REPO_ROOT/config.py" ] || die "找不到 $REPO_ROOT/config.py"
[ -f "$REPO_ROOT/aisbench_test.py" ] || die "找不到 $REPO_ROOT/aisbench_test.py"

# ---------------------------------------------------------------------------
# 1. 从 config.py 读取路径（config.py 是唯一配置源）
# ---------------------------------------------------------------------------
read_cfg() {  # read_cfg <变量名> -> 打印值
    local name="$1" value=""
    if command -v python3 >/dev/null 2>&1; then
        value="$(cd "$REPO_ROOT" && python3 - "$name" <<'PY' 2>/dev/null || true
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cfg", "config.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print(getattr(mod, sys.argv[1], "") or "")
PY
)"
    fi
    if [ -z "$value" ]; then
        value="$(grep -E "^${name}[[:space:]]*=" "$REPO_ROOT/config.py" | head -1 \
                 | sed -E 's/^[^=]*=[[:space:]]*//' | sed -E "s/^[\"']//; s/[\"']$//")"
    fi
    printf '%s' "$value"
}

DATASET_PATH="$(read_cfg DATASET_PATH)"
OUTPUT_DIR="$(read_cfg OUTPUT_DIR)"
MODEL_PATH="$(read_cfg MODEL_PATH)"

for var in DATASET_PATH OUTPUT_DIR MODEL_PATH; do
    [ -n "${!var}" ] || die "config.py 里缺少 $var"
    case "${!var}" in
        /*) ;;
        *) die "$var 必须是绝对路径，当前为 '${!var}'" ;;
    esac
done

[ -d "$MODEL_PATH" ] || die "MODEL_PATH 不存在: $MODEL_PATH（tokenizer 需要它）"
mkdir -p "$DATASET_PATH" "$OUTPUT_DIR"

# ---------------------------------------------------------------------------
# 2. 本次运行目录
# ---------------------------------------------------------------------------
TS="$(date +%Y%m%d_%H%M%S)"
SAFE_OWNER="$(printf '%s' "$OWNER" | tr -c 'A-Za-z0-9_.-' '_')"
RUN_DIR="$RUN_ROOT/$SAFE_OWNER/$TS"
NAME="aisbench_run_${SAFE_OWNER}_${TS}"

mkdir -p "$RUN_DIR/tools"
# 只拷运行所需的代码与语料（不拷历史 dataset / outputs / 日志 / __pycache__）
for f in config.py aisbench_test.py default_api.py temp_api.py generate_dataset.py \
         data_picker.py save_file.py cal_prefix_hit_rate.py GSM8K.jsonl; do
    [ -f "$REPO_ROOT/$f" ] && cp -a "$REPO_ROOT/$f" "$RUN_DIR/tools/"
done

# 容器里 aisbench 源码在 /benchmark（镜像内可编辑安装），覆盖本次副本的 WORK_PATH
cat >> "$RUN_DIR/tools/config.py" <<'PY'

# ---- container_run.sh 追加：容器内 aisbench 源码固定为 /benchmark ----
import os as _os
WORK_PATH = _os.environ.get("AISBENCH_WORK_PATH", "/benchmark")
PY

# 可选：给本次压测独立的实验根目录，避免同 OUTPUT_DIR 的并发 run 撞同名时间戳目录
if [ "${WORKDIR_ISOLATE:-0}" = "1" ]; then
    OUTPUT_DIR="$OUTPUT_DIR/run_${TS}_${SAFE_OWNER}"
    cat >> "$RUN_DIR/tools/config.py" <<PY

# ---- container_run.sh 追加：本次压测独立的实验根目录 ----
OUTPUT_DIR = "$OUTPUT_DIR"
PY
fi
mkdir -p "$OUTPUT_DIR"

info "run 目录 : $RUN_DIR"
info "容器名   : $NAME"
info "数据集   : $DATASET_PATH"
info "输出目录 : $OUTPUT_DIR"
info "模型路径 : $MODEL_PATH"

# ---------------------------------------------------------------------------
# 3. 清理本 owner 上次异常退出（如 kill -9）留下的容器
# ---------------------------------------------------------------------------
for stale in $(docker ps -a --filter "label=ais_bench_run=1" \
                      --filter "label=ais_bench_owner=$SAFE_OWNER" \
                      --filter "status=exited" --filter "status=dead" \
                      --format '{{.Names}}' 2>/dev/null || true); do
    info "清理残留容器 $stale"
    docker rm -f "$stale" >/dev/null 2>&1 || true
done

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# 4. 起临时容器执行压测
# ---------------------------------------------------------------------------
DOCKER_ARGS=(
    --name "$NAME"
    --label ais_bench_run=1
    --label "ais_bench_owner=$SAFE_OWNER"
    --net=host
    --ipc=host
    --security-opt seccomp=unconfined
    -e TZ=Asia/Shanghai
    -v "$RUN_DIR":/run
    -v "$DATASET_PATH":"$DATASET_PATH"
    -v "$OUTPUT_DIR":"$OUTPUT_DIR"
    -v "$MODEL_PATH":"$MODEL_PATH":ro
    -w /run/tools
)

if [ "${DRY_RUN:-0}" = "1" ]; then
    info "DRY_RUN：以下命令未执行"
    echo "docker run -d ${DOCKER_ARGS[*]} $IMAGE python3 aisbench_test.py $*"
    exit 0
fi

docker run -d "${DOCKER_ARGS[@]}" "$IMAGE" python3 aisbench_test.py "$@" >/dev/null

# 实时跟日志；容器退出后 docker logs -f 自动结束
docker logs -f "$NAME" 2>&1 || true
rc="$(docker wait "$NAME" 2>/dev/null || echo 1)"

# 容器还在（trap 尚未执行）时把打屏日志归档
docker logs "$NAME" > "$RUN_DIR/console.log" 2>&1 || true

# ---------------------------------------------------------------------------
# 5. 汇总结果：本次一行追加到 results/aisbench_result.csv，便于多轮对比
# ---------------------------------------------------------------------------
RESULT_DIR="$RUN_ROOT/$SAFE_OWNER/results"
mkdir -p "$RESULT_DIR"
for pair in "aisbench_result.csv:aisbench_result.csv" "aisbench_all.log:aisbench_all.log"; do
    src="$RUN_DIR/tools/${pair%%:*}"
    agg="$RESULT_DIR/${pair##*:}"
    [ -f "$src" ] || continue
    if [ ! -f "$agg" ]; then
        cp "$src" "$agg"
    else
        case "$src" in
            *result.csv) tail -n +2 "$src" >> "$agg" ;;
            *)           printf '\n' >> "$agg"; cat "$src" >> "$agg" ;;
        esac
    fi
done

cat > "$RUN_DIR/meta.json" <<JSON
{
  "owner": "$SAFE_OWNER",
  "run_dir": "$RUN_DIR",
  "container": "$NAME",
  "image": "$IMAGE",
  "tools_commit": "$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)",
  "config": {
    "DATASET_PATH": "$DATASET_PATH",
    "OUTPUT_DIR": "$OUTPUT_DIR",
    "MODEL_PATH": "$MODEL_PATH",
    "WORK_PATH": "/benchmark"
  },
  "args": "$*",
  "exit_code": $rc,
  "finished_at": "$(date '+%Y-%m-%d %H:%M:%S')"
}
JSON

info "压测结束 exit=$rc"
info "本次结果 : $RUN_DIR/tools/aisbench_result.csv"
info "打屏日志 : $RUN_DIR/console.log"
info "汇总结果 : $RESULT_DIR/aisbench_result.csv"
exit "$rc"
