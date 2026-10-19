# Server dedicato PokeWilds (Windows)

Il server dedicato tiene acceso un mondo co-op su un PC Windows, senza un
giocatore davanti: i telefoni (e i PC) si collegano con indirizzo IP e porta,
giocano quando vogliono, e il mondo resta sul server anche quando escono tutti.

Il server è l'"host" del co-op di sempre, con un giocatore suo invisibile fermo
allo spawn: nessuno lo vede, non conta tra i giocatori e non può essere sfidato.

## Scaricare

Su GitHub, nella pagina **Releases**, prendi l'ultima `server-build-N` e scarica
`PokeWilds-Server-win64.zip`. Estrailo in una cartella (per esempio
`C:\PokeWilds-Server`). Dentro ci sono:

| File | A cosa serve |
| --- | --- |
| `start_server.bat` | **Avvio consigliato**: doppio clic e parte il server |
| `PokeWilds.exe`, `PokeWilds.pck` | il gioco (in modalità server) |
| `PokeWilds.console.exe` | lo stesso, con la console, per chi vuole lanciarlo a mano |
| `server_launcher.ps1` | usato da `start_server.bat` |
| `server.cfg.example` | esempio di impostazioni |

Il server e i telefoni devono avere **la stessa versione** del gioco e le stesse
mod attive: altrimenti il telefono viene rifiutato ("Game versions do not
match" o "Enabled mods ... must match"). Aggiorna il server ogni volta che
installi una nuova build iOS.

## Avviare

**Doppio clic su `start_server.bat`.** La prima volta crea il mondo (qualche
minuto per le taglie grandi), poi scrive qualcosa come:

```
SERVER world ready, listening on TCP port 54555
SERVER   LAN 192.168.1.14:54555  join code 1HGE13I2
SERVER commands: stop, save, players
```

L'indirizzo `LAN` è quello da usare dalla stessa rete Wi-Fi.

Per fermarlo: **Ctrl+C**, oppure chiudi la finestra, oppure scrivi `stop` e
Invio. In tutti e tre i casi il server salva il mondo prima di uscire.

Comandi che puoi scrivere nella finestra:

- `stop` salva e spegne
- `save` salva subito
- `players` elenca chi è collegato

Il server salva anche da solo ogni 5 minuti, e ogni azione dei giocatori
(costruzioni, scambi, catture...) viene scritta subito nel diario del mondo:
anche se il PC si spegne di colpo si perde al massimo qualche minuto di
movimento dei Pokémon.

### Opzioni

Si possono dare a `start_server.bat` o a `PokeWilds.console.exe --headless --server`:

| Opzione | Significato | Predefinito |
| --- | --- | --- |
| `--port N` | porta TCP | `54555` |
| `--world NOME` | nome del mondo: lo carica se esiste, altrimenti lo crea | `PokeWilds` |
| `--size S` | taglia di un mondo nuovo: `S`, `M`, `L`, `XL`, `XXL` | `M` |
| `--password P` | password per entrare (max 16 caratteri) | nessuna |
| `--data CARTELLA` | dove tenere i mondi | `server_data` accanto all'exe |
| `--config FILE` | file di impostazioni | `server.cfg` accanto all'exe |

Esempio: `start_server.bat --world Isola --size L --port 50000`

Al posto delle opzioni puoi copiare `server.cfg.example` in `server.cfg` e
modificarlo (porta, mondo, taglia, password, numero massimo di giocatori da 1 a
4, minuti tra un salvataggio automatico e l'altro). Le opzioni da riga di
comando vincono sul file.

**Nota:** se lanci direttamente `PokeWilds.console.exe --headless --server`,
Ctrl+C e la chiusura della finestra spengono il server **senza** salvare (è un
limite di Godot): in quel caso usa il comando `stop`. Con `start_server.bat`
invece salvano sempre.

### I dati

Tutto il mondo sta in `server_data` (accanto all'exe): per un backup copia la
cartella a server spento. Il server tiene anche da sé le ultime 5 copie in
`server_data\online_worlds\<id>\backups`. Più mondi possono convivere: cambia
`--world` per passare dall'uno all'altro.

## Aprire la porta

### Firewall di Windows

Al primo avvio Windows chiede se consentire a PokeWilds l'accesso alla rete:
spunta almeno **Reti private** e conferma. Se hai detto di no, o vuoi farlo a
mano, apri PowerShell **come amministratore** e scrivi:

```
New-NetFirewallRule -DisplayName "PokeWilds server" -Direction Inbound -Protocol TCP -LocalPort 54555 -Action Allow
New-NetFirewallRule -DisplayName "PokeWilds lobby" -Direction Inbound -Protocol UDP -LocalPort 54556 -Action Allow
```

(la seconda regola serve solo perché il server compaia da solo in
MULTIPLAYER > JOIN GAME sulla stessa rete Wi-Fi; se usi un'altra porta,
cambia `54555`).

### Router (per giocare fuori casa)

Dalla stessa Wi-Fi basta il firewall. Per collegarti da fuori (rete mobile,
casa di un amico):

1. Dai al PC del server un **IP fisso** nella rete di casa (dal router:
   "DHCP statico" / "prenotazione indirizzo"), così non cambia.
2. Nel router apri il **port forwarding** (a volte "Virtual server" o "NAT"):
   porta esterna **TCP 54555** verso l'IP del PC, porta interna 54555.
3. Trova il tuo **IP pubblico** (per esempio cercando "what is my ip"): è
   l'indirizzo da usare da fuori, insieme alla porta.

Se l'IP pubblico cambia spesso puoi usare un nome DNS dinamico gratuito
(DuckDNS, No-IP...): nel gioco si può scrivere anche un nome, per esempio
`casa.duckdns.org:54555`.

Se dopo il port forwarding da fuori non si collega niente, il tuo operatore
potrebbe usare il **CGNAT** (l'IP "WAN" mostrato dal router è diverso dall'IP
pubblico, o inizia con `100.64`–`100.127`): in quel caso la porta non si può
aprire. Alternative: chiedere all'operatore un IP pubblico, oppure installare
una VPN come Tailscale o ZeroTier sul PC e sui telefoni e usare l'indirizzo
che la VPN dà al PC.

## Collegarsi dal telefono

1. Apri PokeWilds, scegli **MULTIPLAYER**, poi **JOIN BY IP**.
2. Scrivi l'indirizzo del server con la porta, per esempio
   `192.168.1.14:54555` in casa oppure `93.40.12.34:54555` da fuori. Se la
   porta è quella predefinita puoi scrivere solo l'IP. Va bene anche il
   **join code** di 8 caratteri che il server mostra all'avvio (solo sulla
   porta 54555). Il gioco ricorda l'ultimo indirizzo usato.
3. Premi A (o Invio sulla tastiera), scegli il personaggio e premi **JOIN!**.
4. Se il server ha una password il gioco te la chiede.

Sulla stessa Wi-Fi il server compare anche da solo in **JOIN GAME**.

## Limiti da sapere

- Fino a 4 giocatori insieme.
- Ogni zona nuova della mappa viene creata dal dispositivo del primo giocatore
  che ci entra (come nel co-op normale): su un telefono può richiedere qualche
  minuto; poi è salvata sul server e gli altri la ricevono già pronta.
- La password protegge l'ingresso, ma il traffico non è cifrato: non usare una
  password che usi altrove.
- Chi conosce l'indirizzo e la porta può provare a entrare: se apri la porta
  su Internet metti una password.
