#!/bin/bash

# 检查realm是否已安装
if [ -f "/root/realm/realm" ]; then
    realm_installed=true
    realm_status_color="\033[0;32m" # 绿色
    realm_status="已安装"
else
    realm_installed=false
    realm_status_color="\033[0;31m" # 红色
    realm_status="未安装"
fi

# 检查realm服务状态
check_realm_service_status() {
    if ! $realm_installed; then
        echo -e "\033[0;31m未安装\033[0m"
        return
    fi
    if systemctl is-active --quiet realm; then
        echo -e "\033[0;32m运行中\033[0m" # 绿色
    else
        echo -e "\033[0;31m已停止\033[0m" # 红色
    fi
}

# 显示菜单的函数
show_menu() {
    clear
    echo "========================================="
    echo " Realm 一键转发脚本 (已优化UDP转发)"
    echo "========================================="
    echo " 1. 部署/重装 Realm"
    echo " 2. 添加 UDP/TCP 转发规则"
    echo " 3. 查看并删除转发规则"
    echo " 4. 启动 Realm 服务"
    echo " 5. 停止 Realm 服务"
    echo " 6. 卸载 Realm"
    echo " 0. 退出脚本"
    echo "-----------------------------------------"
    echo -e " Realm 状态：${realm_status_color}${realm_status}\033[0m"
    echo -n " 服务状态："
    check_realm_service_status
    echo "========================================="
}

# 部署环境的函数
deploy_realm() {
    echo "正在部署 Realm 环境..."
    mkdir -p /root/realm
    cd /root/realm || exit
    # 您可以根据需要更改版本和架构
    wget -O realm.tar.gz https://github.com/zhboner/realm/releases/download/v2.6.0/realm-x86_64-unknown-linux-gnu.tar.gz
    tar -xvf realm.tar.gz
    chmod +x realm

    # ★★★★★ 关键修改：创建包含 UDP 开启指令的配置文件 ★★★★★
    if [ ! -f "/root/realm/config.toml" ]; then
        echo "创建配置文件 config.toml 并默认开启 UDP..."
        echo '# 全局网络配置
[network]
use_udp = true  # 明确开启UDP转发功能

# 日志配置 (可选)
[log]
level = "warn"
output = "/var/log/realm.log"
' > /root/realm/config.toml
    fi
    
    # 创建服务文件
    echo "创建 systemd 服务..."
    echo "[Unit]
Description=realm forwarder
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5s
WorkingDirectory=/root/realm
ExecStart=/root/realm/realm -c /root/realm/config.toml

[Install]
WantedBy=multi-user.target" > /etc/systemd/system/realm.service

    systemctl daemon-reload
    realm_installed=true
    realm_status="已安装"
    realm_status_color="\033[0;32m"
    echo "部署完成！"
}

# 卸载realm
uninstall_realm() {
    echo "正在卸载 Realm..."
    systemctl stop realm
    systemctl disable realm
    rm -f /etc/systemd/system/realm.service
    systemctl daemon-reload
    rm -rf /root/realm
    rm -f /var/log/realm.log
    echo "Realm 已被彻底卸载。"
    realm_installed=false
    realm_status="未安装"
    realm_status_color="\033[0;31m"
}

