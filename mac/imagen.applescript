-- Imagen para otra MiniTV: crea y descarga una imagen limpia del sistema (avisa al terminar).
on run
	set r to display dialog "Se va a crear una imagen del sistema para armar OTRA MiniTV igual (sin tus videos, juegos, partidas ni claves).

La TV se apaga unos minutos mientras se copia y luego vuelve sola. La descarga puede tardar un rato." with title "Imagen para otra MiniTV" buttons {"Cancelar", "Crear imagen"} default button "Crear imagen"
	if button returned of r is "Crear imagen" then
		set guion to POSIX path of (path to resource "imagen-otra-minitv.sh")
		do shell script "/usr/bin/caffeinate -i /bin/bash " & quoted form of guion & " > /dev/null 2>&1 &"
	end if
end run
