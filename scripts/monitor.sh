## This runs tmux with btop watch and glances for container monitoring 
## uncomment and try the full version if doesn't work

#tmux new-session -s monitor \; \
#  split-window -h -p 50 \; \
#  select-pane -t 1 \; \
#  split-window -v -p 50 \; \
#  select-pane -t 0 \; \
#  send-keys "btop" Enter \; \
#  select-pane -t 1 \; \
#  send-keys "watch -n 1 sensors" Enter \; \
#  select-pane -t 2 \; \
#  send-keys "glances" Enter

monitor
