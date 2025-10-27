#!/bin/bash

# Interactive SSH Login Script
# Replaces direct ttyd + ssh command with an interactive login prompt
# Usage: ssh-interactive-login.sh <target_host> <port>

# Check if required arguments are provided
if [ $# -ne 2 ]; then
    echo "Usage: $0 <target_host> <port>"
    echo "Example: $0 example.com 22"
    exit 1
fi

TARGET_HOST="$1"
PORT="$2"

# Validate port number
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    echo "Error: Invalid port number. Port must be between 1 and 65535."
    exit 1
fi

# Function to display banner
show_banner() {
    echo "=============================================="
    echo "     SSH Interactive Login Terminal"
    echo "=============================================="
    echo "Target: $TARGET_HOST:$PORT"
    echo "=============================================="
    echo ""
}

# Function to prompt for username
prompt_username() {
    while true; do
        read -p "Enter SSH username: " username
        
        # Validate username is not empty
        if [ -z "$username" ]; then
            echo "Error: Username cannot be empty. Please try again."
            echo ""
            continue
        fi
        
        # Basic validation for username (alphanumeric, dots, dashes, underscores)
        if [[ ! "$username" =~ ^[a-zA-Z0-9._-]+$ ]]; then
            echo "Error: Username contains invalid characters. Use only letters, numbers, dots, dashes, and underscores."
            echo ""
            continue
        fi
        
        break
    done
    
    echo "$username"
}

# Function to establish SSH connection
connect_ssh() {
    local username="$1"
    local host="$2"
    local port="$3"
    
    echo ""
    echo "Connecting to $username@$host:$port..."
    echo "=============================================="
    echo ""
    
    # SSH connection with various options for better compatibility
    ssh -o ConnectTimeout=10 \
        -o ServerAliveInterval=60 \
        -o ServerAliveCountMax=3 \
        -o StrictHostKeyChecking=ask \
        -p "$port" \
        "$username@$host"
    
    local ssh_exit_code=$?
    
    echo ""
    echo "=============================================="
    
    if [ $ssh_exit_code -eq 0 ]; then
        echo "SSH session ended normally."
    elif [ $ssh_exit_code -eq 130 ]; then
        echo "SSH session interrupted by user (Ctrl+C)."
    elif [ $ssh_exit_code -eq 255 ]; then
        echo "SSH connection failed. Please check:"
        echo "- Network connectivity"
        echo "- Target host and port"
        echo "- Username and authentication"
        echo "- SSH service availability"
    else
        echo "SSH session ended with exit code: $ssh_exit_code"
    fi
    
    return $ssh_exit_code
}

# Function to handle retry logic
handle_retry() {
    while true; do
        echo ""
        echo -n "Would you like to try again? (y/n): "
        read -r retry_choice
        
        case "$retry_choice" in
            [Yy]|[Yy][Ee][Ss])
                return 0
                ;;
            [Nn]|[Nn][Oo])
                return 1
                ;;
            *)
                echo "Please enter 'y' for yes or 'n' for no."
                ;;
        esac
    done
}

# Main execution flow
main() {
    # Clear screen for better presentation
    clear
    
    # Show banner
    show_banner
    
    # Main connection loop
    while true; do
        # Prompt for username
        username=$(prompt_username)
        
        # Attempt SSH connection
        connect_ssh "$username" "$TARGET_HOST" "$PORT"
        ssh_result=$?
        
        # If connection was successful or interrupted by user, exit
        if [ $ssh_result -eq 0 ] || [ $ssh_result -eq 130 ]; then
            break
        fi
        
        # Ask if user wants to retry
        if ! handle_retry; then
            echo "Goodbye!"
            break
        fi
        
        # Clear screen before retry
        clear
        show_banner
    done
}

# Trap signals to handle cleanup
trap 'echo -e "\n\nSession terminated."; exit 130' INT TERM

# Execute main function
main

exit 0
