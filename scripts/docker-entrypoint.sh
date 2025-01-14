#!/bin/bash
set -e

# Use root home folder
SSH_DIR="/root/.ssh"
SSH_KEY="${SSH_DIR}/docker"
KNOWN_HOSTS="${SSH_DIR}/known_hosts"
ENV_FILE_PATH="/root/.env"

login() {
  echo "${PASSWORD}" | docker login "${REGISTRY}" -u "${USERNAME}" --password-stdin
}

configure_ssh() {
  mkdir -p "${SSH_DIR}"
  printf '%s' "UserKnownHostsFile=${KNOWN_HOSTS}" >"${SSH_DIR}/config"
  chmod 600 "${SSH_DIR}/config"
}

configure_ssh_keys() {
  # Verify expect is available for password-protected keys
  if [[ -n "${REMOTE_PRIVATE_KEY_PASSWORD}" ]]; then
    if ! command -v expect &>/dev/null; then
      echo "'expect' package is required but not found"
      exit 1
    fi
  fi

  # Configure private key
  printf '%s' "$REMOTE_PRIVATE_KEY" >"${SSH_KEY}"
  lastLine=$(tail -n 1 "${SSH_KEY}")
  if [ "${lastLine}" != "" ]; then
    printf '\n' >>"${SSH_KEY}"
  fi
  chmod 600 "${SSH_KEY}"

  # Configure public key
  printf '%s' "$REMOTE_PUBLIC_KEY" >"${SSH_KEY}.pub"
  lastLine=$(tail -n 1 "${SSH_KEY}.pub")
  if [ "${lastLine}" != "" ]; then
    printf '\n' >>"${SSH_KEY}.pub"
  fi
  chmod 644 "${SSH_KEY}.pub"

  # Start ssh-agent and add key
  eval "$(ssh-agent)"
  if [[ -n "${REMOTE_PRIVATE_KEY_PASSWORD}" ]] || [[ -n "${INPUT_REMOTE_PRIVATE_KEY_PASSWORD}" ]]; then
    # Use expect to handle password-protected key
    # Debug output
    if [ "${DEBUG}" != "0" ]; then
      echo "Debug: Adding key with password"
      echo "Debug: Key file exists: $(test -f "${SSH_KEY}" && echo "yes" || echo "no")"
      echo "Debug: Key file permissions: $(stat -c %a "${SSH_KEY}")"
      echo "Debug: Key file contents check: $(head -n 1 "${SSH_KEY}" | grep -q "BEGIN" && echo "valid" || echo "invalid")"
    fi

    # Handle both regular and INPUT_ prefixed variables
    KEY_PASSWORD="${REMOTE_PRIVATE_KEY_PASSWORD:-${INPUT_REMOTE_PRIVATE_KEY_PASSWORD}}"

    # Debug the key content (first line only)
    if [ "${DEBUG}" != "0" ]; then
      echo "Debug: Testing key decryption..."
      ssh-keygen -y -f "${SSH_KEY}" -P "${KEY_PASSWORD}" >/dev/null 2>&1 && echo "Debug: Key decryption test successful" || echo "Debug: Key decryption test failed"
    fi

    expect -d <<EOF
      log_user 1
      set timeout 20
      set password [lindex {${KEY_PASSWORD}} 0]
      spawn ssh-add ${SSH_KEY}
      expect {
        "Enter passphrase" {
          send "\$password\r"
          exp_continue
        }
        "Identity added" {
          puts "Key added successfully"
          exit 0
        }
        "Bad passphrase" {
          puts "Wrong passphrase provided"
          exit 1
        }
        timeout {
          puts "Timeout waiting for password prompt"
          exit 1
        }
        eof {
          puts "SSH add failed"
          exit 1
        }
      }
EOF
    if [ $? -ne 0 ]; then
      echo "Failed to add SSH key with password"
      exit 1
    fi
  else
    ssh-add "${SSH_KEY}"
  fi
}

configure_env_file() {
  printf '%s' "$ENV_FILE" >"${ENV_FILE_PATH}"
  env_file_len=$(grep -v '^#' ${ENV_FILE_PATH} | grep -v '^$' -c)
  if [[ $env_file_len -gt 0 ]]; then
    echo "Environment Variables: Additional values"
    if [ "${DEBUG}" != "0" ]; then
      echo "Environment vars before: $(env | wc -l)"
    fi
    # shellcheck disable=SC2046
    export $(grep -v '^#' ${ENV_FILE_PATH} | grep -v '^$' | xargs -d '\n')
    if [ "${DEBUG}" != "0" ]; then
      echo "Environment vars after: $(env | wc -l)"
    fi
  fi
}

