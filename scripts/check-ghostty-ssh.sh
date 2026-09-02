#!/bin/zsh
# Exercise the experimental libghostty SSH pane against a throwaway server.
#
# Deliberately a container and not this Mac's sshd: testing should not require
# adding a key to ~/.ssh/authorized_keys, which is a change to who can log in.
#
# Not fully automatic — the pane still needs a click to trust the host key the
# first time, and the timings have to be read back out of the container. What
# this does is set up everything around that.
set -e
cd ${0:A:h}/..
dir=${GHOSTTY_SSH_TEST_DIR:-/tmp/macmoba-sshspike}

docker rm -f macmoba-sshtest >/dev/null 2>&1 || true
docker run -d --name macmoba-sshtest -p 2222:22 alpine sh -c \
  "apk add --no-cache openssh >/dev/null && ssh-keygen -A && adduser -D tester \
   && echo 'tester:secret' | chpasswd && /usr/sbin/sshd -D -e" >/dev/null
echo "sshd starting on 2222 (tester/secret) ..."

rm -rf $dir
swift build --product ghostty-ssh-seed >/dev/null
.build/debug/ghostty-ssh-seed $dir

cat <<TXT

Now:
  open -a ./MacMoba.app --env MACMOBA_DATA_DIR=$dir
  unlock with: testpassword123
  Session > Connect in libghostty (experimental) > ghostty-ssh-test
  trust the host key when asked

To compare throughput, in each pane:
  { time cat /tmp/cjk.txt ; } 2> /tmp/t_<name>
then read it back with:
  docker exec macmoba-sshtest cat /tmp/t_<name>

Tear down with: docker rm -f macmoba-sshtest
TXT
