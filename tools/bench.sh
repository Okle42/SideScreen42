#!/bin/zsh
# 資源與延遲量測：閒置（無用戶端）20 秒 → 串流（60fps 測試圖＋本機用戶端）20 秒
# 用法：tools/bench.sh [port]
cd "$(dirname $0)/.."
PORT=${1:-8767}
BIN=.build/release/sidescreen
[ -x .build/testpattern ] || swiftc -O tools/testpattern.swift -o .build/testpattern
$BIN --port $PORT > /tmp/sidescreen_bench.log 2>&1 &
PID=$!
sleep 4
cpu() { ps -o cputime= -p $PID | awk -F'[:.]' '{ if (NF==3) print $1*60+$2+$3/100; else print $1*3600+$2*60+$3+$4/100 }'; }
rss() { ps -o rss= -p $PID | awk '{printf "%.1f", $1/1024}'; }
c0=$(cpu); sleep 20; c1=$(cpu)
echo "閒置（無用戶端）：CPU $(echo "($c1-$c0)/20*100" | bc -l | xargs printf '%.1f')%  RSS $(rss) MB"
.build/testpattern 26 > /dev/null &
TP=$!
sleep 2
c0=$(cpu)
R=$(node tools/bench_client.mjs ws://127.0.0.1:$PORT/stream 20)
c1=$(cpu)
echo "串流（60fps 測試圖）：CPU $(echo "($c1-$c0)/20*100" | bc -l | xargs printf '%.1f')%  RSS $(rss) MB  $R"
wait $TP 2>/dev/null
kill -INT $PID; wait $PID 2>/dev/null
