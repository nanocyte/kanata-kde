#!/bin/bash
set -euo pipefail

# --- Configuration Variables ---
KANATA_CONFIG_DIR="$HOME/.config/kanata"
KANATA_CONFIG_FILE="$KANATA_CONFIG_DIR/kanata.kbd"
UDEV_RULE_FILE="/etc/udev/rules.d/99-input.rules"
MODPROBE_CONF_FILE="/etc/modules-load.d/uinput.conf"
SYSTEMD_SERVICE_DIR="$HOME/.config/systemd/user"
SYSTEMD_SERVICE_FILE="$SYSTEMD_SERVICE_DIR/kanata.service"

# --- Functions ---

log_info() {
    echo -e "\n\033[1;34mINFO:\033[0m $1"
}

log_success() {
    echo -e "\n\033[1;32mSUCCESS:\033[0m $1"
}

log_warn() {
    echo -e "\n\033[1;33mWARNING:\033[0m $1"
}

log_error() {
    echo -e "\n\033[1;31mERROR:\033[0m $1" >&2
    exit 1
}

check_kanata_executable() {
    log_info "Checking for Kanata executable..."
    if ! command -v kanata &> /dev/null; then
        log_warn "Kanata executable not found in your PATH. Please ensure it's installed (e.g., via 'cargo install kanata') and that ~/.cargo/bin is in your PATH."
        log_warn "The script will proceed, but the service might fail to start if 'kanata' isn't found."
        read -p "Press Enter to continue or Ctrl+C to exit."
    else
        log_info "Kanata executable found at: $(which kanata)"
    fi
}

add_user_to_groups() {
    log_info "Adding user '$USER' to 'input' and 'uinput' groups..."
    # Create uinput group if it doesn't exist (idempotent)
    if ! getent group uinput > /dev/null; then
        sudo groupadd uinput || log_error "Failed to create 'uinput' group."
        log_info "Created 'uinput' group."
    else
        log_info "'uinput' group already exists."
    fi

    # Add user to input group (idempotent)
    if ! groups "$USER" | grep -qw input; then
        sudo usermod -aG input "$USER" || log_error "Failed to add '$USER' to 'input' group."
        log_info "Added '$USER' to 'input' group."
    else
        log_info "'$USER' is already in 'input' group."
    fi

    # Add user to uinput group (idempotent)
    if ! groups "$USER" | grep -qw uinput; then
        sudo usermod -aG uinput "$USER" || log_error "Failed to add '$USER' to 'uinput' group."
        log_info "Added '$USER' to 'uinput' group."
    else
        log_info "'$USER' is already in 'uinput' group."
    fi

    log_warn "You will need to log out and log back in for group changes to take effect!"
}

create_udev_rule() {
    log_info "Creating/updating udev rule for uinput permissions..."
    echo 'KERNEL=="uinput", MODE="0660", GROUP="uinput", OPTIONS+="static_node=uinput"' | sudo tee "$UDEV_RULE_FILE" > /dev/null || log_error "Failed to create udev rule."

    log_info "Reloading udev rules and triggering changes..."
    sudo udevadm control --reload-rules || log_error "Failed to reload udev rules."
    sudo udevadm trigger || log_error "Failed to trigger udev changes."

    log_info "Verifying /dev/uinput permissions:"
    ls -l /dev/uinput || log_warn "Could not list /dev/uinput. Verify udev rule application manually."
}

load_uinput_module() {
    log_info "Ensuring 'uinput' kernel module is loaded and persistent..."
    sudo modprobe uinput || log_error "Failed to load 'uinput' module."

    if ! grep -q "^uinput$" "$MODPROBE_CONF_FILE" 2>/dev/null; then
        echo "uinput" | sudo tee "$MODPROBE_CONF_FILE" > /dev/null || log_error "Failed to make 'uinput' module persistent."
        log_info "'uinput' module added to '$MODPROBE_CONF_FILE' for persistence across reboots."
    else
        log_info "'uinput' module already configured for persistence."
    fi
}

create_kanata_config_dir() {
    log_info "Creating Kanata configuration directory: '$KANATA_CONFIG_DIR'..."
    mkdir -p "$KANATA_CONFIG_DIR" || log_error "Failed to create '$KANATA_CONFIG_DIR'."

    if [ ! -f "$KANATA_CONFIG_FILE" ]; then
        log_warn "No Kanata configuration file found at '$KANATA_CONFIG_FILE'."
        log_warn "Please create or copy your 'kanata.kbd' file into this directory."
        echo "; This is a placeholder for your Kanata configuration." > "$KANATA_CONFIG_FILE"
        echo "; Replace this content with your actual Kanata configuration." >> "$KANATA_CONFIG_FILE"
        echo "; Example: (defsrc esc a b c) (deflayer default (q w e r))" >> "$KANATA_CONFIG_FILE"
        log_info "A placeholder '$KANATA_CONFIG_FILE' has been created."
    else
        log_info "Kanata configuration file already exists at '$KANATA_CONFIG_FILE'."
    fi
}

create_systemd_service() {
    log_info "Creating systemd user service file: '$SYSTEMD_SERVICE_FILE'..."
    mkdir -p "$SYSTEMD_SERVICE_DIR" || log_error "Failed to create '$SYSTEMD_SERVICE_DIR'."

    # Define the service content
    cat <<EOF > "$SYSTEMD_SERVICE_FILE"
[Unit]
Description=Kanata keyboard remapper
Documentation=https://github.com/jtroo/kanata
After=graphical-session.target network-online.target
Wants=graphical-session.target

[Service]
# Set a robust PATH for the service to find 'kanata' and other standard binaries.
# \$HOME will be expanded by systemd for user services.
Environment="PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin:/home/%u/.cargo/bin"
Type=simple
# Execute kanata via sh -c to ensure shell-like PATH resolution for 'which kanata'
ExecStart=/usr/bin/sh -c 'exec \$(which kanata) --cfg ${KANATA_CONFIG_FILE}'
Restart=no

[Install]
WantedBy=default.target
EOF

    if [ $? -eq 0 ]; then
        log_info "Systemd service file created successfully."
    else
        log_error "Failed to create systemd service file."
    fi
}

enable_and_start_service() {
    log_info "Reloading systemd daemon..."
    systemctl --user daemon-reload || log_error "Failed to reload systemd daemon."

    log_info "Enabling Kanata service to start at login..."
    systemctl --user enable kanata.service || log_error "Failed to enable Kanata service."

    log_info "Starting Kanata service now..."
    systemctl --user start kanata.service || log_error "Failed to start Kanata service."

    log_info "Checking Kanata service status:"
    systemctl --user status kanata.service
    log_success "Kanata service setup complete!"
}

# --- Main Script Execution ---

log_info "Starting Kanata setup script for '$USER' on Fedora KDE."

check_kanata_executable
add_user_to_groups
create_udev_rule
load_uinput_module
create_kanata_config_dir
create_systemd_service
enable_and_start_service

log_warn "IMPORTANT: For group changes to take full effect, you MUST log out and log back in."
log_warn "Ensure your Kanata configuration is correctly placed in '$KANATA_CONFIG_FILE'."
log_success "Kanata should now start automatically after you log in."
