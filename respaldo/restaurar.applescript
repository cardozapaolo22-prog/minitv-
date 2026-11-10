-- Restaurar contenido MiniTV: devuelve videos, juegos, partidas y memoria a la MiniTV.
on run
	display dialog "Esto copiará a la MiniTV los videos, juegos, partidas y la memoria de reproducción guardados en MiniTV-Respaldo. No se borra nada de la MiniTV." & return & return & "Úsalo después de grabar la imagen del sistema en una tarjeta nueva, o si se perdió algo." with title "Restaurar contenido MiniTV" buttons {"Cancelar", "Restaurar"} default button "Restaurar" cancel button "Cancelar" with icon note
	set guion to (POSIX path of (path to home folder)) & "minitv/respaldo/restaurar.sh"
	do shell script "/usr/bin/caffeinate -i /bin/bash " & quoted form of guion & " > /dev/null 2>&1 &"
	display notification "Restaurando el contenido. Te aviso al terminar." with title "Restaurar MiniTV"
end run