# 删除转发规则的函数
delete_forward() {
    if [ ! -f "/root/realm/config.toml" ]; then
        echo "配置文件不存在。"
        return
    fi

    # ★★★★★ 关键修改：更准确地定位和显示规则 ★★★★★
    local rules=$(grep -n '\[\[endpoints\]\]' /root/realm/config.toml)
    if [ -z "$rules" ]; then
        echo "没有发现任何转发规则。"
        return
    fi

    echo "当前转发规则："
    local index=1
    local rule_lines=()
    while IFS= read -r line; do
        line_num=$(echo "$line" | cut -d: -f1)
        listen_info=$(sed -n "$(($line_num + 1))p" /root/realm/config.toml | awk -F'"' '{print $2}')
        remote_info=$(sed -n "$(($line_num + 2))p" /root/realm/config.toml | awk -F'"' '{print $2}')
        transport_info=$(sed -n "$(($line_num + 3))p" /root/realm/config.toml)

        echo -e "${index}. \033[0;33m${listen_info}\033[0m -> \033[0;32m${remote_info}\033[0m ($(echo $transport_info | awk -F'"' '{print $2}'))"
        rule_lines+=($line_num)
        index=$((index + 1))
    done <<< "$rules"

    read -p "请输入要删除的转发规则序号 (输入 0 返回): " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -eq 0 ] || [ "$choice" -gt "${#rule_lines[@]}" ]; then
        echo "无效输入或已取消。"
        return
    fi

    local line_to_delete=${rule_lines[$((choice-1))]}
    # 删除从 "[[endpoints]]" 开始的4行
    sed -i "${line_to_delete},$((line_to_delete+3))d" /root/realm/config.toml
    
    echo "规则已删除。建议重启服务以应用更改。"
    systemctl restart realm
    echo "Realm 服务已重启。"
}

# 添加转发规则
add_forward() {
    if ! $realm_installed; then
        echo "请先部署 Realm (选项 1)。"
        return
    fi
    
    while true; do
        read -p "请输入落地机IP(目标IP): " remote_ip
        if [ -z "$remote_ip" ]; then echo "IP不能为空"; continue; fi

        read -p "请输入中转机监听端口(本地端口): " listen_port
        if ! [[ "$listen_port" =~ ^[0-9]+$ ]]; then echo "端口必须是数字"; continue; fi

        read -p "请输入落地机目标端口 (留空则同监听端口): " remote_port
        if [ -z "$remote_port" ]; then remote_port=$listen_port; fi
        if ! [[ "$remote_port" =~ ^[0-9]+$ ]]; then echo "端口必须是数字"; continue; fi

        echo "请选择转发协议:"
        echo "1. UDP (推荐用于 Hysteria2, TUIC 等)"
        echo "2. TCP (推荐用于 VLESS, Trojan 等)"
        read -p "选择 [1/2]: " transport_choice
        case $transport_choice in
            1) transport="udp" ;;
            2) transport="tcp" ;;
            *) echo "无效选择, 默认为UDP"; transport="udp" ;;
        esac

        # ★★★★★ 关键修改：追加包含 transport 的完整规则 ★★★★★
        echo "
[[endpoints]]
listen = \"0.0.0.0:${listen_port}\"
remote = \"${remote_ip}:${remote_port}\"
transport = \"${transport}\" # 明确指定传输协议" >> /root/realm/config.toml
        
        echo "规则已添加: 0.0.0.0:${listen_port} -> ${remote_ip}:${remote_port} (${transport})"
        
        read -p "是否继续添加(Y/N)? [N]: " answer
        if [[ $answer != "Y" && $answer != "y" ]]; then
            break
        fi
    done
    echo "所有规则添加完毕。建议重启服务以应用更改。"
    systemctl restart realm
    echo "Realm 服务已重启。"
}

# 启动服务
start_service() {
    echo "正在启动 Realm 服务..."
    systemctl start realm
    systemctl enable realm
    echo "Realm 服务已启动并设置为开机自启。"
}

# 停止服务
stop_service() {
    echo "正在停止 Realm 服务..."
    systemctl stop realm
    echo "Realm 服务已停止。"
}

# 主循环
while true; do
    show_menu
    read -p "请输入选项 [1-6, 0]: " choice
    case $choice in
        1) deploy_realm ;;
        2) add_forward ;;
        3) delete_forward ;;
        4) start_service ;;
        5) stop_service ;;
        6) uninstall_realm ;;
        0) break ;;
        *) echo -e "\033[0;31m无效选项, 请重新输入。\033[0m" ;;
    esac
    read -n 1 -s -r -p "按任意键继续..."
done

