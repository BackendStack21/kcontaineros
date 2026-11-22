# The last command of a script replaces the shell, so it keeps the same PID.
echo first
echo $$ > /t/lastexec.pid
/bb/busybox sh -c 'echo "same pid: $(( $$ == $(cat /t/lastexec.pid) ))"'
# a trailing comment and blank lines do not prevent it

