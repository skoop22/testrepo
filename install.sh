#!/bin/bash

BASE_PATH=/mgmt/data/tst1
RUNNER_PATH=$BASE_PATH/gh-runner
RUNNER_USER=jf64120
RUNNER_VERSION=$(head -n1 version.txt | tr -d '\r')
RUNNER_NAME=test-runner
RUNNER_GITHUB_URL=https://github.com/skoop22/workflow-test
RUNNER_GROUP=default
RUNNER_WORKDIR=_work
RUNNER_LABELS=self-hosted,linux,x64

set -e

# check if user is root
if [ "$(id -u)" -ne 0 ]; then
  date "+[%F %T-%4N] This script must be run as root. Please use sudo."
  exit 1
fi

if [ -z "${RUNNER_USER}" ]; then
  date "+[%F %T-%4N] RUNNER_USER is not set. Please set it to the user that will run the GitHub Actions runner."
  exit 1
fi

if [ -z "${RUNNER_PATH}" ]; then
  date "+[%F %T-%4N] RUNNER_PATH is not set. Please set it to the path that will run the GitHub Actions runner."
  exit 1
fi

function fix_selinux() {
  date "+[%F %T-%4N] Fixing ownership for $BASE_PATH to $RUNNER_USER:$RUNNER_USER"
  chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_PATH"
  date "+[%F %T-%4N] Fixing SELinux context for $BASE_PATH"
  semanage fcontext -a -t usr_t "${BASE_PATH}(.*)?"
  restorecon -R "$BASE_PATH"
}

function stop_runner() {

  date "+[%F %T-%4N] Stopping GitHub Actions runner"
  if [ -f "${RUNNER_PATH}/.service" ]; then
    RUNNER_SERVICE=$(cat "${RUNNER_PATH}/.service")
    if [ -n "${RUNNER_SERVICE}" ]; then
      systemctl stop "${RUNNER_SERVICE}"
      date "+[%F %T-%4N] Stopped GitHub Actions runner service: ${RUNNER_SERVICE}"
    fi
  else
    date "+[%F %T-%4N] .service file not found nothing to stop"
  fi

}

function start_runner() {
  date "+[%F %T-%4N] Starting GitHub Actions runner"
  if [ -f "${RUNNER_PATH}/.service" ]; then
    RUNNER_SERVICE=$(cat "${RUNNER_PATH}/.service")
    if [ -n "${RUNNER_SERVICE}" ]; then
      systemctl start "${RUNNER_SERVICE}"
      echo "Started GitHub Actions runner service: ${RUNNER_SERVICE}"
    else
      date "+[%F %T-%4N] .service file is empty, cannot start runner"
    fi
  else
    date "+[%F %T-%4N] .service file not found nothing to start"
  fi
}

function update_runner() {

  CURRENT_RUNNER_VERSION=$(sudo -i -u ${RUNNER_USER} ${RUNNER_PATH}/config.sh --version)
  date "+[%F %T-%4N] Current runner version: $CURRENT_RUNNER_VERSION"
  date "+[%F %T-%4N] New runner version: $RUNNER_VERSION"
  if [ "$(printf '%s\n' "$CURRENT_RUNNER_VERSION" "$RUNNER_VERSION" | sort -V -C)" ]; then
    date "+[%F %T-%4N] RUNNER_VERSION ($RUNNER_VERSION) is not higher than CURRENT_RUNNER_VERSION ($CURRENT_RUNNER_VERSION)."
    exit 0
  else
    if [ ${CURRENT_RUNNER_VERSION} == ${RUNNER_VERSION} ]; then
      date "+[%F %T-%4N] RUNNER_VERSION ($RUNNER_VERSION) is equal to CURRENT_RUNNER_VERSION ($CURRENT_RUNNER_VERSION)."
      date "+[%F %T-%4N] not updating runner, version is the same"
      exit 0
    fi
    date "+[%F %T-%4N] RUNNER_VERSION ($RUNNER_VERSION) is higher than CURRENT_RUNNER_VERSION ($CURRENT_RUNNER_VERSION)."
    date "+[%F %T-%4N] extracting runner to tmp folder"
    TEMP_DIR=$(mktemp -d --suffix runner)
    tar -xzf "src/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" -C "$TEMP_DIR"
    date "+[%F %T-%4N] copying new runner files to $RUNNER_PATH"
    mv -fv "$TEMP_DIR/bin" "$RUNNER_PATH/bin.$RUNNER_VERSION"
    mv -fv "$TEMP_DIR/externals" "$RUNNER_PATH/externals.$RUNNER_VERSION"
    date "+[%F %T-%4N] Cleaning up temporary directory $TEMP_DIR"
    rm -rf "$TEMP_DIR"
    stop_runner
    if [[ -L "$RUNNER_PATH/bin" && -d "$RUNNER_PATH/bin" ]]; then
      # return code 0 means it find a bin folder that is a junction folder
      # we just need to delete the junction point.
      date "+[%F %T-%4N] Delete existing junction bin folder"
      rm "$RUNNER_PATH/bin"
      if [ $? -ne 0 ]; then
        date "+[%F %T-%4N] Can't delete existing junction bin folder"
        exit 1
      fi
    else
      # otherwise, we need to move the current bin folder to bin.2.99.0 folder.
      date "+[%F %T-%4N] move $RUNNER_PATH/bin $RUNNER_PATH/bin.$CURRENT_RUNNER_VERSION"
      mv -fv "$RUNNER_PATH/bin" "$RUNNER_PATH/bin.$CURRENT_RUNNER_VERSION"
      if [ $? -ne 0 ]; then
        date "+[%F %T-%4N] Can't move $RUNNER_PATH/bin to $RUNNER_PATH/bin.$CURRENT_RUNNER_VERSION"
        exit 1
      fi
    fi

    # check externals folder
    if [[ -L "$RUNNER_PATH/externals" && -d "$RUNNER_PATH/externals" ]]; then
      # return code 0 means it find a external folder that is a junction folder
      # we just need to delete the junction point.
      date "+[%F %T-%4N] Delete existing junction external folder"
      rm "$RUNNER_PATH/externals"
      if [ $? -ne 0 ]; then
        date "+[%F %T-%4N] Can't delete existing junction external folder"
        exit 1
      fi
    else
      # otherwise, we need to move the current external folder to external.2.99.0 folder.
      date "+[%F %T-%4N] move $RUNNER_PATH/externals $RUNNER_PATH/externals.$CURRENT_RUNNER_VERSION"
      mv -fv "$RUNNER_PATH/externals" "$RUNNER_PATH/externals.$CURRENT_RUNNER_VERSION"
      if [ $? -ne 0 ]; then
        date "+[%F %T-%4N] Can't move $RUNNER_PATH/externals to $RUNNER_PATH/externals.$CURRENT_RUNNER_VERSION"
        exit 1
      fi
    fi
  fi

  # Set the new bin and externals folders
  sudo -u ${RUNNER_USER} ln -s "$RUNNER_PATH/bin.$RUNNER_VERSION" "$RUNNER_PATH/bin"
  sudo -u ${RUNNER_USER} ln -s "$RUNNER_PATH/externals.$RUNNER_VERSION" "$RUNNER_PATH/externals"

  # update runsvc.sh
  if [ -f "$RUNNER_PATH/runsvc.sh" ]; then
    date "+[%F %T-%4N] Update runsvc.sh"
    cat "$RUNNER_PATH/bin/runsvc.sh" >"$RUNNER_PATH/runsvc.sh"
    if [ $? -ne 0 ]; then
      date "+[%F %T-%4N] Can't update $RUNNER_PATH/runsvc.sh using $RUNNER_PATH/bin/runsvc.sh"
      exit 1
    fi
  fi

}

