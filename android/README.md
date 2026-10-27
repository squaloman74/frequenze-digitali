# Frequenze Digitali per Android

Questa app Flutter include attivazione licenza, dashboard di telemetria,
letture del microfono e del magnetometro quando disponibili, calibrazione e
report finale PDF con statistiche. La dashboard offre grafici della frequenza
derivata dal modello di Lorenz, forma d'onda audio e spettrogramma FFT con
scale temporali, frequenziali e d'intensità in dBFS.
La build beta mostra la versione 26 e include un modulo feedback che apre il
menu di condivisione del dispositivo; il feedback viene inviato solo se il
tester sceglie un'app e conferma la condivisione.

Le viste audio richiedono l'avvio del microfono e il relativo permesso.
La calibrazione è abilitata solo mentre il microfono è attivo. La frequenza di
Lorenz è un valore del modello matematico, non una misura ambientale. La
disponibilità del microfono e del magnetometro nel simulatore dipende dalla sua
configurazione; l'app mostra un messaggio quando non riceve campioni audio.
I pulsanti delle viste restano disponibili nella barra inferiore della
dashboard. Gli eventi non vengono mostrati come registro live: sono conservati
in memoria e inclusi nel report finale PDF. Il report riassume frequenza,
livelli audio e campo magnetico disponibili, oltre agli eventi recenti.
Gli avvisi sonori sono attivi per impostazione predefinita quando viene
rilevata una componente stabile a 50/60 Hz. Si possono disattivare e regolare
dal 10% al 100% nella sezione del microfono; il volume iniziale è 65% e segue
anche il volume degli allarmi del dispositivo.

La versione mostrata nell'app viene letta dai metadati della build. Prima di
ogni beta, incrementare `version` in `pubspec.yaml` (per esempio
`26.0.0-beta.9+9` → `26.0.0-beta.10+10`) e compilare
`app-beta-release.apk`. Copiare il risultato in `Frequenze-Digitali.apk` e
aggiornare `android/update.json` (percorso dal repository) con nuova versione,
build e SHA-256 calcolato con
`(Get-FileHash .\Frequenze-Digitali.apk -Algorithm SHA256).Hash.ToLowerInvariant()`.
Pubblicare insieme i due file sul branch `main` di questo repository GitHub
reso pubblico. Dalla
schermata Informazioni scientifiche l'app controlla il manifest, scarica la
beta successiva, ne verifica lo SHA-256 e chiede ad Android di installarla.
Per passare dalla beta 6 occorre installare manualmente la beta 7 bootstrap
una volta; poi il pulsante scarica le beta successive dal repository.

Il repository beta deve essere pubblico e raggiungibile dal telefono. Android
richiede l'autorizzazione dell'utente per installare app da questa sorgente;
la firma dell'APK scaricata deve corrispondere a quella dell'app installata.
La beta usa un product flavor dedicato, così il permesso sideload non viene
incluso nell'APK Play:

```powershell
flutter build apk --release --flavor beta --dart-define=ENABLE_GITHUB_UPDATES=true
flutter build appbundle --release --flavor play
```

Google Play resta supportato per le release distribuite dallo Store.

La configurazione di firma release in questo progetto usa attualmente la
chiave debug locale: serve configurare una chiave di caricamento privata prima
di pubblicare su Google Play. Gli APK distribuiti manualmente non possono
usare gli aggiornamenti in-app di Play e devono essere aggiornati installando
una nuova APK firmata con la stessa chiave.

## Avvio e test

```powershell
flutter run
flutter analyze
flutter test
flutter build apk --debug
flutter build apk --release
```

L'APK di debug viene generato in
`build/app/outputs/flutter-apk/app-debug.apk`. Il build release locale usa la
chiave debug di Gradle e non è adatto alla distribuzione sul Play Store.

## Loghi

- `assets/lorenz-circle.png`: logo circolare usato nell'header Flutter e come
  base per le icone launcher Android.
- `assets/lorenz-wordmark.png`: logo completo usato nella schermata iniziale.
- `android/app/src/main/res/drawable-nodpi/launch_logo.png`: logo splash
  nativo Android.

Il package Android è `it.frequenzedigitali.frequenze_digitali`. Per pubblicare
una release serviranno una chiave di firma Android dedicata e la configurazione
di release appropriata.
