# Server dedicato PokeWilds (Windows)

Il server dedicato tiene acceso un mondo co-op su un PC Windows, senza un
giocatore davanti: i telefoni (e i PC) si collegano con indirizzo IP e porta,
in casa o da fuori, giocano quando vogliono, e il mondo resta sul server anche
quando escono tutti.

## In tre passi

1. **Scarica** l'ultimo server: [PokeWilds-Server-win64.zip](https://github.com/LucaFagnoni/pokewilds-mobile/releases/latest/download/PokeWilds-Server-win64.zip).
   Estrailo in una cartella, per esempio `C:\PokeWilds-Server`.
2. **Doppio clic su `start_server.bat`.** La prima volta Windows chiede il
   permesso di aprire il firewall per PokeWilds: rispondi **Sì**. Dopo qualche
   istante (qualche minuto per un mondo grande) il server scrive:

   ```
   SERVER  Same Wi-Fi:     192.168.1.14:54555   code 1HGE13I2
   SERVER  From outside:   93.40.12.34:54555   code 4K2J9XQ1
   SERVER    Router port opened automatically (UPnP).
   ```

3. **Sul telefono**: PokeWilds > **MULTIPLAYER** > **MY SERVERS** > **ADD SERVER**.
   Scrivi un nome a piacere, l'indirizzo (oppure il codice di 8 caratteri),
   il tuo **ID** e una **password**, e salva:
   - in casa, sulla stessa Wi-Fi: l'indirizzo di **Same Wi-Fi**;
   - fuori casa (rete mobile, casa di un amico): quello di **From outside**.

   Tocca il server nella lista, scegli il personaggio e premi **JOIN!**. La
   lista resta salvata nel telefono anche dopo un aggiornamento del gioco:
   la volta dopo basta un tocco. **EDIT** accanto a ogni server cambia nome,
   indirizzo, ID o password, o lo cancella. Se il server è sulla stessa Wi-Fi
   compare anche in **JOIN GAME**: toccandolo si apre la scheda già pronta e
   basta scrivere ID e password. La prima
   volta che entri con un ID nuovo, il server lo crea con quella password
   (vedi "Giocatori: ID e password").

Il server apre da solo la porta sul router (UPnP) e la richiude quando si
spegne, apre da solo il firewall di Windows e tiene sveglio il PC finché è
acceso (lo schermo può spegnersi): di solito non serve toccare nient'altro.

Server e telefoni devono essere **compatibili** e avere le stesse mod attive.
Ogni release contiene l'IPA e il server costruiti dallo stesso commit: scaricare
entrambi dalla stessa release funziona sempre. Una build più nuova che ha
cambiato solo la parte del telefono (HUD, comandi touch, menu, suoni: l'elenco è
in tools/client_only_paths.txt) entra anche nel server vecchio, e in MY SERVERS
il server resta verde. Altrimenti il telefono viene rifiutato con
"DIFFERENT GAME VERSION: HOST ..., YOURS ...": le due versioni dicono quale
build ha il server e quale il telefono, e va aggiornato il server (o il
telefono). Le build fatte in locale non hanno codice e non vengono controllate.

## Se "From outside" dice altro

- **"The router did not open the port by itself"**: il router ha l'UPnP
  spento. Accendilo nelle impostazioni del router (di solito sotto "Rete",
  "NAT" o "Avanzate"; si chiama "UPnP" o "UPnP IGD") e riavvia il server.
  In alternativa apri la porta a mano:
  1. dai al PC un **IP fisso** nella rete di casa (dal router: "DHCP statico"
     o "prenotazione indirizzo");
  2. crea un **port forwarding** (a volte "Virtual server"): porta **TCP
     54555** verso l'IP del PC (quello di "Same Wi-Fi").
- **"this router is behind another router"**: in casa ci sono due router in
  fila (per esempio il modem dell'operatore e un tuo router). Metti il primo
  in modalità **bridge**, oppure apri la porta TCP 54555 anche sul primo,
  verso l'indirizzo del secondo.
- **"NOT POSSIBLE on this internet line"**: l'operatore mette più case dietro
  un solo indirizzo pubblico (**CGNAT**), e da fuori nessuno può raggiungere
  il PC, qualunque cosa si faccia sul router. Le strade:
  - chiedere all'operatore un **IP pubblico** (spesso gratis o pochi euro, a
    volte basta chiedere di "uscire dal CGNAT");
  - usare **Tailscale** (gratis): installalo sul PC del server e sui telefoni,
    entra con lo stesso account e usa sul telefono l'indirizzo che il server
    mostra alla riga **Tailscale/VPN** (inizia con `100.`), per esempio
    `100.x.y.z:54555`;
  - se compare la riga "Phones with IPv6 may still try ...", i telefoni con
    IPv6 (molte reti mobili) possono provare quell'indirizzo, se il router lo
    lascia passare.