configure_ssh_host() {
  ssh-keyscan -p "${REMOTE_PORT}" "${REMOTE_HOST}" >"${KNOWN_HOSTS}"
  chmod 600 "${KNOWN_HOSTS}"
}

connect_ssh() {
  cmd="ssh"
  if [ "${SSH_VERBOSE}" != "" ]; then
    cmd="ssh ${SSH_VERBOSE}"
  fi
  user=$(${cmd} -p "${REMOTE_PORT}" "${REMOTE_USER}@${REMOTE_HOST}" whoami)
  if [ "${user}" != "${REMOTE_USER}" ]; then
    exit 1
  fi
}

deploy() {
  docker stack deploy --with-registry-auth -c "${STACK_FILE}" "${STACK_NAME}"
}

check_deploy() {
  echo "Deploy: Checking status"
  /stack-wait.sh -t "${DEPLOY_TIMEOUT}" "${STACK_NAME}"
}

[ -z ${DEBUG+x} ] && export DEBUG="0"

# ADDITIONAL ENV VARIABLES
if [[ -z "${ENV_FILE}" ]]; then
  export ENV_FILE=""
else
  configure_env_file
fi

# SET DEBUG
if [ "${DEBUG}" != "0" ]; then
  OUT=/dev/stdout
  SSH_VERBOSE="-vvv"
  echo "Verbose logging"
else
  OUT=/dev/null
  SSH_VERBOSE=""
fi

# PROCEED WITH LOGIN
if [ -z "${USERNAME+x}" ] || [ -z "${PASSWORD+x}" ]; then
  echo "Container Registry: No authentication provided"
else
  [ -z ${REGISTRY+x} ] && export REGISTRY=""
  if login >/dev/null 2>&1; then
    echo "Container Registry: Logged in ${REGISTRY} as ${USERNAME}"
  else
    echo "Container Registry: Login to ${REGISTRY} as ${USERNAME} failed"
    exit 1
  fi
fi

if [[ -z "${DEPLOY_TIMEOUT}" ]]; then
  export DEPLOY_TIMEOUT=600
fi

# CHECK REMOTE VARIABLES
if [[ -z "${REMOTE_HOST}" ]]; then
  echo "Input remote_host is required!"
  exit 1
fi
if [[ -z "${REMOTE_PORT}" ]]; then
  export REMOTE_PORT="22"
fi
if [[ -z "${REMOTE_USER}" ]]; then
  echo "Input remote_user is required!"
  exit 1
fi
if [[ -z "${REMOTE_PRIVATE_KEY}" ]]; then
  echo "Input private_key is required!"
  exit 1
fi
# CHECK STACK VARIABLES
if [[ -z "${STACK_FILE}" ]]; then
  echo "Input stack_file is required!"
  exit 1
else
  if [ ! -f "${STACK_FILE}" ]; then
    echo "${STACK_FILE} does not exist."
    exit 1
  fi
fi

if [[ -z "${STACK_NAME}" ]]; then
  echo "Input stack_name is required!"
  exit 1
fi

# CONFIGURE SSH CLIENT
if configure_ssh >$OUT 2>&1; then
  echo "SSH client: Configured"
else
  echo "SSH client: Configuration failed"
  exit 1
fi

if configure_ssh_keys >$OUT 2>&1; then
  echo "SSH client: Added private key"
else
  echo "SSH client: Private key failed"
  exit 1
fi

if configure_ssh_host >$OUT 2>&1; then
  echo "SSH remote: Keys added to ${KNOWN_HOSTS}"
else
  echo "SSH remote: Server ${REMOTE_HOST} on port ${REMOTE_PORT} not available"
  exit 1
fi

if connect_ssh >$OUT; then
  echo "SSH connect: Success"
else
  echo "SSH connect: Failed to connect to remote server"
  exit 1
fi

export DOCKER_HOST="ssh://${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT}"

if deploy >$OUT; then
  echo "Deploy: Updated services"
else
  echo "Deploy: Failed to deploy ${STACK_NAME} from file ${STACK_FILE}"
  exit 1
fi

if check_deploy; then
  echo "Deploy: Completed"
else
  echo "Deploy: Failed"
  exit 1
fi
