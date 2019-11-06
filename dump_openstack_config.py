#!/usr/bin/python2
#Script to dump running config from OpenStack services
import os
import psutil
import re
import signal
import subprocess
from sys import argv
from pwd import getpwnam
import argparse
import textwrap


def _is_cmd_available(cmd_name):

  try:
    with open(os.devnull) as devnull:
      subprocess.Popen([cmd_name], stdout=devnull, stderr=devnull).communicate()
  except OSError as e:
    if e.errno == os.errno.ENOENT:
      return False

  return True


def demote(user_uid, user_gid):
  def set_ids():
    os.setgid(user_gid)
    os.setuid(user_uid)
    return set_ids


def main(proc_name):

  proc_alive = False
  # Get proc pid
  for p in psutil.process_iter():
    if proc_name in str(p.name):
      proc_pid = p.pid
      proc_user = p.username()
      proc_alive = True

  if not proc_alive:
    print("[ERROR] No such process: %s" % proc_name)
    print("Did you specify it correctly on the command line?")
    print
    print("  Example: %s nova-api" % str(argv[0]))
    return False

  # Get proc user uid/gid
  proc_uid = getpwnam(proc_user).pw_uid
  proc_gid = getpwnam(proc_user).pw_gid

  # attach using strace with nova uid/gid
  strace_cmd = [
    "strace",
    "-qq",
    "-ff",
    "-e",
    "trace=write",
    "-e",
    "write=2",
    "-s",
    "65535",
    "-p",
    str(proc_pid)
  ]

  strace_proc = subprocess.Popen(
    strace_cmd,
    stderr=subprocess.PIPE,
    stdout=open(os.devnull, 'w'),
    preexec_fn=demote(proc_uid, proc_gid)
  )

  # send USR2 signal to proc pid to dump runtime config
  os.kill(proc_pid, signal.SIGUSR2)

  # catch stderr from dump
  stderr = strace_proc.stderr
  run = True
  dump = []
  cpu_mode = False
  cpu_model = False
  cpu_model_extra_flags = False
  maximum_chunks = 1024
  chunk_size = 1024
  chunks = 0

  while run:
    chunks += 1
    # read with small chunks
    lines = stderr.read(chunk_size).split("\n")
    dump.append(lines)
    for line in lines:
      # if all three params are in dump, terminate strace
      if chunks > maximum_chunks or '20 20 20 20 20 20 20 20' in line:
        os.kill(strace_proc.pid, signal.SIGTERM)
        run = False

  dump_text = ''
  for el in dump:
    dump_text+=el[0]

  try_regex = r'\bwrite\(2, \"(.*)\", \d+\) = \d+\b'
  try_template = re.search(try_regex, dump_text)
  config = []
  if try_template:
    config = try_template.group(1)

  try:
    for line in config.split('\\n'):
      print(line)
  except:
    print(dump_text)

if __name__ == "__main__":
  # This script must be run as root!
  if not os.geteuid()==0:
    sys.exit('This script must be run as root!')

  parser = argparse.ArgumentParser(
    formatter_class=argparse.RawDescriptionHelpFormatter,
    description=textwrap.dedent('''\
      Dump running config from OpenStack process.
    '''), prog=argv[0], usage='%(prog)s [proc_name]') 

  parser.add_argument('proc_name', type=str, nargs=1,
                     choices=['nova-api', 'nova-scheduler', 'heat-engine',
                              'heat-api-cfn', 'heat-api', 'cinder-volume'],
                     help='OpenStack process name to dump config from')

  args = parser.parse_args()

  if len(argv) < 2:
    parser.print_help()
    exit(0)  

  if _is_cmd_available('strace'):
    if len(argv) > 1:
      main(argv[1])
    else:
      main()
  else:
    print("You do not have strace installed, please install it first")