- **L'indirizzo è cambiato**: molte linee cambiano IP pubblico quando il
  router si riavvia. Il server lo mostra a ogni avvio; scrivi `address` nella
  sua finestra per vederlo di nuovo. Per un indirizzo che non cambia mai puoi
  usare un nome DNS dinamico gratuito (DuckDNS, No-IP...): nel gioco si può
  scrivere anche un nome, per esempio `casa.duckdns.org:54555`.
- Il **codice** di 8 caratteri funziona solo con la porta predefinita 54555.

## Giocatori: ID e password

Sul server ogni giocatore entra con un **ID** (da 3 a 16 caratteri tra
lettere, numeri, `_` e `-`; maiuscole e minuscole sono uguali) e una
**password**.

- **Il personaggio segue l'ID**: con lo stesso ID e la stessa password da un
  altro telefono ritrovi il tuo personaggio, con squadra e zaino, dove
  l'avevi lasciato.
- **Chi giocava già prima degli ID** tiene il suo personaggio: la prima volta
  che entra con un ID nuovo dallo stesso telefono, quell'ID prende il
  personaggio che quel telefono aveva su questo server.
- **Chi può creare un ID** lo decide `accounts` in `server.cfg` (o
  `--accounts`):
  - `open` (predefinito): il primo accesso con un ID nuovo lo crea, con la
    password usata quella volta;
  - `closed`: entrano solo gli ID che crei tu dalla finestra del server con
    `account add ID PASSWORD`; chi prova un ID che non esiste viene rifiutato
    ("UNKNOWN PLAYER ID");
  - `off`: niente ID, come prima: ogni telefono è un giocatore, e vale la
    `password` condivisa del server (se c'è). Con gli ID attivi quella
    password non serve e viene ignorata.
- **Password dimenticata**: `account password ID NUOVA` dalla finestra del
  server; il giocatore poi la cambia nella lista dei server sul telefono.
- Il server non conserva le password: in `server_data\accounts.json` c'è solo
  un hash con sale per ciascun ID. Al login il telefono dimostra di conoscere
  la password senza mandarla; solo la prima volta, quando l'ID viene creato,
  viaggia (una volta sola) il suo hash.

Messaggi che il telefono può mostrare: "WRONG PLAYER ID OR PASSWORD",
"UNKNOWN PLAYER ID" (server `closed`), "THIS SERVER NEEDS A PLAYER ID AND
PASSWORD" (manca l'ID nella scheda del server), "THIS PLAYER IS ALREADY
CONNECTED" (lo stesso ID è già in gioco da un altro telefono).

## Fermare il server e comandi

Per fermarlo: **Ctrl+C**, oppure chiudi la finestra, oppure scrivi `stop` e
Invio. In tutti e tre i casi il server salva il mondo prima di uscire e
richiude la porta sul router.

Con `stop` o `restart` e qualcuno collegato, i giocatori vedono prima un conto
alla rovescia sotto l'orologio ("SERVER SHUTTING DOWN IN 30 S", "SERVER
RESTARTING IN 30 S"), poi il server salva e chiude; sul telefono compare
"THE SERVER WAS SHUT DOWN." oppure "SERVER RESTARTING. TRY AGAIN IN A MOMENT.".
Se non c'è nessuno, o con `stop 0` / Ctrl+C, si spegne subito. `cancel` ferma
il conto alla rovescia. `restart` riparte da solo solo se il server è stato
avviato con `start_server.bat` (che lo rilancia quando esce con il codice 75).

Comandi che puoi scrivere nella finestra:

| Comando | Cosa fa |
| --- | --- |
| `stop [SECONDI]` | avvisa i giocatori per 30 secondi (o quanti ne scrivi, `0` = subito), salva e spegne; anche `quit` o `exit` |
| `restart [SECONDI]` | come `stop`, poi riparte da solo |
| `cancel` | annulla lo `stop` o il `restart` in corso |
| `maxplayers N` | giocatori massimi, da 1 a 8, subito e in `server.cfg`; chi è già dentro resta, i nuovi entrano quando c'è posto |
| `list on` / `list off` | mette o toglie il server dalla lista **JOIN GAME** dei telefoni (anche `publish` / `unpublish`), e lo scrive in `server.cfg` |
| `save` | salva subito |
| `players` | elenca chi è collegato (1ST, 2ND...) |
| `address` | mostra di nuovo gli indirizzi per collegarsi |
| `kick NOME` | butta fuori un giocatore (può rientrare); va bene anche `kick 1` |
| `ban NOME` | lo butta fuori e non lo fa più entrare in questo mondo |
| `bans` | elenca i giocatori bannati |
| `unban NOME` | toglie il ban |
| `accounts` | elenca gli ID dei giocatori |
| `account add ID PASSWORD` | crea un ID (serve con `accounts=closed`) |
| `account password ID PASSWORD` | dà una nuova password a un ID |
| `account remove ID` | cancella un ID (il suo personaggio resta nel mondo) |

Il server salva anche da solo ogni 5 minuti, e ogni azione dei giocatori
(costruzioni, scambi, catture...) viene scritta subito nel diario del mondo:
anche se il PC si spegne di colpo si perde al massimo qualche minuto di
movimento dei Pokémon.

## Opzioni

Si possono dare a `start_server.bat` (per esempio
`start_server.bat --world Isola --size L`) o scrivere in `server.cfg`:

| Opzione | Significato | Predefinito |
| --- | --- | --- |
| `--port N` | porta TCP | `54555` |
| `--world NOME` | nome del mondo: lo carica se esiste, altrimenti lo crea | `PokeWilds` |
| `--size S` | taglia di un mondo nuovo: `S`, `M`, `L`, `XL`, `XXL` | `M` |
| `--accounts M` | ID dei giocatori: `open`, `closed` o `off` (vedi sopra) | `open` |
| `--password P` | password condivisa, solo con `--accounts off` (max 16 caratteri) | nessuna |
| `--no-upnp` | non aprire la porta sul router da solo | (la apre) |
| `--data CARTELLA` | dove tenere i mondi | `server_data` accanto all'exe |
| `--config FILE` | file di impostazioni | `server.cfg` accanto all'exe |
| `--population-authority M` | chi muove i Pokémon selvatici e degli habitat e depone le uova nelle aree dove ci sono giocatori: `server` (il server, in ogni area; i telefoni li mostrano soltanto) o `players` (il primo giocatore di ogni area, come quando ospita un telefono) | `server` |

Per usare il file copia `server.cfg.example` in `server.cfg` e modificalo
(porta, mondo, taglia, ID dei giocatori, password, giocatori massimi da 1 a
8, presenza nella lista JOIN GAME, minuti tra un salvataggio automatico e
l'altro, apertura automatica della porta, chi muove i Pokémon delle aree con
`population_authority`). Le opzioni da riga di comando
vincono sul file. `maxplayers` e `list` riscrivono la loro riga nel file
lasciando com'erano i commenti.

## Il server nella lista JOIN GAME

Con `listed=true` in `server.cfg` (oppure `list on` nella finestra) il server
compare nella lista **JOIN GAME** dei telefoni, accanto alle partite degli
altri giocatori, con nome del mondo, giocatori collegati e massimi. Dal
telefono basta toccarlo: si collega direttamente all'indirizzo **From
outside** del server (non passa dalla rete ZeroTier delle partite dei
telefoni), quindi la porta deve essere raggiungibile da fuori come sopra; con
gli ID attivi il telefono chiede ID e password. Il server si annuncia ogni
mezzo minuto e si toglie da solo con `list off` o quando si spegne (se si
spegne di colpo sparisce dalla lista entro un minuto e mezzo). Nella finestra:
"SERVER listed in the online games list as ..." quando è in lista.

Funziona solo con il server delle release ufficiali (che conoscono l'indirizzo
della lista); una build fatta in casa scrive "not available".

Se il server è raggiungibile da Internet e vuoi scegliere tu chi gioca, usa
`accounts=closed` e crea gli ID con `account add`: con `open` chiunque conosca
l'indirizzo può crearsi un ID ed entrare.

`PokeWilds.console.exe --headless --server` avvia il server senza il
lanciatore: lì però Ctrl+C e la chiusura della finestra lo spengono **senza**
salvare (limite di Godot), quindi usa `stop`.

## Cosa fa il server per i telefoni

- Le **zone nuove** della mappa, quando un giocatore ci entra per la prima
  volta, le crea il server (una seconda copia del gioco, invisibile, che si
  chiude da sola): il telefono aspetta "THIS AREA IS BEING CREATED" senza
  fare il lavoro pesante. Se il server non ci riesce, la crea il telefono
  come nel co-op normale.
- Il server ha un suo giocatore **invisibile** fermo allo spawn: nessuno lo
  vede, non conta tra i giocatori, i Pokémon non lo inseguono e le orde non
  lo prendono di mira.

## I dati

Tutto sta in `server_data` (accanto all'exe): per un backup copia la cartella
a server spento. Il server tiene anche da sé le ultime 5 copie in
`server_data\online_worlds\<id>\backups`. Più mondi possono convivere: cambia
`--world` per passare dall'uno all'altro.

## Limiti

- Fino a 8 giocatori insieme (il limite del co-op del gioco; `max_players`,
  predefinito 4). I telefoni con una versione vecchia del gioco vedono al
  massimo "4/4".
- Le password non viaggiano mai in chiaro, ma il resto del traffico non è
  cifrato, e il server non blocca chi prova tante password di fila: usa
  password non banali e che non usi altrove.
- Firewall fatto a mano: se hai rifiutato la richiesta di Windows, apri
  PowerShell **come amministratore** e scrivi (cambia il percorso):
  `New-NetFirewallRule -DisplayName "PokeWilds server" -Direction Inbound -Program "C:\PokeWilds-Server\PokeWilds.exe" -Action Allow -Profile Any`
