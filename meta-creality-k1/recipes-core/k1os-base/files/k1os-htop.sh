# shellcheck shell=sh
# htop saves its settings when it ends. Its place for them is under the home
# directory, and root's is on the read-only root file system: every exit said
# "Can not save configuration". /usr/data is writable, and both slots share it.
export HTOPRC=/usr/data/k1os/htoprc
