session="portfwd"

tmux new-session -d -s $session

# K8S Dashboard
window=0
tmux rename-window -t $session:$window 'k8s-dashboard'
tmux send-keys -t $session:$window 'export K8DASH_POD=$(kubectl get pods -l "app.kubernetes.io/instance=k3d,app.kubernetes.io/component=kubernetes-dashboard" -n default -o jsonpath="{.items[0].metadata.name}")' C-m
tmux send-keys -t $session:$window 'kubectl port-forward $K8DASH_POD -n default 8443:8443' C-m

# UI for Kafka
window=1
tmux new-window -t $session:$window -n 'kafka-ui'
tmux send-keys -t $session:$window 'kubectl port-forward svc/k3d-kafka-ui 8989:80' C-m

# Prometheus
window=2
tmux new-window -t $session:$window -n 'prometheus'
tmux send-keys -t $session:$window 'kubectl port-forward svc/k3d-prometheus-prometheus 9090:9090' C-m

# Grafana
window=3
tmux new-window -t $session:$window -n 'grafana'
tmux send-keys -t $session:$window 'kubectl port-forward svc/k3d-grafana 3000' C-m

# Open pages
# sleep 2
# open https://127.0.0.1:8443
# sleep 2
# open http://localhost:8989
# sleep 2
# open http://localhost:9090
# sleep 2
# open http://localhost:3000

tmux attach-session -t $session
