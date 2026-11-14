# homeserver

Servidor casero en el PC viejo: Debian 13 sin escritorio, administrado por SSH y accesible desde afuera solo por NordVPN Meshnet.

**Hardware:** Dell (BIOS A08, 2011) · Core 2 Quad Q8400 · 4 GB DDR3 (2 ranuras libres) · HDD.

```
homeserver/
├── bootstrap.sh              base del sistema (correr una vez en el servidor)
└── services/
    └── nosotros/             app de pareja (repo ~/Projects/SJ)
        ├── deploy.sh         ← se corre desde TU PC
        ├── instalar.sh       ← lo ejecuta deploy.sh en el servidor
        ├── nosotros.service  plantilla systemd
        └── backup/           ← timer en TU PC que trae los backups del servidor
```

Lo que se escribe en este README son comandos fish (tu PC) o bash (el servidor), según cada paso.

---

## 1. BIOS (tecla F2 al encender)

- **Power Management → AC Recovery → Power On**: si se corta la luz, vuelve a encender solo.
- **System Configuration → SATA Operation → AHCI**.
- Revisá que la fecha y la hora estén bien.
- Este equipo no tiene UEFI, así que arranca en modo BIOS clásico. El USB de Debian funciona igual.

## 2. USB de instalación (en tu PC)

Bajá la imagen **netinst amd64** de <https://www.debian.org/distrib/netinst> (`debian-13.*-amd64-netinst.iso`, unos 700 MB).

Grabala en un USB. Primero mirá con `lsblk` cuál es el USB: **todo lo que tenga se va a borrar**.

```fish
lsblk
sudo dd if=debian-13.*-amd64-netinst.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

Si preferís hacerlo con una ventana, sirven *GNOME Disks* ("Restaurar imagen de disco") o *Impression*.

## 3. Instalación

**Conectá el PC al router con cable** antes de empezar. Después, enchufá el USB, encendé y apretá **F12** para elegir arrancar desde el USB.

| Pantalla                    | Qué elegir                                                                          |
|-----------------------------|-------------------------------------------------------------------------------------|
| Menú                        | *Install* (el modo texto alcanza)                                                   |
| Idioma / país / teclado     | Español · tu país · Latinoamericano                                                 |
| Nombre de la máquina        | `servidor` (dominio: vacío)                                                         |
| Contraseña de **root**      | **Dejala vacía.** Así tu usuario queda con `sudo` y no hay login de root.           |
| Usuario                     | `josep` con una contraseña fuerte                                                   |
| Particionado                | Guiado: utilizar todo el disco → Todos los ficheros en una partición                |
| Réplica                     | `deb.debian.org`                                                                    |
| Encuesta de popularidad     | No                                                                                  |
| **Selección de programas**  | Desmarcá *Entorno de escritorio* y *GNOME*. Dejá solo **servidor SSH** y **utilidades estándar del sistema** |
| GRUB                        | Sí, en el disco (`/dev/sda`)                                                        |

Cuando termine, sacá el USB y reiniciá. Iniciá sesión en la consola y anotá la IP de la red local:

```bash
ip -br a        # buscá algo como 192.168.x.x en la interfaz enpXsY / eno1
```

Si podés, reservá esa IP en el router (DHCP estático). Así no cambia y no tenés que actualizar la configuración de SSH.

## 4. Conectarte por SSH (desde tu PC)

Agregá esto a `~/.ssh/config`:

```
Host servidor
    HostName 192.168.x.x
    User josep
