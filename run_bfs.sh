#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: bash run_bfs.sh --sizes 8 16 32 [options]
  --sizes N ...          Combined graph file sizes in GiB (decimals allowed)
  --variants NAME ...   none pref advise pref_advise (default: all four)
  --degree N            Average degree (default: 16)
  --iterations N        BFS iterations (default: 1)
  --root N              BFS root (default: 0)
  --type N              BFS implementation: 0, 1, 2 (default: 2)
  --work-dir PATH        Temporary graph/build directory (default: current dir)
  --nvcc-flags FLAGS     Extra whitespace-separated CUDA flags
  -h, --help            Show this help
Environment: CXX, NVCC, NVCCFLAGS override compiler defaults.
All runs use UVM_DIRECT (-m 2) on GPU 0.
EOF
}

die() { echo "Error: $*" >&2; exit 1; }
sizes=()
variants=(none pref advise pref_advise)
degree=16 iterations=1 root=0 type=2
work_dir=$PWD
nvcc_flags=${NVCCFLAGS:-}
while (($#)); do
    case "$1" in
        --sizes|--variants)
            option=$1
            shift
            values=()
            while (($#)) && [[ $1 != --* ]]; do
                values+=("$1")
                shift
            done
            ((${#values[@]})) || die "$option needs a list"
            if [[ $option == --sizes ]]; then sizes=("${values[@]}")
            else variants=("${values[@]}"); fi
            ;;
        --degree|--iterations|--root|--type|--work-dir|--nvcc-flags)
            (($# >= 2)) || die "$1 needs a value"
            case "$1" in
                --degree) degree=$2 ;; --iterations) iterations=$2 ;;
                --root) root=$2 ;; --type) type=$2 ;;
                --work-dir) work_dir=$2 ;; --nvcc-flags) nvcc_flags=$2 ;;
            esac
            shift 2 ;;
        --nvcc-flags=*) nvcc_flags=${1#*=}; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done
((${#sizes[@]})) || die "Specify --sizes, e.g. --sizes 8 16"
[[ $degree =~ ^[1-9][0-9]*$ && $iterations =~ ^[1-9][0-9]*$ ]] || die "degree and iterations must be positive integers"
[[ $root =~ ^(0|[1-9][0-9]*)$ && $type =~ ^[012]$ ]] || die "Invalid root or type"
for variant in "${variants[@]}"; do
    case "$variant" in none|pref|advise|pref_advise) ;; *) die "Unknown variant: $variant" ;; esac
done

# Two 16-byte headers, (nodes + 1) offsets, and nodes * degree edges.
node_counts=()
for size in "${sizes[@]}"; do
    [[ $size =~ ^[0-9]+([.][0-9]+)?$ ]] || die "Invalid GiB size: $size"
    nodes=$(awk -v s="$size" -v d="$degree" -v r="$root" 'BEGIN {
        n = int((s * 1073741824 - 40) / (8 * (d + 1)))
        if (n <= r || s * 1073741824 > 9007199254740991) exit 1
        printf "%.0f", n
    }') || die "Size $size is too small for the root or too large"
    node_counts+=("$nodes")
done

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
work=$(mktemp -d "$work_dir/emogi-XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

"${CXX:-c++}" -O3 -std=c++11 "$source_dir/generator.cpp" -o "$work/generator"
flags=()
read -r -a flags <<< "$nvcc_flags"
for variant in "${variants[@]}"; do
    [[ ! -f $work/bfs_$variant ]] || continue
    defines=()
    case "$variant" in
        pref) defines=(-DPREF) ;;
        advise) defines=(-DADVISE) ;;
        pref_advise) defines=(-DPREF -DADVISE) ;;
    esac
    # The optional-array expansion also supports macOS Bash 3.2 with nounset.
    "${NVCC:-nvcc}" -O3 ${flags[@]+"${flags[@]}"} ${defines[@]+"${defines[@]}"} \
        "$source_dir/bfs.cu" -o "$work/bfs_$variant"
done

graph=$work/graph.bel
for index in "${!sizes[@]}"; do
    nodes=${node_counts[$index]}
    edges=$((nodes * degree))
    echo "=== ${sizes[$index]} GiB: $nodes nodes, $edges edges ==="
    "$work/generator" "$graph" "$nodes" "$edges"
    # generator.cpp does not report write failures; check for truncated files.
    [[ $(wc -c < "$graph.col") -eq $((16 + (nodes + 1) * 8)) &&
       $(wc -c < "$graph.dst") -eq $((16 + edges * 8)) ]] || die "Incomplete graph files"
    for variant in "${variants[@]}"; do
        echo "=== ${sizes[$index]} GiB / $variant / UVM_DIRECT ==="
        "$work/bfs_$variant" -f "$graph" -m 2 -t "$type" -r "$root" -i "$iterations"
    done
    rm -f -- "$graph.col" "$graph.dst"
    echo "Deleted graph for ${sizes[$index]} GiB"
done