function create_setup_scripts() {
  date "+[%F %T-%4N] Creating setup script for GitHub Actions runner"
  cat <<EOF >"$RUNNER_PATH/setup.sh"
#!/bin/bash
# This script sets up the GitHub Actions runner
set -e

# check if user is root
if [ "\$(id -u)" -ne 0 ]; then
  echo "This script must be run as root. Please use sudo."
  exit 1
fi

TOKEN=\$1
if [ -z "\$TOKEN" ]; then
  echo "Usage: \$0 <TOKEN>"
  exit 1
fi

RUNNER_NAME=${RUNNER_NAME:-$(hostname -s)}
RUNNER_WORKDIR=${RUNNER_WORKDIR:-_work}
RUNNER_LABELS=${RUNNER_LABELS:-self-hosted,linux,x64}
RUNNER_GROUP=${RUNNER_GROUP:-default}

date "+[%F %T-%4N] Configuring GitHub Actions runner with name \$RUNNER_NAME, workdir \$RUNNER_WORKDIR, labels \$RUNNER_LABELS, group \$RUNNER_GROUP"

sudo -u ${RUNNER_USER} ./config.sh --unattended --replace \\
  --url ${RUNNER_GITHUB_URL} \\
  --token \$TOKEN \\
  --name \${RUNNER_NAME} \\
  --work \${RUNNER_WORKDIR} \\
  --labels \${RUNNER_LABELS} \\
  --runnergroup \${RUNNER_GROUP} \\
  --disableupdate

date "+[%F %T-%4N] Activation cleanup script for GitHub Actions runner"
echo "ACTIONS_RUNNER_HOOK_JOB_STARTED=/${RUNNER_PATH}/cleanup.sh" >>.env
chown -R ${RUNNER_USER}:${RUNNER_USER} .env

date "+[%F %T-%4N] installing github actions runner as user ${RUNNER_USER}"
./svc.sh install ${RUNNER_USER}
./svc.sh start
EOF

  chmod +x "$RUNNER_PATH/setup.sh"
}

# This script installs the GitHub Actions runner to a specified directory

function create_cleanup_script() {
  date "+[%F %T-%4N] Creating setup script for GitHub Actions runner"
  cat <<EOF >"$RUNNER_PATH/cleanup.sh"
#!/bin/bash
# This script cleans up the GitHub Actions runner after a job is completed
if [ -n "\${GITHUB_WORKSPACE}" ]; then
  echo "cleaning workspace \$GITHUB_WORKSPACE"
  rm -rf "\$GITHUB_WORKSPACE" && mkdir -p "\$GITHUB_WORKSPACE"
fi
EOF

  chmod +x "$RUNNER_PATH/cleanup.sh"
}

if [ -x "${RUNNER_PATH}/config.sh" ]; then
  date "+[%F %T-%4N] Runner is already installed $RUNNER_PATH updating version to $RUNNER_VERSION"
  # stop_runner
  update_runner
  create_setup_scripts
  create_cleanup_script
  fix_selinux
  start_runner
  date "+[%F %T-%4N] Runner updated successfully to version $RUNNER_VERSION"
else
  date "+[%F %T-%4N] Creating directory $RUNNER_PATH"
  mkdir -p "$RUNNER_PATH"
  date "+[%F %T-%4N] Extracting runner version $RUNNER_VERSION to $RUNNER_PATH"
  tar -xzf "src/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" -C "$RUNNER_PATH"
  create_setup_scripts
  create_cleanup_script
  fix_selinux
fi
