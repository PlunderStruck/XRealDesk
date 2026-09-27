#!/bin/zsh
# Refits the learned head predictor from every recording and calibration session, then scores the
# new fit against the current one on the newest calibration session (which the current fit never
# saw). Writes Sources/XRCore/HeadPredictorWeights.swift; the old one is kept in $CALDIR.
set -e
cd "$(dirname "$0")/.."
LOGS=~/Library/Logs/XRealDesk
CALDIR=${CALDIR:-$HOME/Library/Application\ Support/XRealDesk/predictor-data}
mkdir -p "$CALDIR"
swift build --product xrcheck >/dev/null
XR=.build/debug/xrcheck
CAL=testdata/air2pro-calibration.json
for f in $LOGS/imu-*.csv(N); do
    out="$CALDIR/cal-$(basename $f .csv | sed 's/^imu-//').csv"
    [ -f "$out" ] || $XR dumpcal $CAL "$f" "$out" >/dev/null
done
for d in $LOGS/calibration-*(N/); do
    [ -f "$d/imu.csv" ] && [ -f "$d/labels.csv" ] || continue
    name=$(basename $d | sed 's/^calibration-//')
    out="$CALDIR/cal-calib-$name.csv"
    [ -f "$out" ] || $XR dumpcal $CAL "$d/imu.csv" "$out" >/dev/null
    cp "$d/labels.csv" "$CALDIR/labels-calib-$name.csv"
done
cp Sources/XRCore/HeadPredictorWeights.swift "$CALDIR/HeadPredictorWeights.previous.swift"
CALDIR="$CALDIR" python3 scripts/fit-head-predictor.py Sources/XRCore/HeadPredictorWeights.swift
CALDIR="$CALDIR" python3 scripts/eval-head-predictor.py "$CALDIR/HeadPredictorWeights.previous.swift"
