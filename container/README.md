# container/ —— 临时容器压测入口

一次压测 = 一个临时 benchmark 容器。容器从固定镜像启动，在容器里跑完 `aisbench_test.py` 后立即删除，本次产物全部落在宿主机目录里。

## 为什么用临时容器

| | 直接 `python3 aisbench_test.py`（原来的方式） | `bash container/run.sh` |
| --- | --- | --- |
| 环境 | 当前容器里必须装好 aisbench | 固定镜像自带，不用装 |
| 对推理服务容器 | 要进服务容器装包，可能要重启服务 | 完全不碰服务容器 |
| 多人同时用 | 共享当前目录，`temp_api.py` / `gsm8k/test.jsonl` / `aisbench.log` 会互相覆盖 | 各自容器，互不影响 |
| 产物 | 散在仓库根目录 + `OUTPUT_DIR` | 收在本次 run 目录，带 `meta.json` |

## 快速开始

```bash
# 参数和原来完全一样，只是前面换成 bash container/run.sh
bash container/run.sh --input_len 2048 --output_len 2048 --data_num 160 --concurrency 40 --request_rate 10

# 前缀测试
bash container/run.sh --input_len 2048 --output_len 2048 --data_num 160 --concurrency 40 --request_rate 10 \
  --dataset_type prefix_cache --repeat_rate 0.5 --prefix_test --dp 2

# 8 个并发点（每条命令各自起一个临时容器，串行）
for i in 1 8 16 24 32 40 48 56; do
  bash container/run.sh --input_len 8192 --output_len 1 --data_num $((i*4)) --concurrency $i \
    --request_rate 0 --dataset_type prefix_cache --repeat_rate 0.5 --seed $i --prefix_num 1 --prefix_test
done

# 只看会执行什么，不真跑
DRY_RUN=1 bash container/run.sh --input_len 2048 --output_len 2048 --data_num 160 --concurrency 40
```

`--help` 也直接透传：`bash container/run.sh --help`。

## 路径仍然由 config.py 决定

脚本从仓库根目录的 `config.py` 读出路径，按「宿主与容器同路径」挂进容器，所以 `config.py` 不用改：

| config.py 字段 | run.sh 怎么处理 |
| --- | --- |
| `DATASET_PATH` | 原样挂进容器（可写）。**数据集照旧复用**：同名 jsonl 存在就不再生成 |
| `OUTPUT_DIR` | 原样挂进容器（可写）。aisbench 原始结果照旧落在这里的 `<时间戳>/` 下 |
| `MODEL_PATH` | 原样挂进容器（只读），用来读 tokenizer |
| `HOST_IP` / `HOST_PORT` / `URL` / `API_KEY` / `MODEL_NAME` / `POD_INFO` | 原样读取；容器 `--net=host`，`127.0.0.1:端口` 就是宿主机上的服务 |
| `WORK_PATH` | **自动改成 `/benchmark`**（镜像内 aisbench 源码位置），你填什么都会被覆盖 |

约束：`DATASET_PATH` / `OUTPUT_DIR` / `MODEL_PATH` 必须是绝对路径（脚本会检查），`MODEL_PATH` 必须已存在。

## 一次压测的产物

```
$RUN_ROOT/<owner>/<时间戳>/
├── tools/                    本次在容器里的工作目录副本
│   ├── config.py             本次实际生效的配置（含自动追加的 WORK_PATH）
│   ├── aisbench_result.csv   本次那一行结果
│   └── aisbench.log          本次 aisbench 日志
├── console.log               打屏日志（出错先看这个）
└── meta.json                 镜像 tag、仓库 commit、参数、退出码

$RUN_ROOT/<owner>/results/
├── aisbench_result.csv       所有轮次累加，一行一轮，8 点扫描跑完就是 8 行
└── aisbench_all.log          所有轮次日志拼接
```

`RUN_ROOT` 默认 `$HOME/aisbench_runs`。

## 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `IMAGE` | `ghcr.io/aisbench/aisbench_benchmark:v3.1-20261013-master-ubuntu24.04-py312-aarch64` | 换镜像 tag |
| `RUN_ROOT` | `$HOME/aisbench_runs` | 产物根目录 |
| `OWNER` | `whoami` | 目录名、容器 label，用于区分人 |
| `DRY_RUN` | `0` | `1` = 只打印 docker 命令 |

## 并发压测（同一个 OUTPUT_DIR）

不同人各自一份 `config.py`（`OUTPUT_DIR` 不同）时，并发压测互不影响，可以直接并行跑。

但**同一个 `OUTPUT_DIR` 下并发跑两个压测会出问题**：ais_bench 的实验目录是 `<OUTPUT_DIR>/<秒级时间戳>/`，两个 run 同一秒启动就会撞进同一个目录，互相读到对方的配置和任务记录。实测症状：两个 run 都把请求打到同一个服务、请求数翻倍、`max_tokens` 用错。

需要这样跑时，加 `WORKDIR_ISOLATE=1`，本次会落到 `<OUTPUT_DIR>/run_<时间戳>_<owner>/` 下：

```bash
WORKDIR_ISOLATE=1 bash container/run.sh --input_len 2048 --output_len 2048 --data_num 160 --concurrency 40
```

## 注意事项

- `run.sh` 必须是 **LF** 换行。Windows 检出时如果 `core.autocrlf=true`，拷到 Linux 会报 `bash: bad interpreter`，用 `sed -i 's/\r$//' container/run.sh` 修一下。
- 镜像需先在宿主机准备好（`docker load -i xxx.tar.gz` 或 `docker pull`）。
- 脚本固定带 `--security-opt seccomp=unconfined`：宿主 Docker 18.09 的默认 seccomp 白名单不含 `clone3`，不加的话容器内 numpy 会报 `pthread_create failed: Operation not permitted`。
- 编排进程被 `kill -9` 会留下 exited 容器；下次运行会自动清理同 owner 的残留，也可以手动：
  `docker rm -f $(docker ps -aq --filter label=ais_bench_run=1)`
- 退出码就是 `aisbench_test.py` 的退出码，可直接用 `&&`/`||` 串起来。
- 一次压测一个容器，8 点扫描 = 8 个容器顺序起停，单次开销约 0.6 秒，可忽略。
