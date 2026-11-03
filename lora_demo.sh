#!/bin/bash
#
# lora_mesh demo in one tmux window, four panes:
#
#   +---------------------------+---------------------------+
#   | T1 lora_mesh (Erlang)     | T2 Python bot             |
#   |    fake boards + script   |    runs by itself         |
#   +---------------------------+---------------------------+
#   | T3 Python manual          | T4 mosquitto_sub          |
#   |    send pre-typed: Enter  |    everything on MQTT     |
#   +---------------------------+---------------------------+
#
# Put this script in the folder that holds lora_mesh/ and lora_mesh_client/
# (e.g. ~/ddmesh/ms99c), then:
#
#   ./lora_demo.sh              start (or re-attach)
#   ./lora_demo.sh stop         end the demo
#
# Settings below, or from the environment, e.g. DEMO=mixed ./lora_demo.sh

SESSION="${SESSION:-lora_demo}"
DEMO="${DEMO:-meshtastic}"         # meshtastic | mixed
NAME="${NAME:-Mary}"               # the bot's name in its replies
BROKER="${BROKER:-localhost}"

case "$DEMO" in
    meshtastic) START="lora_mesh_demo_meshtastic:start()."
                SEND_ARGS="send \"hello School\" --to '!0c0c0c0c'" ;;
    mixed)      START="lora_mesh_demo:start()."
                SEND_ARGS="send \"hello Alice\" --to @a1a2a3a4a5a6" ;;
    *)          echo "DEMO must be meshtastic or mixed" >&2; exit 1 ;;
esac

cd "$(dirname "$0")" || exit 1
BASE="$(pwd)"

if [ "$1" = "stop" ]; then
    tmux kill-session -t "$SESSION" 2>/dev/null && echo "demo stopped"
    exit 0
fi

if tmux has-session -t "$SESSION" 2>/dev/null; then
    exec tmux attach-session -t "$SESSION"
fi

for d in lora_mesh lora_mesh_client lora_mesh_client/.venv; do
    [ -d "$BASE/$d" ] || { echo "missing $BASE/$d" >&2; exit 1; }
done

# forget node records the broker kept from earlier demos
mosquitto_sub -h "$BROKER" -t 'mesh/node/#' --remove-retained -W 2 >/dev/null 2>&1

# 1. the panes, each with its permanent id (indexes change after splits)
T1=$(tmux new-session -d -s "$SESSION" -n demo -x 200 -y 50 -c "$BASE/lora_mesh" -P -F '#{pane_id}')
T2=$(tmux split-window -h -t "$T1" -c "$BASE/lora_mesh_client" -P -F '#{pane_id}')
T3=$(tmux split-window -v -t "$T1" -c "$BASE/lora_mesh_client" -P -F '#{pane_id}')
T4=$(tmux split-window -v -t "$T2" -c "$BASE" -P -F '#{pane_id}')

tmux set-option -t "$SESSION" pane-border-status top
tmux select-pane -t "$T1" -T "T1 lora_mesh (Erlang)"
tmux select-pane -t "$T2" -T "T2 Python bot"
tmux select-pane -t "$T3" -T "T3 Python manual: press Enter to send"
tmux select-pane -t "$T4" -T "T4 mosquitto_sub"

# 2. the programs: broker watcher first, then lora_mesh, then the bot
tmux send-keys -t "$T4" "mosquitto_sub -h $BROKER -t '#' -v" C-m
tmux send-keys -t "$T1" "rebar3 as test shell --start-clean --eval \"$START\"" C-m
tmux send-keys -t "$T2" "source .venv/bin/activate && python examples/demo_bot.py --host $BROKER --name $NAME" C-m

# 3. the manual send, typed but not run
tmux send-keys -t "$T3" "source .venv/bin/activate" C-m
tmux send-keys -t "$T3" "python -m lora_mesh_client --host $BROKER $SEND_ARGS"

tmux select-pane -t "$T3"
exec tmux attach-session -t "$SESSION"
