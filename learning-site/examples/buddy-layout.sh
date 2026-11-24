#!/usr/bin/env bash
set -euo pipefail

# 每行代表一个以 16 页边界开始的区域，点号表示空闲。
printf '%s\n' '........########' '.#.#.#.#.#.#.#.#' '####........####' |
    awk '
    {
        free_pages = gsub(/[.]/, ".", $0)
        for (order = 4; order >= 0; order--) {
            width = 2 ^ order
            for (base = 0; base + width <= length($0); base += width)
                if (substr($0, base + 1, width) !~ /#/)
                    break
            if (base + width <= length($0))
                break
        }
        printf "%s 空闲=%d 最大 order=%d 起点=%d\n", $0, free_pages, order, base
    }'
