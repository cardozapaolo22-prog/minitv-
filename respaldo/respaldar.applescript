-- Respaldar MiniTV: lanza ~/minitv/respaldo/respaldar.sh en segundo plano (avisa al terminar).
on run
	set guion to (POSIX path of (path to home folder)) & "minitv/respaldo/respaldar.sh"
	do shell script "/usr/bin/caffeinate -i /bin/bash " & quoted form of guion & " > /dev/null 2>&1 &"
end run
