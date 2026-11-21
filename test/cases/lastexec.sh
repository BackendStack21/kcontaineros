# The last command of a script replaces the shell, so it keeps the same PID.
echo first
echo $$ > /t/lastexec.pid
/bb/busybox sh -c 'echo "same pid: $(( $$ == $(cat /t/lastexec.pid) ))"'
# a trailing comment, blank lines and semicolons do not prevent it
  ;

