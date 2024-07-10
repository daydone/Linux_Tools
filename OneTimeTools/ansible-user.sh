#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

main() {
    local ansible_user="ansible-user"

    # Create user
    create_user "$ansible_user"

    # Grant sudo privileges
    grant_sudo "$ansible_user"

    # Set password using user input
    set_password "$ansible_user"

    # Self-deletion of script
    self_delete
}

create_user() {
    local user=$1
    if ! id "$user" &>/dev/null; then
        sudo useradd "$user"
    fi
}

grant_sudo() {
    local user=$1
    echo "$user ALL=(ALL) NOPASSWD:ALL" | sudo tee "/etc/sudoers.d/$user"
}

set_password() {
    local user=$1
    local password

    read -s -p "Enter password for $user: " password
    echo
    read -s -p "Confirm password for $user: " password_confirm
    echo

    if [[ "$password" != "$password_confirm" ]]; then
        printf "Passwords do not match. Please try again.\n" >&2
        return 1
    fi

    echo "$user:$password" | sudo chpasswd
}

self_delete() {
    rm -- "$0"
}

main "$@"
