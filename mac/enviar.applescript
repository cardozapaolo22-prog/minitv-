-- Enviar a MiniTV: arrastra videos, juegos o carpetas encima del ícono (o ábrela y elige archivos).
-- El trabajo lo hace enviar-a-minitv.sh (dentro de la app), en segundo plano; avisa al terminar.
on open lista
	set argumentos to ""
	repeat with f in lista
		set argumentos to argumentos & " " & quoted form of (POSIX path of f)
	end repeat
	set guion to POSIX path of (path to resource "enviar-a-minitv.sh")
	do shell script "/bin/bash " & quoted form of guion & argumentos & " > /dev/null 2>&1 &"
end open

on run
	set lista to choose file with prompt "Elige videos o juegos para la MiniTV (o arrastra carpetas encima del ícono)" with multiple selections allowed
	open lista
end run