```

Después:

```fish
test -f ~/.ssh/id_ed25519; or ssh-keygen -t ed25519
ssh-copy-id servidor
ssh servidor            # ya no debería pedir contraseña
```

## 5. Bootstrap

```fish
scp -r ~/Projects/homeserver servidor:
ssh -t servidor 'sudo bash homeserver/bootstrap.sh'
```

Al terminar te muestra:
- las reglas del firewall,
- la salud del disco (SMART). Si `Reallocated_Sector_Ct` o `Current_Pending_Sector` no están en 0, el disco está fallando y conviene cambiarlo por un SSD antes de guardar cosas importantes.

Si dice que hay que reiniciar: `ssh servidor sudo reboot`.

## 6. Meshnet (en el servidor)

```bash
sh <(curl -sSf https://downloads.nordcdn.com/apps/linux/install.sh)
sudo usermod -aG nordvpn $USER
exit                                   # salir y volver a entrar para que tome el grupo
```

```bash
# Token: Nord Account → NordVPN → "Get access token" (acceso manual)
nordvpn login --token TU_TOKEN
nordvpn set meshnet on
nordvpn meshnet peer list              # anotá el nombre *.nord del servidor y el de tus dispositivos
nordvpn meshnet peer incoming allow <tu-pc>.nord
nordvpn meshnet peer incoming allow <tu-celu>.nord
```

- **No hagas `nordvpn connect`** en el servidor. Meshnet funciona sin conectarse a un servidor VPN, y la VPN conectada le cortaría el acceso desde la LAN.
- Cuando Meshnet ande, podés cambiar `HostName` en `~/.ssh/config` por el nombre `*.nord` del servidor. Así entrás por SSH desde cualquier lugar.
- El firewall sigue dejando entrar SSH desde la LAN. Es la puerta de emergencia por si Meshnet falla.

## 7. Nosotros

Desde tu PC:

```fish
# primera vez, llevando fotos/usuarios/mensajes del servidor de prueba:
~/Projects/homeserver/services/nosotros/deploy.sh --con-datos

# actualizaciones posteriores (frontend o migraciones nuevas):
~/Projects/homeserver/services/nosotros/deploy.sh
```

`deploy.sh` hace todo esto:
1. Compila `SJ/web`.
2. Sube el frontend y las migraciones.
3. En el servidor, `instalar.sh`:
   - descarga PocketBase y verifica el SHA-256,
   - crea el usuario de sistema `nosotros`,
   - instala el servicio en `/srv/nosotros`,
   - abre el puerto 8090 **solo para Meshnet**.

Con Meshnet activo, la app queda en `http://<servidor>.nord:8090` y el panel admin en `/_/`.

Útil en el servidor:

```bash
systemctl status nosotros
journalctl -u nosotros -f
sudo bash homeserver/services/nosotros/instalar.sh --desinstalar   # no borra /srv/nosotros/pb_data
```

> El esquema de la base se cambia en el repo SJ (`pb_migrations`), no desde el panel del servidor.
> El servicio corre con `--automigrate=false`.

## 8. Backups

Dos copias: el **servidor** genera un zip diario (base + fotos) y tu **PC** lo trae por Meshnet.

**En el servidor**, una sola vez:

1. Panel (`http://<servidor>.nord:8090/_/`) → Settings → Backups:
   - **Auto backups** activado, cron `0 8 * * *` (va en **UTC**: 2 AM en CST; evitá las 04:30, que es cuando puede reiniciarse por actualizaciones),
   - **Max auto backups**: `7`.
2. Darle a tu usuario permiso de lectura (los datos son del usuario `nosotros`):

   ```bash
   sudo usermod -aG nosotros $USER
   exit                                   # volver a entrar
   ls -l /srv/nosotros/pb_data/backups    # tiene que listar sin error
   ```

**En tu PC**, una sola vez:

```fish
mkdir -p ~/.config/systemd/user
cp ~/Projects/homeserver/services/nosotros/backup/nosotros-backup.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user start nosotros-backup.service      # prueba
journalctl --user -u nosotros-backup -n 5
systemctl --user enable --now nosotros-backup.timer
```

- El timer corre cada hora (si no hay nada nuevo no transfiere casi nada) y, si la PC estuvo apagada, al prenderla.
- Guarda los zips en `~/Backups/nosotros` y borra los de más de 30 días.
- Si no hay ningún backup de las últimas 48 h, el servicio queda en **failed**: revisalo de vez en cuando con `systemctl --user status nosotros-backup`.
- La clave SSH no puede tener passphrase (el timer no puede escribirla); si la tiene, falla con `Permission denied`.

**Restaurar**: panel → Settings → Backups → subir el zip → *Restore*. Reemplaza **todos** los datos actuales.

---

## Pendiente

- RAM: pasar a 8 GB con 2 módulos DDR3 1066/1333 en las ranuras libres.
- Cambiar el HDD por un SSD.
