#!/bin/bash
# Background setup — runs before the user sees the terminal.
# We only install the binary and prepare the environment;
# the learner starts vault dev server themselves in step1.

source /root/setup-common.sh

install_vault

# Ensure tcpdump is available for step3 (packet sniffing demo)
if ! command -v tcpdump > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq tcpdump > /dev/null 2>&1
fi

# Ensure jq is available
if ! command -v jq > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq jq > /dev/null 2>&1
fi

# Prepare workspace
mkdir -p /root/workspace
cd /root/workspace

finish_setup
