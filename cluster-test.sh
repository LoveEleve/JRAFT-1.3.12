#!/bin/bash

# JRaft Counter 3节点集群管理脚本
# 节点配置
GROUP_ID="counter"
INIT_CONF="127.0.0.1:8081,127.0.0.1:8082,127.0.0.1:8083"
BASE_DIR="/tmp/jraft-cluster-test"
EXAMPLE_DIR="/data/workspace/sofa-jraft/jraft-example"

# classpath
CP="${EXAMPLE_DIR}/target/classes:${EXAMPLE_DIR}/target/dependency/*"

# JVM 参数
JVM_OPTS="-Xmx256m -Xms256m"

start_node() {
    local node_id=$1
    local port=$((8080 + node_id))
    local data_path="${BASE_DIR}/server${node_id}"
    local server_id="127.0.0.1:${port}"
    local log_file="${BASE_DIR}/node${node_id}.log"

    echo ">>> 启动节点 ${node_id} (${server_id})..."
    mkdir -p "${data_path}"

    nohup java ${JVM_OPTS} -cp "${CP}" \
        com.alipay.sofa.jraft.example.counter.CounterServer \
        "${data_path}" "${GROUP_ID}" "${server_id}" "${INIT_CONF}" \
        > "${log_file}" 2>&1 &
    
    echo $! > "${BASE_DIR}/node${node_id}.pid"
    echo "    PID: $(cat ${BASE_DIR}/node${node_id}.pid), 日志: ${log_file}"
}

stop_node() {
    local node_id=$1
    local pid_file="${BASE_DIR}/node${node_id}.pid"
    
    if [ -f "${pid_file}" ]; then
        local pid=$(cat "${pid_file}")
        if kill -0 "${pid}" 2>/dev/null; then
            echo ">>> 停止节点 ${node_id} (PID: ${pid})..."
            kill "${pid}"
            sleep 1
            if kill -0 "${pid}" 2>/dev/null; then
                kill -9 "${pid}"
            fi
            echo "    已停止"
        else
            echo ">>> 节点 ${node_id} 已经不在运行"
        fi
        rm -f "${pid_file}"
    else
        echo ">>> 节点 ${node_id} PID文件不存在"
    fi
}

status_all() {
    echo "=== 集群状态 ==="
    for i in 1 2 3; do
        local pid_file="${BASE_DIR}/node${i}.pid"
        local port=$((8080 + i))
        if [ -f "${pid_file}" ]; then
            local pid=$(cat "${pid_file}")
            if kill -0 "${pid}" 2>/dev/null; then
                echo "  节点${i} (127.0.0.1:${port}): 运行中 (PID: ${pid})"
            else
                echo "  节点${i} (127.0.0.1:${port}): 已停止 (PID文件残留)"
            fi
        else
            echo "  节点${i} (127.0.0.1:${port}): 未启动"
        fi
    done
}

run_client() {
    echo ">>> 运行 CounterClient (发送 1000 次 incrementAndGet)..."
    java ${JVM_OPTS} -cp "${CP}" \
        com.alipay.sofa.jraft.example.counter.CounterClient \
        "${GROUP_ID}" "${INIT_CONF}"
}

case "$1" in
    start)
        echo "=== 启动 3 节点 JRaft Counter 集群 ==="
        rm -rf "${BASE_DIR}"
        mkdir -p "${BASE_DIR}"
        for i in 1 2 3; do
            start_node $i
            sleep 1
        done
        echo ""
        echo "=== 等待选举完成 (5秒)... ==="
        sleep 5
        status_all
        echo ""
        echo "=== 检查最近日志 ==="
        for i in 1 2 3; do
            echo "--- 节点${i} 最后5行日志 ---"
            tail -5 "${BASE_DIR}/node${i}.log" 2>/dev/null
        done
        ;;
    stop)
        echo "=== 停止集群 ==="
        for i in 1 2 3; do
            stop_node $i
        done
        ;;
    status)
        status_all
        ;;
    kill-leader)
        echo "=== Kill Leader 故障注入 ==="
        echo "先检查各节点日志找到 Leader..."
        for i in 1 2 3; do
            if grep -q "onLeaderStart" "${BASE_DIR}/node${i}.log" 2>/dev/null; then
                local_leader=$(grep "onLeaderStart" "${BASE_DIR}/node${i}.log" | tail -1)
                echo "  节点${i} 曾成为 Leader: ${local_leader}"
            fi
        done
        if [ -z "$2" ]; then
            echo "用法: $0 kill-leader <node_id>"
            echo "请指定要Kill的Leader节点ID (1/2/3)"
        else
            stop_node $2
            echo ""
            echo "=== 等待重新选举 (5秒)... ==="
            sleep 5
            echo "=== 选举后日志 ==="
            for i in 1 2 3; do
                if [ -f "${BASE_DIR}/node${i}.pid" ]; then
                    echo "--- 节点${i} 最后10行日志 ---"
                    tail -10 "${BASE_DIR}/node${i}.log" 2>/dev/null
                fi
            done
        fi
        ;;
    restart-node)
        if [ -z "$2" ]; then
            echo "用法: $0 restart-node <node_id>"
        else
            echo "=== 重启节点 $2 ==="
            stop_node $2
            sleep 2
            start_node $2
            sleep 3
            echo "--- 节点$2 最后10行日志 ---"
            tail -10 "${BASE_DIR}/node$2.log" 2>/dev/null
        fi
        ;;
    client)
        run_client
        ;;
    logs)
        if [ -z "$2" ]; then
            echo "用法: $0 logs <node_id> [行数]"
        else
            local lines=${3:-50}
            tail -${lines} "${BASE_DIR}/node$2.log" 2>/dev/null
        fi
        ;;
    clean)
        echo "=== 清理所有数据 ==="
        for i in 1 2 3; do
            stop_node $i
        done
        rm -rf "${BASE_DIR}"
        echo "已清理 ${BASE_DIR}"
        ;;
    *)
        echo "JRaft Counter 集群管理工具"
        echo ""
        echo "用法: $0 {command}"
        echo ""
        echo "命令:"
        echo "  start         - 启动3节点集群"
        echo "  stop          - 停止集群"
        echo "  status        - 查看集群状态"
        echo "  kill-leader N - Kill节点N (模拟Leader故障)"
        echo "  restart-node N- 重启节点N"
        echo "  client        - 运行客户端发送请求"
        echo "  logs N [行数] - 查看节点N的日志"
        echo "  clean         - 停止并清理所有数据"
        ;;
esac
