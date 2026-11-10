defmodule ArkabWeb.Words do
  @moduledoc """
  The page's words, in English and Dutch. Two languages and about thirty
  strings do not need gettext, which would be a dependency, a build step and
  four files for the bridge's one page; a map does. `t/2` falls back to
  English for a key the language lacks, and a test makes sure none does.

  The language is the visitor's: a cookie set by `/lang/nl` or `/lang/en`
  (the links at the foot of the page), or, until they choose, what the
  browser asks for (`ArkabWeb.Locale`).
  """

  @locales ~w(en nl)

  @words %{
    "en" => %{
      tagline: "Reads the boards in this hall and sends them on.",
      servers: "Servers",
      connected: "connected",
      not_connected: "not connected",
      server_behind:
        "the server is behind by %{n} events (restored from a backup?); the current boards were sent again",
      remove: "Remove",
      confirm_remove: "Leave this server? It stops getting these boards.",
      no_servers: "Joined to no server yet.",
      waiting: "Events waiting:",
      store_dropped:
        "%{n} events were thrown away because the queue could not be kept (a full disk, or a server that never came back). Remove servers that are gone, and look at the disk.",
      store_error: "The disk refused the last write: %{why}",
      join_title: "Join a server",
      join: "Join",
      joining: "Joining...",
      scan: "Scan",
      joined: "Joined.",
      join_hint:
        "In Alnasl: Halls, your hall, Bridges, \"Add a bridge\". Paste the link it shows here, or press Scan and point the camera at its code; that is all.",
      ports_title: "Ports and boards",
      no_ports: "No ports.",
      not_read: "(not read)",
      board: "Board",
      board_no: "Board no. %{n}",
      serial: "serial",
      recording: "Recording:",
      on: "on",
      off: "off",
      help: "Help",
      back: "Back to the bridge",
      language: "Language",
      err_not_a_link: "That is not a join link. It looks like https://server/join/K7Q-4MD.",
      err_insecure:
        "That link is plain http to a server outside this network, and the bridge's key would travel in the clear. Ask for an https link.",
      err_used_or_expired: "That link is used up or expired. Ask the server for a new one.",
      err_unreachable: "The server in that link does not answer from here.",
      err_version: "That server speaks another version of the link. Update one of the two.",
      err_elsewhere:
        "This bridge is still in another hall on that server. Remove it there first, then use the link again.",
      err_other: "That address answered, but not like a server.",
      update_available: "Arkab %{version} is out.",
      update_size: "The download is %{mb} MB.",
      update_cost: "The boards are not read for about a minute while it installs.",
      update_install: "Download and install",
      update_later: "Later",
      update_manual: "This copy is updated by hand: download the new one and replace this.",
      update_releases: "Releases",
      update_started: "Updating. This page reconnects when the bridge is back.",
      update_no_build: "There is no build for this machine.",
      update_failed: "The last update, to %{version}, did not work: %{why}",
      program_title: "This program",
      unlock_title: "Unlock this bridge",
      unlock_intro:
        "Enter the bridge's access PIN. This browser then gets the page, every button included, for 12 hours.",
      unlock_where:
        "The PIN is on the status page of the bridge itself, and on the screen of a box that has one.",
      pin_show: "Show",
      pin_label: "PIN",
      unlock: "Unlock",
      lock_again: "Lock again",
      unlocked_note: "Unlocked with the PIN, for 12 hours at most.",
      pin_wrong: "That is not the PIN.",
      pin_locked: "Too many wrong tries. Wait %{seconds} seconds.",
      pin_plain:
        "The page runs on plain HTTP: the PIN crosses the hall's network in clear. It keeps a curious guest out of the page; it is not security against the internet.",
      help_title: "Get help",
      help_hint:
        "Sends this box's report (passwords and keys left out) to the people who help, and gives a code to read out to them.",
      help_send: "Send the report",
      help_sending: "Sending...",
      help_code: "Help code",
      help_read: "Read this code to the people helping you. Valid until %{until}.",
      help_no_internet: "The box could not reach the internet. Check its network and try again.",
      help_rate_limited: "Too many requests from this network. Try again in an hour.",
      help_support_off:
        "Support is switched off on that server. Check the address in the box's menu, under Settings.",
      help_too_large: "The report is too large to send.",
      help_rejected: "The server did not accept the report.",
      help_server_error: "The server gave an unexpected answer. Try again later.",
      help_unavailable:
        "The box's own menu did not answer. Try again, or use Get help in its menu.",
      box_title: "This box",
      box_image: "System image %{train} (version %{version})",
      upgrade_available: "%{train} is available",
      upgrade_explain:
        "A new system image for this box. Your data and settings stay. The box restarts when it is done, and goes back to the old version by itself if the new one does not start.",
      upgrade_button: "Upgrade to %{train}",
      upgrade_confirm:
        "Upgrade this box to %{train}? It downloads and installs the new system, then restarts. Do not switch it off meanwhile, and do not do this during a round.",
      upgrade_yes: "Yes, upgrade to %{train}",
      cancel: "Cancel",
      upgrade_blocked:
        "A newer train exists, but this box needs version %{version} of its own train first.",
      upgrade_started: "The upgrade has started.",
      upgrade_keep_power: "Keep the power on.",
      upgrade_round:
        "A round is in progress, so the upgrade did not start. Try again between rounds.",
      upgrade_busy: "The box is busy with another update.",
      upgrade_updates_off: "System updates are off on this box.",
      upgrade_not_ab: "This card cannot take system updates.",
      upgrade_bad_train: "That is not a later train than this box runs.",
      upgrade_unavailable: "The box's own menu did not answer. Try again in a moment.",
      upgrade_server_error: "The box gave an unexpected answer. Try again later.",
      phase_downloading: "Downloading the update",
      phase_verifying: "Checking the download",
      phase_installing: "Installing the update",
      phase_restarting: "Restarting. This page comes back when the box does.",
      phase_waiting: "Waiting for a quiet moment (no round in progress)",
      phase_working: "Working on the update",
      mode_slave: "This box is a slave",
      mode_slave_hint:
        "It only reads the DGT boards and passes them to a master. To make it the master of the hall instead (Alnasl and the hall screen), switch it here.",
      switch_button: "Switch to master",
      switch_confirm:
        "Switch this box to master? Arkab stops here, Alnasl and the hall screen start, and the box restarts. What Arkab keeps stays on the card.",
      switch_yes: "Yes, switch to master",
      switch_started: "Switching. The box restarts.",
      switch_failed: "The box did not switch. Try again, or use Settings in its menu.",
      pin_title: "Access PIN",
      pin_current: "The PIN:",
      pin_random: "New random PIN",
      pin_made: "A new PIN was made; every other browser has to give the new one.",
      pin_notice:
        "A new PIN was made when Arkab was updated: the old one was stored only as a hash and could not be shown.",
      pin_notice_ok: "Got it",
      pin_long: "A PIN has 64 characters at most.",
      pin_edge: "A PIN cannot start or end with a space.",
      pin_invisible: "A PIN cannot hold an invisible or control character.",
      pin_unwritable: "The PIN could not be written to disk; the old one stays.",
      pin_new: "New PIN (at least 6 characters)",
      pin_save: "Save PIN",
      pin_saved: "PIN changed; every other browser has to give the new one.",
      pin_short: "A PIN needs at least 6 characters.",
      pin_hint:
        "Every other computer, phone or laptop has to give this PIN before it sees this page. It is shown and changed on the bridge itself only, and there is always one.",
      version: "Version",
      update_check: "Look for a newer version now and then",
      check_now: "Look now",
      checking: "Looking...",
      up_to_date: "This is the newest version.",
      check_failed: "Could not reach the release page.",
      autostart: "Start Arkab when Windows starts",
      autostart_failed: "Windows would not take that setting."
    },
    "nl" => %{
      tagline: "Leest de borden in deze zaal en stuurt ze door.",
      servers: "Servers",
      connected: "verbonden",
      not_connected: "niet verbonden",
      server_behind:
        "de server loopt %{n} gebeurtenissen achter (hersteld uit een back-up?); de huidige borden zijn opnieuw gestuurd",
      remove: "Verwijderen",
      confirm_remove: "Deze server verlaten? Hij krijgt deze borden dan niet meer.",
      no_servers: "Nog bij geen enkele server aangesloten.",
      waiting: "Gebeurtenissen in de wachtrij:",
      store_dropped:
        "%{n} gebeurtenissen zijn weggegooid omdat de wachtrij niet bewaard kon blijven (een volle schijf, of een server die nooit meer terugkwam). Verwijder servers die weg zijn, en kijk naar de schijf.",
      store_error: "De schijf weigerde het laatste schrijven: %{why}",
      join_title: "Aansluiten bij een server",
      join: "Aansluiten",
      joining: "Aansluiten...",
      scan: "Scannen",
      joined: "Aangesloten.",
      join_hint:
        "In Alnasl: Zalen, je zaal, Bruggen, \"Een brug toevoegen\". Plak de link die verschijnt hier, of druk op Scannen en richt de camera op de code; meer is het niet.",
      ports_title: "Poorten en borden",
      no_ports: "Geen poorten.",
      not_read: "(wordt niet gelezen)",
      board: "Bord",
      board_no: "Bord nr. %{n}",
      serial: "serienummer",
      recording: "Opnemen:",
      on: "aan",
      off: "uit",
      help: "Help",
      back: "Terug naar de brug",
      language: "Taal",
      err_not_a_link:
        "Dat is geen aansluitlink. Zo'n link ziet eruit als https://server/join/K7Q-4MD.",
      err_insecure:
        "Die link is gewoon http naar een server buiten dit netwerk, en de sleutel van de brug zou onversleuteld onderweg zijn. Vraag om een https-link.",
      err_used_or_expired: "Die link is al gebruikt of verlopen. Vraag de server om een nieuwe.",
      err_unreachable: "De server in die link antwoordt niet vanaf hier.",
      err_version: "Die server spreekt een andere versie van de link. Werk een van de twee bij.",
      err_elsewhere:
        "Deze brug zit nog in een andere zaal op die server. Haal hem daar eerst weg en gebruik de link dan opnieuw.",
      err_other: "Dat adres antwoordde, maar niet als een server.",
      update_available: "Arkab %{version} is uit.",
      update_size: "De download is %{mb} MB.",
      update_cost: "De borden worden ongeveer een minuut niet gelezen terwijl het installeert.",
      update_install: "Downloaden en installeren",
      update_later: "Later",
      update_manual: "Deze kopie werk je met de hand bij: download de nieuwe en vervang deze.",
      update_releases: "Uitgaven",
      update_started: "Bijwerken. Deze pagina verbindt opnieuw zodra de brug terug is.",
      update_no_build: "Voor deze machine bestaat geen versie.",
      update_failed: "De laatste update, naar %{version}, is mislukt: %{why}",
      program_title: "Dit programma",
      unlock_title: "Deze brug ontgrendelen",
      unlock_intro:
        "Voer de pincode van de brug in. Deze browser krijgt dan 12 uur lang de pagina, met alle knoppen.",
      unlock_where:
        "De pincode staat op de statuspagina van de brug zelf, en op het scherm van een box die er een heeft.",
      pin_show: "Tonen",
      pin_label: "Pincode",
      unlock: "Ontgrendelen",
      lock_again: "Weer vergrendelen",
      unlocked_note: "Ontgrendeld met de pincode, hooguit 12 uur.",
      pin_wrong: "Dat is de pincode niet.",
      pin_locked: "Te veel foute pogingen. Wacht %{seconds} seconden.",
      pin_plain:
        "De pagina draait op gewoon HTTP: de pincode gaat onversleuteld over het netwerk van de zaal. Hij houdt een nieuwsgierige gast van de pagina af; het is geen beveiliging tegen het internet.",
      help_title: "Hulp vragen",
      help_hint:
        "Stuurt het rapport van deze box (zonder wachtwoorden en sleutels) naar de mensen die helpen, en geeft een code om aan hen door te geven.",
      help_send: "Rapport versturen",
      help_sending: "Versturen...",
      help_code: "Hulpcode",
      help_read: "Geef deze code door aan de mensen die je helpen. Geldig tot %{until}.",
      help_no_internet:
        "De box kreeg geen verbinding met internet. Controleer het netwerk en probeer opnieuw.",
      help_rate_limited: "Te veel aanvragen vanaf dit netwerk. Probeer het over een uur opnieuw.",
      help_support_off:
        "Hulp staat uit op die server. Controleer het adres in het menu van de box, onder Instellingen.",
      help_too_large: "Het rapport is te groot om te versturen.",
      help_rejected: "De server heeft het rapport niet aanvaard.",
      help_server_error: "De server gaf een onverwacht antwoord. Probeer het later opnieuw.",
      help_unavailable:
        "Het eigen menu van de box antwoordde niet. Probeer opnieuw, of gebruik Hulp vragen in het menu.",
      box_title: "Deze box",
      box_image: "Systeemimage %{train} (versie %{version})",
      upgrade_available: "%{train} is beschikbaar",
      upgrade_explain:
        "Een nieuw systeemimage voor deze box. Je gegevens en instellingen blijven. De box start opnieuw op als hij klaar is, en keert zelf terug naar de oude versie als de nieuwe niet start.",
      upgrade_button: "Upgraden naar %{train}",
      upgrade_confirm:
        "Deze box upgraden naar %{train}? Hij downloadt en installeert het nieuwe systeem en start dan opnieuw op. Zet hem ondertussen niet uit, en doe dit niet tijdens een ronde.",
      upgrade_yes: "Ja, upgraden naar %{train}",
      cancel: "Annuleren",
      upgrade_blocked:
        "Er bestaat een nieuwere reeks, maar deze box heeft eerst versie %{version} van zijn eigen reeks nodig.",
      upgrade_started: "De upgrade is begonnen.",
      upgrade_keep_power: "Laat de stroom aan.",
      upgrade_round:
        "Er loopt een ronde, dus de upgrade is niet gestart. Probeer het opnieuw tussen twee rondes.",
      upgrade_busy: "De box is bezig met een andere update.",
      upgrade_updates_off: "Systeemupdates staan uit op deze box.",
      upgrade_not_ab: "Deze kaart kan geen systeemupdates krijgen.",
      upgrade_bad_train: "Dat is geen latere reeks dan die deze box draait.",
      upgrade_unavailable: "Het eigen menu van de box antwoordde niet. Probeer zo opnieuw.",
      upgrade_server_error: "De box gaf een onverwacht antwoord. Probeer het later opnieuw.",
      phase_downloading: "De update wordt gedownload",
      phase_verifying: "De download wordt gecontroleerd",
      phase_installing: "De update wordt geïnstalleerd",
      phase_restarting: "Opnieuw opstarten. Deze pagina komt terug als de box er weer is.",
      phase_waiting: "Wachten op een rustig moment (geen ronde bezig)",
      phase_working: "Bezig met de update",
      mode_slave: "Deze box is een slave",
      mode_slave_hint:
        "Hij leest alleen de DGT-borden en geeft ze door aan een master. Wil je hem zelf de master van de zaal maken (Alnasl en het zaalscherm), schakel hem dan hier om.",
      switch_button: "Omschakelen naar master",
      switch_confirm:
        "Deze box omschakelen naar master? Arkab stopt hier, Alnasl en het zaalscherm starten, en de box start opnieuw op. Wat Arkab bewaart blijft op de kaart.",
      switch_yes: "Ja, omschakelen naar master",
      switch_started: "Omschakelen. De box start opnieuw op.",
      switch_failed:
        "De box schakelde niet om. Probeer opnieuw, of gebruik Instellingen in zijn menu.",
      pin_title: "Pincode",
      pin_current: "De pincode:",
      pin_random: "Nieuwe willekeurige pincode",
      pin_made: "Er is een nieuwe pincode gemaakt; elke andere browser moet de nieuwe geven.",
      pin_notice:
        "Bij het bijwerken van Arkab is een nieuwe pincode gemaakt: de oude was alleen als hash bewaard en kon niet getoond worden.",
      pin_notice_ok: "Begrepen",
      pin_long: "Een pincode heeft hooguit 64 tekens.",
      pin_edge: "Een pincode mag niet met een spatie beginnen of eindigen.",
      pin_invisible: "Een pincode mag geen onzichtbaar teken of stuurteken bevatten.",
      pin_unwritable: "De pincode kon niet naar de schijf geschreven worden; de oude blijft.",
      pin_new: "Nieuwe pincode (minstens 6 tekens)",
      pin_save: "Pincode opslaan",
      pin_saved: "Pincode gewijzigd; elke andere browser moet de nieuwe geven.",
      pin_short: "Een pincode heeft minstens 6 tekens nodig.",
      pin_hint:
        "Elke andere computer, telefoon of laptop moet deze pincode geven voordat hij deze pagina ziet. Je ziet en wijzigt hem alleen op de brug zelf, en er is er altijd een.",
      version: "Versie",
      update_check: "Af en toe naar een nieuwere versie kijken",
      check_now: "Nu kijken",
      checking: "Kijken...",
      up_to_date: "Dit is de nieuwste versie.",
      check_failed: "De uitgavenpagina is niet te bereiken.",
      autostart: "Arkab starten als Windows start",
      autostart_failed: "Windows wilde die instelling niet aannemen."
    }
  }

  def locales, do: @locales

  @doc "The word for `key` in `locale`, English if the language lacks it."
  def t(locale, key, bindings \\ []) do
    text = get_in(@words, [locale, key]) || @words["en"][key]

    Enum.reduce(bindings, text, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
  end

  @doc "Every key of English, for the test that checks Dutch has them all."
  def keys(locale), do: @words |> Map.fetch!(locale) |> Map.keys() |> Enum.sort()
end
