session="portfwd"

tmux new-session -d -s $session

# K8S Dashboard
window=0
tmux rename-window -t $session:$window 'k8s-dashboard'
tmux send-keys -t $session:$window 'export K8DASH_POD=$(kubectl get pods -l "app.kubernetes.io/component=kubernetes-dashboard" -A -o jsonpath="{.items[0].metadata.name}")' C-m
tmux send-keys -t $session:$window 'kubectl port-forward $K8DASH_POD -n default 8443:8443' C-m

# UI for Kafka
window=1
tmux new-window -t $session:$window -n 'kafka-ui'
tmux send-keys -t $session:$window 'export KUI_SVC=$(kubectl get svc -l "app.kubernetes.io/name=kafka-ui" -A -o jsonpath="{.items[0].metadata.name}")' C-m
tmux send-keys -t $session:$window 'kubectl port-forward svc/$KUI_SVC 8989:80' C-m

# Prometheus
window=2
tmux new-window -t $session:$window -n 'prometheus'
tmux send-keys -t $session:$window 'export PROM_SVC=$(kubectl get svc -l "app.kubernetes.io/component=prometheus" -A -o jsonpath="{.items[0].metadata.name}")' C-m
tmux send-keys -t $session:$window 'kubectl port-forward svc/$PROM_SVC 9090:9090' C-m

# Grafana
window=3
tmux new-window -t $session:$window -n 'grafana'
tmux send-keys -t $session:$window 'export GRAFA_SVC=$(kubectl get svc -l "app.kubernetes.io/name=grafana" -A -o jsonpath="{.items[0].metadata.name}")' C-m
tmux send-keys -t $session:$window 'kubectl port-forward svc/$GRAFA_SVC 3000' C-m

tmux attach-session -t $session
